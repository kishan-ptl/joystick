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
    let v: Int?            // schema version (1); absent on pre-versioning events
    let kind: String?      // "shell" | "claude" | "external"; absent on legacy events (derive from tty)
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
    let act: String?       // current activity (tool the agent just used), on `active` events
    let title: String?     // session topic (ai-title), on `meta` events
    let model: String?     // model id, on `meta` events
    let mode: String?      // permission mode, on `meta` events
    let ctx: Double?       // context-window tokens used, on `meta` events
    let name: String?      // user-set session title (rename), on `meta` events
    let color: String?     // user-set session color (agent color), on `meta` events
}

struct Op: Identifiable {
    let key: String
    let cmd: String
    let cwd: String
    let tty: String        // real device for shell ops; "" for claude/external
    let surface: String
    let kind: String       // "shell" | "claude" | "external"
    let pid: Int32
    let start: Double
    var endTs: Double? = nil
    var exitCode: Int? = nil
    var dur: Double? = nil
    var waitingSince: Double? = nil   // explicit waiting event (Claude hooks)
    var waitingMsg: String? = nil
    var activity: String? = nil       // live: tool the agent is currently using (Claude)
    var stallIdle: Double? = nil      // heuristic: tty quiet + fg proc asleep
    var isService = false             // fg process group holds a listening port
    var unseen = false                // finished, and surface not viewed since
    var summary: String? = nil        // Claude's closing blurb, on the end event
    var title = ""                    // session topic (from meta events), Claude rows
    var model = ""                    // model id (from meta events)
    var mode = ""                     // permission mode (from meta events)
    var ctxTokens: Double = 0         // context-window fill (from meta events)
    var sessionName = ""              // user-given session title (rename), from meta
    var agentColor = ""               // user-given session color name, from meta

    var id: String { "\(key)-\(Int(start))" }
    var isRunning: Bool { endTs == nil }
    var isWaiting: Bool { isRunning && (waitingSince != nil || stallIdle != nil) }
    var isClaude: Bool { kind == "claude" }
    var isExternal: Bool { kind == "external" }   // `joystick log` (CI/webhooks); no local pid or surface

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

// Per-session metadata from the transcript (`meta` events), keyed by claude-<sid>.
struct SessionMeta { var title = ""; var model = ""; var mode = ""; var ctx: Double = 0; var name = ""; var color = "" }

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var activeGroups: [SurfaceGroup] = []
    @Published var idleGroups: [SurfaceGroup] = []
    @Published var now = Date()
    @Published var commandsToday = 0   // shell + Claude turns started today (local time)
    // Surface id of the Ghostty tab/split focused right now (or most recently,
    // while you're away in another app — we deliberately DON'T clear it on blur,
    // so the highlight keeps pointing at "where you were" — that's the get-back-
    // to-the-right-tab use case). Drives the focused-row highlight in GroupRow.
    @Published var focusedSurface: String? = nil

    static let minRunningSecs = 5.0
    static let minDoneSecs = 10.0
    static let doneWindowSecs = 6.0 * 3600
    static let externalTTL = 24.0 * 3600   // running `joystick log` ops dropped after this with no end
    static let maxDone = 20
    static let maxDoneRetained = 2000   // incremental parse accumulates; cap retained finished ops
    static let historyCap = 3
    static let ignore: Set<String> = ["claude", "claude2", "vim", "nvim", "less", "man", "top", "htop", "tmux"]
    nonisolated static let stallSecs = 20.0
    static let backstopSecs = 10.0   // safety-net reload cadence; the FS watch does the real work

    enum TtyState: Sendable { case waiting(Double), service }

