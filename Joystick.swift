// Joystick — live dashboard of operations running across all terminal tabs.
// Reads ~/.local/state/joystick/events.jsonl (written by joystick.zsh and
// claude-hook.sh). Click a row to focus that Ghostty tab.
// Build with ~/joystick/build-app.sh

import SwiftUI
import AppKit
import Combine
import Darwin

// MARK: - Events & operations

struct RawEvent: Decodable {
    let ev: String
    let id: String
    let cmd: String?
    let cwd: String?
    let pid: Int32?
    let tty: String?
    let surface: String?
    let ts: Double
    let exit: Int?
    let dur: Double?
    let msg: String?
}

struct Op: Identifiable {
    let key: String
    let cmd: String
    let cwd: String
    let tty: String
    let surface: String
    let pid: Int32
    let start: Double
    var endTs: Double? = nil
    var exitCode: Int? = nil
    var dur: Double? = nil
    var waitingSince: Double? = nil   // explicit waiting event (Claude hooks)
    var waitingMsg: String? = nil
    var stallIdle: Double? = nil      // heuristic: tty quiet + fg proc asleep
    var isService = false             // fg process group holds a listening port
    var unseen = false                // finished, and surface not viewed since

    var id: String { "\(key)-\(Int(start))" }
    var isRunning: Bool { endTs == nil }
    var isWaiting: Bool { isRunning && (waitingSince != nil || stallIdle != nil) }
    var isClaude: Bool { tty == "claude" }

    // Stable grouping identity. A Claude session keeps ONE id across all its
    // turns (claude-<sid>), so group by that — robust even when surface
    // capture misses. Shell commands have per-command ids, so they group by
    // their Ghostty surface (the terminal they ran in).
    var groupKey: String { isClaude ? key : (surface.isEmpty ? id : surface) }
}

// One row per Ghostty surface: what the terminal is doing now (or did last),
// with a short dimmed history of earlier results beneath it.
struct SurfaceGroup: Identifiable {
    let key: String      // surface id (op id when surface unknown)
    var current: Op
    var history: [Op] = []
    var id: String { key }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var activeGroups: [SurfaceGroup] = []
    @Published var idleGroups: [SurfaceGroup] = []
    @Published var now = Date()

    static let minRunningSecs = 5.0
    static let minDoneSecs = 10.0
    static let doneWindowSecs = 6.0 * 3600
    static let maxDone = 20
    static let historyCap = 3
    static let ignore: Set<String> = ["claude", "claude2", "vim", "nvim", "less", "man", "top", "htop", "tmux"]
    nonisolated static let stallSecs = 20.0

    enum TtyState: Sendable { case waiting(Double), service }