    private var ttyStates: [String: TtyState] = [:]
    private var lastStallCheck = Date.distantPast
    private var notifiedWaiting: Set<String> = []
    // Parsed log cache — re-parse only when (mtime, size) move, and then read
    // only the bytes appended since lastReadOffset, folding each new event into
    // the maps below. A full re-read happens only on rotation/truncation.
    private var lastLogMtime = Date.distantPast
    private var lastLogSize: UInt64 = .max
    private var lastReadOffset: UInt64 = 0   // bytes of the log already folded in
    private var parsedOpen: [String: Op] = [:]
    private var parsedDone: [Op] = []
    private var parsedMeta: [String: SessionMeta] = [:]
    private var lastPersistedFocus: String? = nil
    private var liveSurfaces: Set<String>? = nil
    private var lastSurfacePoll = Date.distantPast
    private var lastFocusPoll = Date.distantPast
    // surface id -> last time it was focused while Ghostty was frontmost
    private var seenAt: [String: Double] = [:]
    // Refresh is event-driven (see startWatching): an FS watch on the log fires
    // reload() within ~tens of ms of a new event, instead of a 1 Hz poll. The
    // active tick runs at 1 Hz only while something is running (to advance the
    // clock and cross time thresholds); a slow backstop covers missed events and
    // log rotation. At rest, none of these fire.
    private var logWatcher: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?
    private var activeTick: Timer?
    private var backstopTimer: Timer?
    // 4 Hz sampler for the focused-tab highlight, live ONLY while Ghostty is
    // frontmost (started/stopped by focusObserver). Catches tab/split switches,
    // which don't change the frontmost app; off at rest, so it doesn't regress
    // the log-watch model's quiet.
    private var focusTick: Timer?
    private var focusObserver: NSObjectProtocol?
    // Daily command tally (shell + Claude turns started today, local time). Driven
    // incrementally as starts are folded; recomputed from the log only on a day
    // change (backfill), and persisted so it survives restarts and log rotation.
    private var tallyDayStart: TimeInterval = 0
    private var needsBackfill = false

    init() {
        // Keep the installed emitter scripts current with this app build before
        // anything else — an auto-update (Sparkle/brew) ships new bundled scripts
        // but the hooks run the COPIES in $JOYSTICK_HOME.
        Self.syncEmitters()
        if let d = UserDefaults.standard.dictionary(forKey: "seenAt") as? [String: Double] {
            seenAt = d
        }
        commandsToday = UserDefaults.standard.integer(forKey: "commandsToday")
        tallyDayStart = UserDefaults.standard.double(forKey: "tallyDayStart")
        reload()
        // Watch the log instead of polling it: near-instant pickup of new
        // sessions and state changes, and ~zero wakeups while the log is quiet.
        startWatching()
        // Safety net for missed FS events, the log being created after launch,
        // and rotation gaps — far cheaper than the old always-on 1 Hz poll.
        backstopTimer = Timer.scheduledTimer(withTimeInterval: Self.backstopSecs, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        startFocusTracking()
    }

    deinit {
        logWatcher?.cancel()
        activeTick?.invalidate()
        backstopTimer?.invalidate()
        focusTick?.invalidate()
        if let o = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    // The shell + Claude hooks run COPIES of the emitter scripts in $JOYSTICK_HOME
    // (placed there by install.sh), not the ones in our bundle. So an app update
    // would otherwise leave them on stale logic until the user re-ran the
    // installer. On launch, if $JOYSTICK_HOME exists (i.e. already installed) and
    // its stamped version differs from ours, re-copy the bundled scripts and
    // restamp. Fail-silent, and we never CREATE $JOYSTICK_HOME — first install
    // (which also wires .zshrc/Claude) is install.sh's job, not ours.
    nonisolated static func syncEmitters() {
        let fm = FileManager.default
        guard let resPath = Bundle.main.resourcePath else { return }
        let homePath = ProcessInfo.processInfo.environment["JOYSTICK_HOME"]
            ?? (NSHomeDirectory() + "/.config/joystick")
        let home = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: home.path, isDirectory: &isDir), isDir.boolValue else { return }

        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        let stamp = home.appendingPathComponent(".joystick-version")
        let installed = (try? String(contentsOf: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, installed != version else { return }

        // The same set install.sh places in $JOYSTICK_HOME (incl. the installer,
        // so `install.sh uninstall` and re-runs use the current copy).
        let res = URL(fileURLWithPath: resPath)
        for s in ["install.sh", "joystick.zsh", "claude-hook.sh", "joystick-redact.zsh", "joystick-focus.sh"] {
            let src = res.appendingPathComponent(s)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = home.appendingPathComponent(s)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        try? version.write(to: stamp, atomically: true, encoding: .utf8)
    }

    // Make the focused-tab highlight responsive without a perpetual poll. The
    // instant Ghostty becomes frontmost we sample immediately (switching INTO
    // Ghostty feels instant), then tick at 4 Hz to catch tab/split switches
    // within Ghostty (those don't fire an app-activation notification). When any
    // other app takes over we stop ticking — nothing fires at rest.
    private func startFocusTracking() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.updateFocusTick(app?.bundleIdentifier == "com.mitchellh.ghostty")
            }
        }
        // Launch case: Ghostty may already be frontmost.
        updateFocusTick(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty")
    }

    // Start/stop the 4 Hz focus sampler. Idempotent. Does NOT clear
    // focusedSurface on stop — the highlight holds on the last tab you were in.
    private func updateFocusTick(_ ghosttyFront: Bool) {
        if ghosttyFront {
            pollFocusedSurface()   // immediate, so switching INTO Ghostty is instant
            guard focusTick == nil else { return }
            focusTick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollFocusedSurface() }
            }
        } else {
            focusTick?.invalidate()
            focusTick = nil
        }
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
        rolloverTallyIfNeeded()
        parseLogIfChanged()

        var running = parsedOpen.values
            .filter { op in
                guard !ignored(op.cmd) else { return false }
                // External ops (joystick log) have no local pid/surface — keep
                // them until an `end` event arrives or the TTL elapses.
                if op.isExternal { return nowTs - op.start < Self.externalTTL }
                return alive(op.pid) && nowTs - op.start >= Self.minRunningSecs
            }

        // Stall heuristic for shell ops (interactive prompts like `eas submit`):
        // tty produced no output for a while and its foreground process is
        // asleep with no CPU — almost certainly waiting on the user. Sampled
        // every 5s on a background queue (it shells out to ps); rows pick up
        // the previous sample, one tick of lag is invisible.
        refreshTtyStates(ttys: Set(running.filter { $0.kind == "shell" }.map(\.tty)), nowTs: nowTs)
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
            parsedDone.filter { ($0.isExternal || ($0.dur ?? 0) >= Self.minDoneSecs)
                && nowTs - ($0.endTs ?? 0) <= Self.doneWindowSecs
                && !ignored($0.cmd) }
                .sorted { ($0.endTs ?? 0) > ($1.endTs ?? 0) }
                .prefix(Self.maxDone)
        )