    private var ttyStates: [String: TtyState] = [:]
    private var lastStallCheck = Date.distantPast
    private var notifiedWaiting: Set<String> = []
    // Parsed log cache — the file only changes a few times a minute, but
    // reload() ticks every second; re-parse only when (mtime, size) move.
    private var lastLogMtime = Date.distantPast
    private var lastLogSize: UInt64 = .max
    private var parsedOpen: [String: Op] = [:]
    private var parsedDone: [Op] = []
    private var lastPersistedFocus: String? = nil
    private var liveSurfaces: Set<String>? = nil
    private var lastSurfacePoll = Date.distantPast
    private var lastFocusPoll = Date.distantPast
    // surface id -> last time it was focused while Ghostty was frontmost
    private var seenAt: [String: Double] = [:]
    private var timer: Timer?

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: "seenAt") as? [String: Double] {
            seenAt = d
        }
        // Self-drive the refresh so the menubar stays live even when no window
        // is open. (Previously the 1s timer lived in ContentView and only
        // ticked while a window was visible.)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private var logURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("joystick/events.jsonl")
    }

    func reload() {
        now = Date()
        let nowTs = now.timeIntervalSince1970
        parseLogIfChanged()

        var running = parsedOpen.values
            .filter { alive($0.pid) && nowTs - $0.start >= Self.minRunningSecs && !ignored($0.cmd) }

        // Stall heuristic for shell ops (interactive prompts like `eas submit`):
        // tty produced no output for a while and its foreground process is
        // asleep with no CPU — almost certainly waiting on the user. Sampled
        // every 5s on a background queue (it shells out to ps); rows pick up
        // the previous sample, one tick of lag is invisible.
        refreshTtyStates(ttys: Set(running.map(\.tty)), nowTs: nowTs)
        running = running.map { op -> Op in
            var op = op
            if op.waitingSince == nil {
                switch ttyStates[op.tty] {
                case .waiting(let idle): op.stallIdle = idle
                case .service: op.isService = true
                case nil: break
                }
            }
            return op
        }
        notifyNewlyWaiting(running: running)

        var finished = Array(
            parsedDone.filter { ($0.dur ?? 0) >= Self.minDoneSecs
                && nowTs - ($0.endTs ?? 0) <= Self.doneWindowSecs
                && !ignored($0.cmd) }
                .sorted { ($0.endTs ?? 0) > ($1.endTs ?? 0) }
                .prefix(Self.maxDone)
        )

        // Closing a tab IS the dismiss gesture: finished ops whose Ghostty
        // surface no longer exists are dropped entirely (noise, not history).
        pollLiveSurfaces()
        if let live = liveSurfaces {
            finished.removeAll { !live.contains($0.surface) }
        }

        // Unread badges: a finished op is unseen until its surface has been
        // focused (in Ghostty, by any means) after the op ended.
        pollFocusedSurface()
        finished = finished.map { op -> Op in
            var op = op
            op.unseen = (seenAt[op.surface] ?? 0) < (op.endTs ?? 0)
            return op
        }

        // One group per terminal: the running op (or latest result) is the
        // terminal's state; earlier results are dimmed history beneath it.
        var bySurface: [String: SurfaceGroup] = [:]
        var order: [String] = []
        for op in running {
            let key = op.groupKey
            if var g = bySurface[key] {
                if op.start > g.current.start { g.history.insert(g.current, at: 0); g.current = op }
                bySurface[key] = g
            } else {
                bySurface[key] = SurfaceGroup(key: key, current: op)
                order.append(key)
            }
        }
        for op in finished {   // already newest-first
            let key = op.groupKey
            if var g = bySurface[key] {
                if g.history.count < Self.historyCap { g.history.append(op) }
                bySurface[key] = g
            } else {
                bySurface[key] = SurfaceGroup(key: key, current: op)
                order.append(key)
            }
        }
        var active: [SurfaceGroup] = []
        var idle: [SurfaceGroup] = []
        for key in order {
            let g = bySurface[key]!
            if g.current.isRunning { active.append(g) } else { idle.append(g) }
        }
        // Waiting terminals on top, then active ops, then services (ambient).
        active.sort { a, b in
            if a.current.isWaiting != b.current.isWaiting { return a.current.isWaiting }
            if a.current.isService != b.current.isService { return !a.current.isService }
            return a.current.start < b.current.start
        }
        idle.sort { ($0.current.endTs ?? 0) > ($1.current.endTs ?? 0) }
        activeGroups = active
        idleGroups = idle

        let unseenCount = idle.filter { $0.current.unseen }.count
        NSApp.dockTile.badgeLabel = unseenCount > 0 ? "\(unseenCount)" : nil
    }

    func focus(_ op: Op) {
        guard !op.surface.isEmpty || !op.cwd.isEmpty else { return }
        // Optimistically mark seen — the focus poll would catch it anyway,
        // but this clears the badge without the ~2s lag.
        if !op.surface.isEmpty {
            seenAt[op.surface] = now.timeIntervalSince1970
            persistSeen()
        }
        let script = NSString(string: "~/joystick/joystick-focus.sh").expandingTildeInPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script, op.surface.isEmpty ? "-" : op.surface, op.cwd]
        try? p.run()
    }

    private func parseLogIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let size = ((attrs?[.size] as? NSNumber)?.uint64Value) ?? 0
        guard mtime != lastLogMtime || size != lastLogSize else { return }
        lastLogMtime = mtime
        lastLogSize = size

        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            parsedOpen = [:]; parsedDone = []
            return
        }
        let decoder = JSONDecoder()
        var open: [String: Op] = [:]
        var done: [Op] = []
        for line in text.split(separator: "\n").suffix(4000) {
            guard let e = try? decoder.decode(RawEvent.self, from: Data(line.utf8)) else { continue }
            if e.ev == "start" {
                open[e.id] = Op(key: e.id, cmd: e.cmd ?? "?", cwd: e.cwd ?? "",
                                tty: e.tty ?? "", surface: e.surface ?? "",
                                pid: e.pid ?? -1, start: e.ts)
            } else if e.ev == "end", var op = open.removeValue(forKey: e.id) {
                op.endTs = e.ts
                op.exitCode = e.exit ?? 0
                op.dur = e.dur ?? max(0, e.ts - op.start)
                done.append(op)
            } else if e.ev == "waiting", var op = open[e.id] {
                op.waitingSince = e.ts
                op.waitingMsg = e.msg
                open[e.id] = op
            } else if e.ev == "active", var op = open[e.id] {
                op.waitingSince = nil
                op.waitingMsg = nil
                open[e.id] = op
            }
        }
        parsedOpen = open
        parsedDone = done
    }

    private func refreshTtyStates(ttys: Set<String>, nowTs: Double) {
        guard now.timeIntervalSince(lastStallCheck) >= 5 else { return }
        lastStallCheck = now
        let candidates = ttys.filter { !$0.isEmpty && $0 != "claude" }
        guard !candidates.isEmpty else { ttyStates = [:]; return }
        DispatchQueue.global(qos: .utility).async {
            var states: [String: TtyState] = [:]
            for tty in candidates {
                if let st = Self.probeTty(tty: tty, nowTs: nowTs) { states[tty] = st }
            }
            DispatchQueue.main.async { [weak self] in self?.ttyStates = states }
        }
    }

    private func ignored(_ cmd: String) -> Bool {
        let first = cmd.split(separator: " ").first.map(String.init) ?? ""
        return Self.ignore.contains(first)
    }

    private func alive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Classifies what a tty's foreground is doing:
    //   .service       — fg process group holds a listening TCP socket
    //                    (yarn dev, vite, ...), regardless of activity
    //   .waiting(idle) — no output for stallSecs+, fg asleep at ~0% CPU,
    //                    no listener: almost certainly a prompt
    //   nil            — busy, or no foreground command
    nonisolated static func probeTty(tty: String, nowTs: Double) -> TtyState? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/dev/" + tty),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let idle = nowTs - mtime.timeIntervalSince1970

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-t", tty, "-o", "pid=,stat=,pcpu=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }

        let shells: Set<String> = ["zsh", "bash", "fish", "sh"]
        var sawForeground = false
        var busy = false
        var fgPids: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            let pid = String(parts[0])
            let stat = String(parts[1])
            let pcpu = Double(parts[2]) ?? 0
            let comm = String(parts[3])
            guard stat.contains("+") else { continue }
            let base = (comm as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if shells.contains(base) { continue }
            sawForeground = true
            fgPids.append(pid)
            if stat.hasPrefix("R") || pcpu > 5 { busy = true }
        }
        guard sawForeground else { return nil }
        // ps -t lists children too, so the yarn->node listener is seen.
        if hasListeningSocket(pids: fgPids) { return .service }
        if busy || idle < stallSecs { return nil }
        return .waiting(idle)
    }

    nonisolated static func hasListeningSocket(pids: [String]) -> Bool {
        guard !pids.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", pids.joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return !data.isEmpty
    }

    // Notify once per op when it first enters a stall-detected waiting state.
    // (Claude waiting events already notify from the hook itself.)
    private func notifyNewlyWaiting(running: [Op]) {
        let stalled = running.filter { $0.stallIdle != nil && $0.waitingSince == nil }
        for op in stalled where !notifiedWaiting.contains(op.id) {
            notifiedWaiting.insert(op.id)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.mitchellh.ghostty" {
                notifyUser(title: "Waiting for your input?",
                           body: "\(op.cmd) — quiet for \(fmt(op.stallIdle ?? 0)) in \(tilde(op.cwd))")
            }
        }
        notifiedWaiting.formIntersection(Set(running.filter(\.isWaiting).map(\.id)))
    }

    // Poll Ghostty for the set of live surface ids, off the main thread,
    // at most every 10s. nil result (e.g. automation denied) keeps the
    // previous set rather than wrongly marking everything closed.
    private func pollLiveSurfaces() {
        guard Date().timeIntervalSince(lastSurfacePoll) >= 10 else { return }
        lastSurfacePoll = Date()
        DispatchQueue.global(qos: .utility).async {
            let ids = Self.fetchLiveSurfaceIds()
            DispatchQueue.main.async { [weak self] in
                guard let self, let ids else { return }
                self.liveSurfaces = ids
                // Forget seen-state for surfaces that no longer exist.
                self.seenAt = self.seenAt.filter { ids.contains($0.key) }
                self.persistSeen()
            }
        }
    }

    // While the user is actually in Ghostty, whatever surface is focused is
    // being viewed — stamp it. Cheap AppleScript, sampled every 2s, and only
    // when Ghostty is the frontmost app (a background tab isn't "viewed").
    private func pollFocusedSurface() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty",
              Date().timeIntervalSince(lastFocusPoll) >= 2 else { return }
        lastFocusPoll = Date()
        DispatchQueue.global(qos: .utility).async {
            let id = Self.fetchFocusedSurfaceId()
            DispatchQueue.main.async { [weak self] in
                guard let self, let id, !id.isEmpty else { return }
                self.seenAt[id] = Date().timeIntervalSince1970
                // In-memory state updates every sample; disk persistence only
                // needs to survive restarts, so write only on focus change.
                if self.lastPersistedFocus != id {
                    self.lastPersistedFocus = id
                    self.persistSeen()
                }
            }
        }
    }

    nonisolated static func fetchFocusedSurfaceId() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Ghostty\" to get id of focused terminal of selected tab of front window"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistSeen() {
        UserDefaults.standard.set(seenAt, forKey: "seenAt")
    }

    nonisolated static func fetchLiveSurfaceIds() -> Set<String>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Ghostty\" to get id of every terminal of every window"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }
        let ids = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    private func notifyUser(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv",
                       "-e", "display notification (item 2 of argv) with title (item 1 of argv) sound name \"Glass\"",
                       "-e", "end run", title, body]
        try? p.run()
    }
}