        // Closing a tab IS the dismiss gesture: a finished op is dropped once
        // its hosting terminal is gone (noise, not history). How we know it's
        // gone differs by kind — and a Claude row can't use the surface gate:
        //   shell  — its Ghostty surface no longer exists. The surface id is a
        //            reliable per-shell capture and UUIDs are never reused, so
        //            this never wrongly keeps or drops a row.
        //   claude — its session process has exited. A Claude row's surface is
        //            only a best-effort focused-surface snapshot (captured once
        //            on the session's first prompt); it can point at the WRONG,
        //            still-open pane, which would keep a closed session's rows
        //            alive forever. The claude/node pid can't outlive its pane
        //            (Ghostty SIGHUPs it on close), so pid-liveness is the
        //            trustworthy "is the host still here?" signal.
        //   external — no local host; TTL-gated above, never dropped here.
        pollLiveSurfaces()
        finished.removeAll { op in
            if op.isExternal { return false }
            if op.isClaude { return !alive(op.pid) }
            guard let live = liveSurfaces else { return false }
            return !live.contains(op.surface)
        }

        // Unread badges: a finished op is unseen until its surface has been
        // focused (in Ghostty, by any means) after the op ended.
        pollFocusedSurface()
        finished = finished.map { op -> Op in
            var op = op
            op.unseen = !op.isExternal && (seenAt[op.surface] ?? 0) < (op.endTs ?? 0)
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
        // Waiting terminals on top, longest-BLOCKED first (the needs-you inbox),
        // then active ops, then services (ambient).
        func blockedSecs(_ op: Op) -> Double {
            if let since = op.waitingSince { return nowTs - since }
            return op.stallIdle ?? 0   // stallIdle already = seconds blocked
        }
        active.sort { a, b in
            if a.current.isWaiting != b.current.isWaiting { return a.current.isWaiting }
            if a.current.isWaiting && b.current.isWaiting { return blockedSecs(a.current) > blockedSecs(b.current) }
            if a.current.isService != b.current.isService { return !a.current.isService }
            return a.current.start < b.current.start
        }
        idle.sort { ($0.current.endTs ?? 0) > ($1.current.endTs ?? 0) }
        // Attach per-session meta (title/model/mode/ctx from `meta` events) to
        // each Claude group's current op for display.
        func withMeta(_ g: SurfaceGroup) -> SurfaceGroup {
            guard let m = parsedMeta[g.key] else { return g }
            var g = g
            g.current.title = m.title; g.current.model = m.model
            g.current.mode = m.mode; g.current.ctxTokens = m.ctx
            g.current.sessionName = m.name; g.current.agentColor = m.color
            return g
        }
        activeGroups = active.map(withMeta)
        idleGroups = idle.map(withMeta)

        let unseenCount = idle.filter { $0.current.unseen }.count
        NSApp.dockTile.badgeLabel = unseenCount > 0 ? "\(unseenCount)" : nil

        // Run the 1 Hz tick only while something is (or is about to become)
        // running — it advances elapsed-time labels, crosses the minRunningSecs
        // visibility threshold, re-evaluates the stall heuristic, and drops rows
        // whose pid died without an `end`. With no live open op there's nothing
        // to animate, so the tick is torn down and the app idles silently; the
        // FS watch alone wakes it when the next event lands.
        let liveOpen = parsedOpen.values.contains {
            $0.isExternal ? (nowTs - $0.start < Self.externalTTL) : alive($0.pid)
        }
        updateActiveTick(liveOpen)
    }

    // MARK: - Event-driven refresh

    // Watch the log for appends and fire a (debounced) reload. A vnode source on
    // the file fd delivers .write/.extend within ~tens of ms. On rotation (the
    // log is rewritten via `mv` past 5MB) the .rename/.delete event re-arms the
    // watch on the replacement file; if the log doesn't exist yet, retry until
    // the emitters create it.
    private func startWatching() {
        logWatcher?.cancel()
        logWatcher = nil
        let fd = open(logURL.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startWatching() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            let rotated = !src.data.intersection([.delete, .rename, .revoke]).isEmpty
            DispatchQueue.main.async {
                guard let self else { return }
                if rotated { self.startWatching() }   // re-arm on the replacement file
                self.scheduleReload()
            }
        }
        src.setCancelHandler { close(fd) }
        logWatcher = src
        src.resume()
    }

    // Coalesce a burst of appends (many sessions starting at once) into one
    // reparse ~40ms later, instead of one per line.
    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    // Start/stop the 1 Hz display+threshold tick. Idempotent; torn down at rest.
    private func updateActiveTick(_ active: Bool) {
        if active {
            guard activeTick == nil else { return }
            activeTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        } else {
            activeTick?.invalidate()
            activeTick = nil
        }
    }

    func focus(_ op: Op) {
        guard !op.surface.isEmpty || !op.cwd.isEmpty else { return }
        // Optimistically mark seen — the focus poll would catch it anyway,
        // but this clears the badge without the ~2s lag.
        if !op.surface.isEmpty {
            seenAt[op.surface] = now.timeIntervalSince1970
            persistSeen()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Self.focusScript, op.surface.isEmpty ? "-" : op.surface, op.cwd]
        try? p.run()
    }