// MARK: - Formatting

func fmt(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t < 60 { return "\(t)s" }
    if t < 3600 { return String(format: "%dm%02ds", t / 60, t % 60) }
    return String(format: "%dh%02dm", t / 3600, (t % 3600) / 60)
}

func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Views

struct OpRow: View {
    let op: Op
    let nowTs: Double

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)
                .opacity(op.unseen ? 1 : 0)
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(op.cmd)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(timeText)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(op.isService ? Color.green
                                 : op.isRunning ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 3)
    }

    private var statusIcon: some View {
        Group {
            if op.isWaiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            } else if op.isService {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
            } else if op.isRunning {
                Image(systemName: "play.circle.fill").foregroundStyle(.blue)
            } else if op.exitCode == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 16))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let since = op.waitingSince {
            let what = (op.waitingMsg?.isEmpty == false) ? op.waitingMsg! : "needs you"
            parts.append("✋ \(what) — \(fmt(nowTs - since))")
        } else if let idle = op.stallIdle {
            parts.append("✋ waiting for input? quiet \(fmt(idle))")
        } else if op.isService {
            parts.append("serving")
        }
        parts.append(tilde(op.cwd))
        if !op.tty.isEmpty { parts.append(op.tty) }
        if let code = op.exitCode, code != 0 {
            parts.append(code == -1 ? "killed" : "exit \(code)")
        }
        if let end = op.endTs { parts.append(fmt(nowTs - end) + " ago") }
        return parts.joined(separator: " · ")
    }

    private var timeText: String {
        op.isRunning ? fmt(nowTs - op.start) : fmt(op.dur ?? 0)
    }
}