    // Locate joystick-focus.sh without assuming the dev's ~/joystick checkout:
    // the copy bundled in the app works at any install location; fall back to
    // $JOYSTICK_HOME (where install.sh copies it) and finally the dev repo.
    // First existing path wins; the last candidate is the bare fallback.
    static let focusScript: String = {
        let home = ProcessInfo.processInfo.environment["JOYSTICK_HOME"] ?? "~/.config/joystick"
        let candidates = [
            Bundle.main.resourcePath.map { $0 + "/joystick-focus.sh" },
            (home as NSString).expandingTildeInPath + "/joystick-focus.sh",
            NSString(string: "~/joystick/joystick-focus.sh").expandingTildeInPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.last!
    }()

    // Incremental tail-parse: read only the bytes appended since last time and
    // fold each new event into parsedOpen/parsedDone. The log is append-only, so
    // steady-state cost is "parse the new line(s)", not "re-read 4000 lines" —
    // and because we accumulate rather than re-window, a long-running op's row no
    // longer vanishes when its `start` scrolls past the last-4000-line mark (now
    // common, since every Claude tool use appends an `active` line).
    private func parseLogIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let size = ((attrs?[.size] as? NSNumber)?.uint64Value) ?? 0
        guard mtime != lastLogMtime || size != lastLogSize else { return }
        lastLogMtime = mtime
        lastLogSize = size

        // Rotation/truncation (the log shrank or was replaced): re-read from top.
        if size < lastReadOffset { lastReadOffset = 0; parsedOpen = [:]; parsedDone = []; parsedMeta = [:] }

        guard let fh = try? FileHandle(forReadingFrom: logURL) else {
            lastReadOffset = 0; parsedOpen = [:]; parsedDone = []; parsedMeta = [:]
            return
        }
        defer { try? fh.close() }
        if lastReadOffset > 0 { try? fh.seek(toOffset: lastReadOffset) }
        guard let chunk = try? fh.readToEnd(), !chunk.isEmpty else { return }

        // Consume only up to the last newline; any trailing partial line stays in
        // the file and is re-read next time. (Lines are atomic <PIPE_BUF appends,
        // so this is belt-and-suspenders — but it keeps us robust against a
        // future producer that isn't line-atomic.)
        guard let lastNL = chunk.lastIndex(of: 0x0A) else { return }
        let cold = (lastReadOffset == 0)
        let completeLen = chunk.distance(from: chunk.startIndex, to: lastNL) + 1
        let complete = chunk.prefix(completeLen)
        lastReadOffset += UInt64(completeLen)

        let decoder = JSONDecoder()
        let allLines = Array(complete.split(separator: 0x0A, omittingEmptySubsequences: true))
        // Fold only the recent window on a cold read; everything on an incremental read.
        let foldStart = cold ? max(0, allLines.count - 4000) : 0
        // Count today's commands over all NEW lines incrementally, or over the whole
        // file during a day-change backfill. A plain cold read (rotation/restart)
        // counts nothing — the persisted tally already covers it.
        let countToday = needsBackfill || !cold
        let beforeCount = commandsToday
        for (i, line) in allLines.enumerated() {
            guard let e = try? decoder.decode(RawEvent.self, from: Data(line)) else { continue }
            if countToday, e.ev == "start", e.ts >= tallyDayStart, countsTowardTally(e) { commandsToday += 1 }
            if i >= foldStart { applyEvent(e) }
        }
        needsBackfill = false
        if commandsToday != beforeCount { persistTally() }
        if parsedDone.count > Self.maxDoneRetained {
            parsedDone.removeFirst(parsedDone.count - Self.maxDoneRetained)
        }
    }

    // If the local day has changed since the tally was last anchored, reset it and
    // force a cold re-read so the new day's count is backfilled from the log.
    private func rolloverTallyIfNeeded() {
        let dayStart = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        guard dayStart != tallyDayStart else { return }
        tallyDayStart = dayStart
        commandsToday = 0
        needsBackfill = true
        lastReadOffset = 0; parsedOpen = [:]; parsedDone = []; parsedMeta = [:]
        persistTally()
    }

    // Shell commands + Claude turns count toward the daily tally; external
    // `joystick log` events don't (they aren't commands you ran).
    private func countsTowardTally(_ e: RawEvent) -> Bool {
        let kind = e.kind ?? (e.tty == "claude" ? "claude" : e.tty == "cli" ? "external" : "shell")
        return kind == "shell" || kind == "claude"
    }

    private func persistTally() {
        UserDefaults.standard.set(commandsToday, forKey: "commandsToday")
        UserDefaults.standard.set(tallyDayStart, forKey: "tallyDayStart")
    }

    // Fold one event into the running state. Identical semantics whether applied
    // incrementally or over a full re-read — it's a left-fold over the log.
    private func applyEvent(_ e: RawEvent) {
        switch e.ev {
        case "start":
            // Prefer the explicit kind; fall back to the old tty sentinels for
            // events written before the kind field existed.
            let kind = e.kind ?? (e.tty == "claude" ? "claude"
                                  : e.tty == "cli" ? "external" : "shell")
            parsedOpen[e.id] = Op(key: e.id, cmd: e.cmd ?? "?", cwd: e.cwd ?? "",
                                  tty: e.tty ?? "", surface: e.surface ?? "", kind: kind,
                                  pid: e.pid ?? -1, start: e.ts)
        case "end":
            if var op = parsedOpen.removeValue(forKey: e.id) {
                op.endTs = e.ts
                op.exitCode = e.exit ?? 0
                op.dur = e.dur ?? max(0, e.ts - op.start)
                op.summary = e.msg        // Claude's closing blurb (claude turns only)
                parsedDone.append(op)
            }
        case "waiting":
            if var op = parsedOpen[e.id] {
                op.waitingSince = e.ts
                op.waitingMsg = e.msg
                op.activity = nil          // blocked on you, not running a tool
                parsedOpen[e.id] = op
            }
        case "active":
            if var op = parsedOpen[e.id] {
                op.waitingSince = nil
                op.waitingMsg = nil
                op.activity = e.act        // live "what it's doing now"
                parsedOpen[e.id] = op
            }
        case "meta":
            // Session metadata (title/model/mode/ctx). Keyed by claude-<sid>;
            // attached to the group's current op at render time. Emitted AFTER
            // the end event, so the op is already in `done` — keep it separate.
            parsedMeta[e.id] = SessionMeta(title: e.title ?? "", model: e.model ?? "",
                                           mode: e.mode ?? "", ctx: e.ctx ?? 0,
                                           name: e.name ?? "", color: e.color ?? "")
        default:
            break
        }
    }

    private func refreshTtyStates(ttys: Set<String>, nowTs: Double) {
        guard now.timeIntervalSince(lastStallCheck) >= 5 else { return }
        lastStallCheck = now
        let candidates = ttys.filter { !$0.isEmpty }   // already shell-only; real device ttys
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
    // being viewed — stamp it (and highlight its row). Cheap AppleScript, only
    // when Ghostty is frontmost (a background tab isn't "viewed"). Paced by the
    // focus tick (see updateFocusTick) at ~4 Hz; the 0.2s floor just dedupes
    // the overlap with reload()'s call while an op is running.
    private func pollFocusedSurface() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty",
              Date().timeIntervalSince(lastFocusPoll) >= 0.2 else { return }
        lastFocusPoll = Date()
        DispatchQueue.global(qos: .utility).async {
            let id = Self.fetchFocusedSurfaceId()
            DispatchQueue.main.async { [weak self] in
                guard let self, let id, !id.isEmpty else { return }
                self.seenAt[id] = Date().timeIntervalSince1970
                // Publish the highlight + persist seen-state only on an actual
                // focus CHANGE — otherwise a 1 Hz sample would redraw the whole
                // list every second while you sit in one tab. Not cleared on
                // blur: the highlight holds on the last tab you were in.
                if self.lastPersistedFocus != id {
                    self.lastPersistedFocus = id
                    self.focusedSurface = id
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

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Views

// Claude's brand orange (#D97757). Used for the thinking sparkle and the
// matching elapsed-time on an in-flight Claude row. The warm hue sits near the
// amber needs-you hand, but the sparkle shape + motion keep the two apart.
extension Color {
    init(hex: UInt) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    static let claudeOrange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

    // Claude Code's /color agent palette is the Dracula colors (extracted from the
    // CLI binary) — NOT SwiftUI's stock .purple etc., which look noticeably off.
    // These are the 8 names /color offers; unknown/empty → nil (neutral pill).
    static func claudeAgent(_ name: String) -> Color? {
        switch name.lowercased() {
        case "red":             return Color(hex: 0xff5858)
        case "orange":          return Color(hex: 0xffb86c)
        case "yellow":          return Color(hex: 0xf1fa8c)
        case "green":           return Color(hex: 0x50fa7b)
        case "cyan":            return Color(hex: 0x8be9fd)
        case "blue":            return Color(hex: 0x61afef)
        case "purple":          return Color(hex: 0xbd93f9)
        case "pink", "magenta": return Color(hex: 0xff79c6)
        default:                return nil
        }
    }
}

// The twinkling asterisk Claude shows while thinking, reproduced as a breathing
// star so a working Claude row reads at a glance. Frame-cycled (not tweened) to
// match the terminal spinner, in Claude's brand orange.
struct ClaudeThinkingIcon: View {
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let interval = 0.16

    var body: some View {
        // TimelineView drives the redraw and naturally pauses when the row
        // isn't on screen — no manual Timer to leak or reset on every reload.
        TimelineView(.periodic(from: .now, by: Self.interval)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
            Text(Self.frames[step % Self.frames.count])
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.claudeOrange)
                .frame(width: 16, height: 16)   // fixed box so glyph width can't jitter the row
        }
    }
}

// A row that needs you, shown as a soft yellow light that gently breathes —
// opacity (and a faint glow) eased in and out on a sine, calm rather than an
// attention-grabbing on/off blink. TimelineView drives the redraw, so it pauses
// when the row is off-screen and survives row reloads with no manual Timer/@State
// to leak or reset — same approach as ClaudeThinkingIcon.
struct WaitingLight: View {
    private static let period = 2.0          // seconds per full breath
    private static let fps = 24.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / Self.fps)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t / Self.period * 2 * Double.pi) + 1) / 2   // 0…1, smooth
            let level = 0.3 + 0.7 * phase                                // 0.3…1.0
            Image(systemName: "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
                .opacity(level)
                .shadow(color: .yellow.opacity(level * 0.7), radius: 3)   // breathing halo
                .frame(width: 16, height: 16)   // fixed box so it lines up with the other glyphs
        }
    }
}