struct GroupRow: View {
    let group: SurfaceGroup
    let nowTs: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                OpRow(op: group.current, nowTs: nowTs)
                ForEach(group.history) { op in
                    HStack(spacing: 0) {
                        Spacer().frame(width: 43)  // align under the command text
                        Text(historyLine(op))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .opacity(0.65)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to focus this tab in Ghostty")
    }

    private func historyLine(_ op: Op) -> String {
        let mark = (op.exitCode ?? 0) == 0 ? "✓" : "✗"
        let ago = fmt(nowTs - (op.endTs ?? nowTs))
        return "\(mark) \(op.cmd) — \(fmt(op.dur ?? 0)) (\(ago) ago)"
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var floatOnTop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            opList
        }
        .frame(minWidth: 400, minHeight: 320)
        .onAppear { store.reload() }
        .onChange(of: floatOnTop) { _, pinned in
            for w in NSApp.windows { w.level = pinned ? .floating : .normal }
        }
    }

    private var header: some View {
        let waiting = store.activeGroups.filter { $0.current.isWaiting }.count
        let serving = store.activeGroups.filter { $0.current.isService }.count
        let runningCount = store.activeGroups.count - serving
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if serving > 0 { parts.append("\(serving) serving") }
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        return HStack(spacing: 8) {
            Circle()
                .fill(waiting > 0 ? Color.orange
                      : store.activeGroups.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 9, height: 9)
            Text(parts.isEmpty ? "Idle" : parts.joined(separator: " · "))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Spacer()
            Toggle("Pin", isOn: $floatOnTop)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Keep this window above all others")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var opList: some View {
        let nowTs = store.now.timeIntervalSince1970
        return List {
            Section("Running") {
                if store.activeGroups.isEmpty {
                    Text("Nothing running")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.activeGroups) { g in
                        GroupRow(group: g, nowTs: nowTs) { store.focus(g.current) }
                    }
                }
            }
            if !store.idleGroups.isEmpty {
                Section("Finished") {
                    ForEach(store.idleGroups) { g in
                        GroupRow(group: g, nowTs: nowTs) { store.focus(g.current) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - App

// Compact status shown in the menubar: an icon + count that reflects the most
// urgent thing happening (needs-you > running > serving > idle).
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let waiting = store.activeGroups.filter { $0.current.isWaiting }.count
        let serving = store.activeGroups.filter { $0.current.isService }.count
        let running = store.activeGroups.count - serving
        if waiting > 0 {
            Label("\(waiting)", systemImage: "hand.raised.fill")
        } else if running > 0 {
            Label("\(running)", systemImage: "play.fill")
        } else if serving > 0 {
            Label("\(serving)", systemImage: "antenna.radiowaves.left.and.right")
        } else {
            Image(systemName: "gamecontroller")
        }
    }
}

@main
struct JoystickApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Joystick") {
            ContentView().environmentObject(store)
        }

        // The app now owns the menubar itself (replacing the SwiftBar plugin).
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
                .frame(width: 380, height: 460)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