// "claude-opus-4-8" -> "Opus", etc. for the meta badge.
func shortModel(_ m: String) -> String {
    let l = m.lowercased()
    if l.contains("opus") { return "Opus" }
    if l.contains("sonnet") { return "Sonnet" }
    if l.contains("haiku") { return "Haiku" }
    if l.contains("fable") { return "Fable" }
    return m
}

// The session's name — your rename if you set one, else Claude's auto topic —
// shown as a quiet eyebrow above the latest-prompt label: small, dim, no chrome,
// so it reads as identity and stays subordinate to the prompt. A pill was too
// loud here (it borrowed the ✋/▶/◉ status grammar for something that isn't
// state). When the session has an agent color, a small dot carries it — color
// without tinting the text, which keeps the name legible at any hue.
struct SessionEyebrow: View {
    let name: String
    let tint: Color?   // session's agent color; tints the pill (nil = neutral grey)

    var body: some View {
        let c = tint ?? .secondary
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(c)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(c.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(c.opacity(0.35), lineWidth: 0.5))
    }
}

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
                // The label is always the latest command/prompt — the session's
                // name/topic lives in the badge above (see GroupRow).
                Text(op.cmd)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                if let blurb = op.summary, !blurb.isEmpty, !op.isRunning {
                    // What Claude said when it finished — the reply, distinct
                    // from the prompt above and the metadata below.
                    Text("↳ \(blurb)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(timeText)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(op.isService ? Color.green
                                 : (op.isRunning && op.isClaude && !op.isWaiting) ? Color.claudeOrange
                                 : op.isRunning ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 3)
    }

    private var statusIcon: some View {
        Group {
            if op.isWaiting {
                WaitingLight()         // soft yellow breathing light = needs you
            } else if op.isService {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
            } else if op.isRunning && op.isClaude {
                ClaudeThinkingIcon()   // twinkling sparkle while a turn is in flight
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
        } else if op.isRunning, let act = op.activity, !act.isEmpty {
            parts.append("⚙ \(act)")       // live agent activity (PostToolUse)
        } else if op.isService {
            parts.append("serving")
        }
        parts.append(tilde(op.cwd))
        if !op.tty.isEmpty { parts.append(op.tty) }
        if let code = op.exitCode, code != 0 {
            parts.append(code == -1 ? "killed" : "exit \(code)")
        }
        if let end = op.endTs { parts.append(fmt(nowTs - end) + " ago") }
        if op.isClaude {   // session context fill + model + notable mode (from meta)
            if op.ctxTokens > 0 {
                let limit = op.ctxTokens > 200_000 ? 1_000_000.0 : 200_000.0
                parts.append("\(Int((op.ctxTokens / limit) * 100))% ctx")
            }
            if !op.model.isEmpty { parts.append(shortModel(op.model)) }
            if op.mode == "bypassPermissions" { parts.append("⚠ bypass") }
        }
        return parts.joined(separator: " · ")
    }

    private var timeText: String {
        op.isRunning ? fmt(nowTs - op.start) : fmt(op.dur ?? 0)
    }
}

struct GroupRow: View {
    let group: SurfaceGroup
    let nowTs: Double
    var focusedSurface: String? = nil
    let action: () -> Void

    // Is this the Ghostty tab/split focused right now? Shell rows group BY
    // surface (group.key), so that's an exact hit. Claude rows group by
    // claude-<sid> and carry only a best-effort surface snapshot on current.surface
    // — match that too, so Claude rows highlight when the snapshot is good and
    // simply don't when it's stale (graceful, consistent with how that data behaves).
    private var isFocused: Bool {
        guard let f = focusedSurface, !f.isEmpty else { return false }
        return f == group.key || f == group.current.surface
    }

    var body: some View {
        // One-tap focus is THE feature, so it has to be rock-solid. We tried
        // making the row's text selectable (drag to highlight, ⌘C to copy) while
        // a gesture handled the tap, but macOS text selection installs its own
        // mouse handling on the glyphs and swallows the click wherever it lands
        // on text — which is most of the row — so clicking selected instead of
        // focusing. No simultaneous/high-priority gesture beats it reliably.
        // So: text is NOT selectable; the whole row is a plain click → focus,
        // and copy lives in the right-click menu (whole command / directory).
        VStack(alignment: .leading, spacing: 1) {
            // Eyebrow above the prompt: your rename pill (if set) + Claude's
            // auto-generated session topic, both shown. The prompt stays the
            // label below. The pill is tinted by the session's agent color.
            let badgeName = group.current.sessionName
            let topic = group.current.title
            if !badgeName.isEmpty || !topic.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 43)   // align under the command text
                    if !badgeName.isEmpty {
                        SessionEyebrow(name: badgeName,
                                       tint: Color.claudeAgent(group.current.agentColor))
                    }
                    if !topic.isEmpty {
                        Text(topic)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
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
                .contentShape(Rectangle())
                // Right-clicking a specific history line copies that line's
                // command (innermost context menu wins over the row's).
                .contextMenu { copyMenu(for: op) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .help("Click to focus this tab in Ghostty · right-click to copy")
        .contextMenu { copyMenu(for: group.current) }
        // "You are here": tint the row for the surface focused in Ghostty right
        // now. Neutral grey (the system's inactive-selection fill), like a
        // dimmed Ghostty split — quiet on purpose, so it never competes with the
        // colored ✋/▶/◉/✓/✗ state glyphs.
        .listRowBackground(
            isFocused ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
                      : Color.clear
        )
    }

    // Right-click → copy. Command first (the row's main text), then its
    // directory. cmd is copied as shown (Claude rows keep their 🤖 prefix).
    @ViewBuilder
    private func copyMenu(for op: Op) -> some View {
        Button { copyToPasteboard(op.cmd) } label: { Label("Copy command", systemImage: "doc.on.doc") }
        if !op.cwd.isEmpty {
            Button { copyToPasteboard(op.cwd) } label: { Label("Copy directory", systemImage: "folder") }
        }
    }

    private func historyLine(_ op: Op) -> String {
        let mark = (op.exitCode ?? 0) == 0 ? "✓" : "✗"
        let ago = fmt(nowTs - (op.endTs ?? nowTs))
        return "\(mark) \(op.cmd) — \(fmt(op.dur ?? 0)) (\(ago) ago)"
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var floatOnTop = true
    @State private var copiedPrompt = false

    // First-run onboarding without a wizard: the user pastes this into Claude
    // Code, which runs the bundled installer (shell + Claude hooks). Claude
    // adapts to their environment and explains the diffs — the onboarding UI we
    // don't have to build. install.sh ships in the app bundle's Resources.
    static var onboardingPrompt: String {
        let installer = Bundle.main.resourcePath.map { $0 + "/install.sh" } ?? "~/joystick/install.sh"
        return "Set up Joystick on this Mac: run the installer at \"\(installer)\" — "
            + "it wires up the zsh shell hook and Claude Code hooks, is idempotent, and "
            + "backs up every file it edits. Then tell me in one line what it changed and "
            + "how to undo it."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            opList
        }
        .frame(minWidth: 400, minHeight: 320)
        .onAppear {
            store.reload()
            // Apply the default pin state — onChange only fires on a *change*,
            // so without this the toggle would read "on" while windows stayed
            // at .normal until the first manual toggle.
            for w in NSApp.windows { w.level = floatOnTop ? .floating : .normal }
        }
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
            Text("❯ \(store.commandsToday) today")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .help("Shell commands + Claude turns started today")
            Button {
                copyToPasteboard(Self.onboardingPrompt)
                copiedPrompt = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPrompt = false }
            } label: {
                Label(copiedPrompt ? "Copied — paste into Claude" : "Set up",
                      systemImage: copiedPrompt ? "checkmark" : "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy a prompt that installs Joystick's shell + Claude hooks — paste it into Claude Code")
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
                        GroupRow(group: g, nowTs: nowTs, focusedSurface: store.focusedSurface) { store.focus(g.current) }
                    }
                }
            }
            if !store.idleGroups.isEmpty {
                Section("Finished") {
                    ForEach(store.idleGroups) { g in
                        GroupRow(group: g, nowTs: nowTs, focusedSurface: store.focusedSurface) { store.focus(g.current) }
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
