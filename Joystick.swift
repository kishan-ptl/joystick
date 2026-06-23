// Joystick — live dashboard of operations running across all terminal tabs.
// Reads ~/.local/state/joystick/events.jsonl (written by joystick.zsh and
// claude-hook.sh). Click a row to focus that Ghostty tab.
// Build with ~/joystick/build-app.sh

import SwiftUI
import AppKit
import Combine
import Darwin
import Carbon   // RegisterEventHotKey — global summon shortcut, no a11y prompt

// MARK: - App-only types
//
// The log event model, the folded `Op`/`SurfaceGroup`/`SessionMeta`, and the pure
// `EventFold` (the left-fold of the log) live in EventLog.swift — Foundation-only,
// so they compile and unit-test without SwiftUI. See tests/eventfold-test.swift.

// Outcome of running the in-app setup (install.sh).
enum SetupResult: Equatable { case ok, failed(String) }

// Apple Events permission to control Ghostty (drives click-to-focus). .denied
// means the user said no (or it's off in Privacy settings) — we surface a banner.
enum AutomationStatus { case granted, denied, notDetermined, unknown }

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var activeGroups: [SurfaceGroup] = []
    @Published var idleGroups: [SurfaceGroup] = []
    // Flat, first-seen-ordered list of ALL terminals (running + finished) for
    // the keyboard-nav window. Stable slots — see slotOrder in reload().
    @Published var orderedGroups: [SurfaceGroup] = []
    @Published var now = Date()
    @Published var commandsToday = 0   // shell + Claude turns started today (4am-aligned, local)
    // First-run onboarding state. shellWired/claudeWired reflect whether the zsh
    // hook and Claude hooks are actually present; the banner uses them to offer
    // one-click setup (running the bundled install.sh) instead of manual steps.
    @Published var shellWired = false
    @Published var claudeWired = false
    @Published var isSettingUp = false
    @Published var setupResult: SetupResult? = nil
    @Published var automation: AutomationStatus = .unknown
    var needsSetup: Bool { !shellWired || !claudeWired }
    // Show the onboarding banner while unwired, and briefly after a successful
    // run (to show the "open a new terminal" nudge until dismissed).
    var showSetupBanner: Bool {
        if needsSetup { return true }
        if case .ok = setupResult { return true }
        return false
    }
    // Surface id of the Ghostty tab/split focused right now (or most recently,
    // while you're away in another app — we deliberately DON'T clear it on blur,
    // so the highlight keeps pointing at "where you were" — that's the get-back-
    // to-the-right-tab use case). Drives the focused-row highlight in GroupRow.
    @Published var focusedSurface: String? = nil

    // Keyboard navigation (window only). filterText is the type-to-filter query;
    // selectedKey is the group.key under the keyboard cursor. We anchor the
    // cursor to the STABLE group identity, never an index — so as the live list
    // re-sorts (a terminal flips to "waiting" and jumps to the top), the
    // highlight follows the row you meant instead of the slot it used to be in.
    @Published var filterText = ""
    @Published var selectedKey: String? = nil

    static let minRunningSecs = 5.0
    static let minDoneSecs = 10.0
    static let doneWindowSecs = 6.0 * 3600
    static let externalTTL = 24.0 * 3600   // running `joystick log` ops dropped after this with no end
    static let pidReuseMargin = 120.0      // slack for the pid-reuse identity check (alive()); a host that
                                           // started >2min after its op began is a recycled pid, not ours
    static let maxDone = 20
    static let historyCap = 3
    static let ignore: Set<String> = ["claude", "claude2", "vim", "nvim", "less", "man", "top", "htop", "tmux"]
    nonisolated static let stallSecs = 20.0
    static let backstopSecs = 10.0   // safety-net reload cadence; the FS watch does the real work

    enum TtyState: Sendable { case waiting(Double), service([Int]) }

    private var ttyStates: [String: TtyState] = [:]
    private var lastStallCheck = Date.distantPast
    private var notifiedWaiting: Set<String> = []
    // First-seen order of group keys, preserved across reloads (new keys
    // appended, vanished keys removed) — the stable slots for orderedGroups.
    private var slotOrder: [String] = []
    // Parsed log cache — re-parse only when (mtime, size) move, and then read
    // only the bytes appended since lastReadOffset, folding each new event into
    // the maps below. A full re-read happens only on rotation/truncation.
    private var lastLogMtime = Date.distantPast
    private var lastLogSize: UInt64 = .max
    private var lastReadOffset: UInt64 = 0   // bytes of the log already folded in
    private var fold = EventFold()            // pure left-fold of the log → open/done/meta
    private var lastPersistedFocus: String? = nil
    private var liveSurfaces: Set<String>? = nil
    private var lastSurfacePoll = Date.distantPast
    private var lastFocusPoll = Date.distantPast
    // surface id -> last time it was focused while Ghostty was frontmost
    private var seenAt: [String: Double] = [:]
    // group key -> when the user right-click "Clear"ed its waiting light. We
    // suppress only the wait instance that was live at that moment; a genuinely
    // newer wait (Claude re-prompts, or a fresh stall after output resumes)
    // starts after this stamp and re-raises the light. In-memory only — the
    // wait is itself a live signal, so after an app restart it's right to show
    // a still-blocked terminal again (unlike seenAt, which must outlive launches).
    private var clearedWaitingAt: [String: Double] = [:]
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
    // Today's turn tally (shell + Claude turns since the 4am day boundary).
    // Driven incrementally as starts are folded; recomputed from the log on the
    // 4am roll (backfill), and persisted so it survives restarts and log
    // rotation. tallyDayStart is that 4am-aligned day-start instant.
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
        // Restore the user's manual row order; reload() then drops gone keys and
        // appends any new ones, so a saved order survives across launches.
        slotOrder = UserDefaults.standard.stringArray(forKey: "slotOrder") ?? []
        commandsToday = UserDefaults.standard.integer(forKey: "commandsToday")
        tallyDayStart = UserDefaults.standard.double(forKey: "tallyDayStart")
        refreshWiring()
        refreshAutomation()
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

    // Are the shell + Claude hooks actually wired? We look for the marker
    // substrings rather than the exact install.sh block, so a hand-wired or
    // dev-repo setup (sourcing from ~/joystick) reads as installed too. Honors
    // the same env overrides install.sh uses, which keeps it testable.
    func refreshWiring() {
        let env = ProcessInfo.processInfo.environment
        func read(_ p: String) -> String {
            (try? String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
        }
        let zshrc = env["JOYSTICK_ZSHRC"] ?? ((env["ZDOTDIR"] ?? NSHomeDirectory()) + "/.zshrc")
        let claude = env["JOYSTICK_CLAUDE_SETTINGS"] ?? (NSHomeDirectory() + "/.claude/settings.json")
        shellWired = read(zshrc).contains("joystick.zsh")
        claudeWired = read(claude).contains("claude-hook.sh")
    }

    // One-click first-run setup: run the bundled install.sh, which wires the zsh
    // hook + Claude hooks (idempotent, backs up every file it edits). Finder-
    // launched apps inherit a minimal PATH, so prepend Homebrew's bins — install.sh
    // needs `jq`, which is often brew-only. Re-checks wiring when done.
    func runSetup() {
        guard let res = Bundle.main.resourcePath else { setupResult = .failed("App resources missing"); return }
        let installer = res + "/install.sh"
        guard FileManager.default.fileExists(atPath: installer) else {
            setupResult = .failed("Installer missing from app bundle"); return
        }
        // install.sh needs jq to merge the Claude hooks. Check up front so we
        // give a clear message instead of a partial wiring + cryptic failure.
        // (The Homebrew cask also declares depends_on jq, covering brew installs.)
        guard Self.jqPath() != nil else {
            setupResult = .failed("jq is required. Install it with:  brew install jq"); return
        }
        isSettingUp = true
        setupResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [installer]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var output = "", code: Int32 = -1
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()   // drain before wait (no deadlock)
                p.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
                code = p.terminationStatus
            } catch {
                output = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.isSettingUp = false
                self.refreshWiring()
                if code == 0 && !self.needsSetup {
                    self.setupResult = .ok
                    // Hooks are wired — ask for Ghostty automation now, so the first
                    // click-to-focus isn't a surprise system prompt later.
                    _ = self.ghosttyAutomation(prompt: true)
                    self.refreshAutomation()
                } else {
                    let last = output.split(whereSeparator: \.isNewline).last.map(String.init)
                    self.setupResult = .failed(last ?? "Setup failed — check that jq is installed")
                }
            }
        }
    }

    // First jq on the likely PATHs (Finder-launched apps don't inherit the shell's).
    nonisolated static func jqPath() -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { $0 + "/jq" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Whether we're allowed to send Apple Events to Ghostty (click-to-focus).
    // prompt=false reports status silently; prompt=true shows the one-time
    // consent dialog when undetermined. .unknown covers "Ghostty not running".
    @discardableResult
    func ghosttyAutomation(prompt: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.mitchellh.ghostty")
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, prompt)
        if status == noErr { return .granted }
        if status == OSStatus(errAEEventNotPermitted) { return .denied }
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .notDetermined }
        return .unknown   // procNotFound (Ghostty not running), etc.
    }

    func refreshAutomation() { automation = ghosttyAutomation(prompt: false) }

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

        // Free open ops whose host is gone (closed tab / quit session / expired
        // external). The running filter would hide them anyway; pruning here is what
        // stops fold.open growing unbounded between rotations, and keeps a stale id
        // from mis-feeding the Claude late-end merge in EventFold.apply.
        fold.pruneOpen { opHostAlive($0, nowTs: nowTs) }

        // fold.open now holds only live-host ops, so this is just the cosmetic gate:
        // hide ignored interactive apps, and debounce trivial shell noise (a
        // blink-and-gone `ls`/`cd` never flashes a row). External + Claude rows are
        // each a deliberate event — show them the instant they start, so a turn that
        // finishes in <minRunningSecs doesn't fall into the dead zone between "too
        // young to show running" and "too short to show done".
        var running = fold.open.values
            .filter { op in
                guard !ignored(op.cmd) else { return false }
                return op.isExternal || op.isClaude || nowTs - op.start >= Self.minRunningSecs
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
                case .service(let ports): op.isService = true; op.ports = ports
                case nil: break
                }
            }
            // Right-click "Clear" (see clearRow) dismisses the wait that was live
            // when you cleared. A Claude wait starts at waitingSince; a shell stall
            // started ~stallIdle seconds ago. While that same instance persists its
            // start stays <= the clear stamp, so it stays hidden; a fresh wait later
            // starts after it and shows again. The slop absorbs the 5s probe jitter.
            if let cleared = clearedWaitingAt[op.groupKey],
               let waitStart = op.waitingSince ?? op.stallIdle.map({ nowTs - $0 }),
               waitStart <= cleared + 1.5 {
                op.waitingSince = nil; op.waitingMsg = nil; op.stallIdle = nil
            }
            return op
        }
        // Drop clear-stamps whose terminal/session is no longer running — a wait
        // can only reappear on something live, so the rest are dead weight.
        if !clearedWaitingAt.isEmpty {
            let liveKeys = Set(running.map(\.groupKey))
            clearedWaitingAt = clearedWaitingAt.filter { liveKeys.contains($0.key) }
        }
        notifyNewlyWaiting(running: running)

        // minDoneSecs hides trivial finished shell commands (a 2s `ls` leaves no
        // row). Claude turns and external events are always meaningful — keep them
        // regardless of duration, so a quick turn doesn't vanish into the gap
        // between "too young to show running" and "too short to show done".
        let shown = fold.done.filter {
            ($0.isExternal || $0.isClaude || ($0.dur ?? 0) >= Self.minDoneSecs) && !ignored($0.cmd)
        }
        // A live Claude session between turns sits in `done` (its last turn ended)
        // while the process stays alive — that's its normal resting state, the live
        // session mission-control exists to mirror, NOT stale history. So it must
        // survive the staleness cleanups (doneWindowSecs age-out, maxDone count cap)
        // that exist to forget old shell results: keep every alive-Claude op, and
        // apply window + cap only to the rest. Liveness (the pid gate below) stays the
        // sole arbiter for these rows, per Principle #1. See NOTES.md.
        var liveClaude: [Op] = [], rest: [Op] = []
        for op in shown {
            if op.isClaude && alive(op.pid, since: op.start) { liveClaude.append(op) } else { rest.append(op) }
        }
        let capped = Array(rest
            .filter { nowTs - ($0.endTs ?? 0) <= Self.doneWindowSecs }
            .sorted { ($0.endTs ?? 0) > ($1.endTs ?? 0) }
            .prefix(Self.maxDone))
        var finished = (liveClaude + capped).sorted { ($0.endTs ?? 0) > ($1.endTs ?? 0) }

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
            if op.isClaude { return !alive(op.pid, since: op.start) }
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
            // A session with live background work — shells (run_in_background) or
            // subagents still running after the turn closed — is still WORKING, so
            // it stays in the active (Running) section instead of dropping to
            // Finished the instant its turn ends. Keeps such a row pinned in one
            // place rather than teleporting between sections as the turn flips.
            let liveBg = !(fold.bgShells[key]?.isEmpty ?? true)
                || !(fold.subagents[key]?.isEmpty ?? true)
            if g.current.isRunning || liveBg { active.append(g) } else { idle.append(g) }
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
            var g = g
            if let m = fold.meta[g.key] {
                g.current.title = m.title; g.current.model = m.model
                g.current.mode = m.mode; g.current.ctxTokens = m.ctx
                g.current.sessionName = m.name; g.current.agentColor = m.color
                g.current.worktree = m.wt; g.current.goal = m.goal
            }
            // Background shells and subagents are session-scoped and outlive the
            // launching turn, so attach them whatever the current op's state (a running
            // turn, or a done one whose shells/agents are still going).
            g.current.bgShells = fold.bgShells[g.key] ?? []
            g.current.liveSubagents = fold.subagents[g.key] ?? []
            return g
        }
        activeGroups = active.map(withMeta)
        idleGroups = idle.map(withMeta)

        // Stable order for the keyboard-nav window: each terminal keeps its slot
        // for life (state lives in the glyph, not the position); new terminals
        // join at the TOP (newest first), closed ones drop out. We never *auto*-
        // reorder existing slots, so ↑/↓ cycling and ⌘1–9 stay put — only the
        // user reorders, by hand, via ⌘↑/⌘↓ or the row's right-click menu
        // (moveRow, below), and that order persists like any other slot order.
        let present = Set(bySurface.keys)
        let prevSlots = slotOrder
        slotOrder.removeAll { !present.contains($0) }
        let fresh = bySurface.keys.filter { !slotOrder.contains($0) }
            .sorted { bySurface[$0]!.current.start > bySurface[$1]!.current.start }
        slotOrder.insert(contentsOf: fresh, at: 0)
        if slotOrder != prevSlots { persistSlotOrder() }
        orderedGroups = slotOrder.compactMap { bySurface[$0] }.map(withMeta)

        // Keep the keyboard cursor on a still-visible row as terminals come and go.
        ensureSelection()

        let unseenCount = idle.filter { $0.current.unseen }.count
        NSApp.dockTile.badgeLabel = unseenCount > 0 ? "\(unseenCount)" : nil

        // Run the 1 Hz tick only while something is (or is about to become)
        // running — it advances elapsed-time labels, crosses the minRunningSecs
        // visibility threshold, re-evaluates the stall heuristic, and drops rows
        // whose pid died without an `end`. With no live open op there's nothing
        // to animate, so the tick is torn down and the app idles silently; the
        // FS watch alone wakes it when the next event lands.
        let liveOpen = fold.open.values.contains { opHostAlive($0, nowTs: nowTs) }
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

    // Manually re-flag a finished row as unread (right-click → "Mark unread").
    // Reuses the surface-based seen model rather than adding new state: rewind
    // seenAt for this op's surface to just before it ended, so the blue unseen
    // dot and the dock tally come back. It then clears the organic way — the next
    // time that Ghostty tab is focused, pollFocusedSurface stamps seenAt = now —
    // exactly like a naturally-unseen result. No-op for running / external /
    // surfaceless ops (nothing to rewind to).
    func markUnread(_ op: Op) {
        guard !op.surface.isEmpty, let end = op.endTs else { return }
        seenAt[op.surface] = end - 1
        persistSeen()
        reload()
    }

    // Right-click → "Clear": acknowledge whatever this row is flagging, without
    // switching to the tab. A row flags exactly one thing at a time — the breathing
    // waiting light (running) or the blue unseen dot (finished) — so one action
    // covers both. Each reuses an organic, self-healing model rather than a sticky
    // "dismissed" flag: marking seen is exactly what focusing the tab does, and the
    // waiting stamp only hides the current wait (a new prompt/stall re-raises it).
    func clearRow(_ op: Op) {
        if op.isWaiting {
            clearedWaitingAt[op.groupKey] = now.timeIntervalSince1970
        } else if op.unseen, !op.surface.isEmpty {
            seenAt[op.surface] = now.timeIntervalSince1970
            persistSeen()
        }
        reload()
    }

    // MARK: - Keyboard navigation

    // Does this group match the current type-to-filter query? (Empty query = all.)
    func matchesFilter(_ g: SurfaceGroup) -> Bool {
        guard !filterText.isEmpty else { return true }
        let q = filterText.lowercased()
        let c = g.current
        return c.cmd.lowercased().contains(q)
            || tilde(c.cwd).lowercased().contains(q)
            || c.title.lowercased().contains(q)
            || c.sessionName.lowercased().contains(q)
    }
    // The keyboard-nav list reads from the stable flat order, narrowed by the
    // filter. Rendering and ↑/↓ navigation share this one list, so the cursor
    // can't land on a row you can't see.
    var visibleGroups: [SurfaceGroup] { orderedGroups.filter(matchesFilter) }

    // Keep the cursor on a real, visible row. If the selected row vanished
    // (closed, finished-aged-out, filtered away), fall back to the top visible
    // row — which, given the sort, is the top "needs you" row when one exists,
    // so summon → ⏎ does the obvious thing with zero arrow presses.
    func ensureSelection() {
        let keys = visibleGroups.map(\.key)
        if selectedKey == nil || !keys.contains(selectedKey!) {
            selectedKey = keys.first
        }
    }

    // On summon, pre-aim the cursor: the first row that needs you (so summon → ⏎
    // jumps straight to what's waiting), else the tab you're already in, else the
    // top row. With a fixed order there's no "top = most urgent", so we go FIND
    // the urgent one instead of assuming it floated up.
    func selectForSummon() {
        let order = visibleGroups
        guard !order.isEmpty else { selectedKey = nil; return }
        if let waiting = order.first(where: { $0.current.isWaiting }) {
            selectedKey = waiting.key
        } else if let f = focusedSurface, !f.isEmpty,
                  let here = order.first(where: { $0.key == f || $0.current.surface == f }) {
            selectedKey = here.key
        } else {
            selectedKey = order.first!.key
        }
    }

    func moveSelection(_ delta: Int) {
        let keys = visibleGroups.map(\.key)
        guard !keys.isEmpty else { selectedKey = nil; return }
        if let cur = selectedKey.flatMap({ keys.firstIndex(of: $0) }) {
            let n = keys.count
            selectedKey = keys[((cur + delta) % n + n) % n]   // wrap both ends (↓ last → first)
        } else {
            selectedKey = delta >= 0 ? keys.first : keys.last
        }
    }

    // ⌘↑ / ⌘↓ (and the right-click "Move up/down"): nudge a row one place in the
    // persisted slot order. We reorder the row's position in the VISIBLE list —
    // not the raw slotOrder — so that with a filter active it moves past the rows
    // you actually see, leaving hidden (filtered-out) rows pinned where they sit.
    // It WRAPS, like the cursor does: ⌘↓ on the bottom row jumps it to the top
    // (⌘↑ on the top row to the bottom) — so with two rows it's a straight swap.
    // The cursor follows the moved row.
    @discardableResult
    func moveRow(_ key: String, _ delta: Int) -> Bool {
        var vis = visibleGroups.map(\.key)
        guard vis.count > 1, let vi = vis.firstIndex(of: key) else { return false }
        let vj = ((vi + delta) % vis.count + vis.count) % vis.count   // wrap both ends
        vis.remove(at: vi)
        vis.insert(key, at: vj)
        // Stitch the reordered visible sequence back into slotOrder: at each slot
        // that holds a visible key, drop in the next key from the new order; the
        // hidden ones keep their exact slots. (Counts match — every visible key is
        // in slotOrder exactly once — so the iterator never runs dry.)
        let visibleSet = Set(vis)
        var next = vis.makeIterator()
        slotOrder = slotOrder.map { visibleSet.contains($0) ? next.next()! : $0 }
        persistSlotOrder()
        // Re-sort the rendered list to the new slotOrder now, rather than waiting
        // for the next reload() — same groups, just reindexed by the new order.
        let byKey = Dictionary(orderedGroups.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        orderedGroups = slotOrder.compactMap { byKey[$0] }
        selectedKey = key
        return true
    }

    @discardableResult
    func moveSelectedRow(_ delta: Int) -> Bool {
        guard let key = selectedKey else { return false }
        return moveRow(key, delta)
    }

    private func selectedGroup() -> SurfaceGroup? {
        selectedKey.flatMap { k in visibleGroups.first { $0.key == k } }
    }

    // ⏎ — focus the selected row's terminal. Returns false when nothing's
    // selected, so the caller knows not to dismiss the window.
    @discardableResult
    func activateSelection() -> Bool {
        guard let g = selectedGroup() else { return false }
        focus(g.current)
        return true
    }

    // ⌘1…⌘9 — jump straight to the Nth visible row and focus it.
    @discardableResult
    func jump(toIndex i: Int) -> Bool {
        let order = visibleGroups
        guard i >= 0, i < order.count else { return false }
        selectedKey = order[i].key
        focus(order[i].current)
        return true
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
    // fold each new event into fold.open/fold.done. The log is append-only, so
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
        if size < lastReadOffset { lastReadOffset = 0; fold.reset() }

        guard let fh = try? FileHandle(forReadingFrom: logURL) else {
            lastReadOffset = 0; fold.reset()
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
        // Fold the WHOLE file, cold read included. A cold read happens on launch, on
        // the 4am rollover, and on rotation — and an earlier "last 4000 lines only"
        // cold window silently dropped any op whose `start` had scrolled past line
        // 4000. Long-running services (npx expo start, next dev, ngrok) have the
        // OLDEST starts, so they were the first to vanish on the next restart/rollover
        // even while their process stayed alive. The fold is bounded regardless: the
        // log rotates at ~5MB and `done` is trimmed to maxDoneRetained below.
        let foldStart = 0
        // Count today's commands over all NEW lines incrementally, or over the whole
        // file during a day-change backfill. A plain cold read (rotation/restart)
        // counts nothing — the persisted tally already covers it.
        let countToday = needsBackfill || !cold
        let beforeCount = commandsToday
        for (i, line) in allLines.enumerated() {
            guard let e = try? decoder.decode(RawEvent.self, from: Data(line)) else { continue }
            if countToday, e.ev == "start", e.ts >= tallyDayStart, EventFold.countsTowardTally(e) { commandsToday += 1 }
            if i >= foldStart { fold.apply(e) }
        }
        needsBackfill = false
        if commandsToday != beforeCount { persistTally() }
        fold.trimDone()
    }

    // If the 4am day boundary has moved since the tally was last anchored, reset
    // and force a cold re-read so the new day's count is backfilled from the log.
    // Clearing the fold would otherwise blank every row until the
    // next log event, because parseLogIfChanged's mtime/size gate skips an
    // unchanged file — so we also invalidate that cache to guarantee the re-read.
    private func rolloverTallyIfNeeded() {
        let dayStart = EventFold.fourAMDayStart(now)
        guard dayStart != tallyDayStart else { return }
        tallyDayStart = dayStart
        commandsToday = 0
        needsBackfill = true
        lastReadOffset = 0; fold.reset()
        lastLogMtime = .distantPast; lastLogSize = .max   // force parseLogIfChanged to re-read
        persistTally()
    }

    private func persistTally() {
        UserDefaults.standard.set(commandsToday, forKey: "commandsToday")
        UserDefaults.standard.set(tallyDayStart, forKey: "tallyDayStart")
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

    // kill(pid,0) proves only that SOME process holds this number right now — not
    // that it's STILL ours. macOS recycles pids, so a long-gone session's pid can
    // resurface as an unrelated daemon and pin a dead row open forever (seen in the
    // wild: a closed Claude session whose pid 5418 came back as `seputil`, its row
    // stuck at "waiting on your reply" for a day). `opStart` lets us confirm
    // identity: a host process must predate the op it runs, so a process that
    // started AFTER the op began can't be the real host. The margin absorbs the
    // sub-second case where a session's first event lands in the same whole-clock
    // second its process launched (the log clock is whole seconds). Callers that
    // pass no opStart (default 0) get the old existence-only check.
    private func alive(_ pid: Int32, since opStart: Double = 0) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard opStart > 0, let started = procStartTime(pid) else { return true }
        return started <= opStart + Self.pidReuseMargin
    }

    // Wall-clock start time of pid's CURRENT process (epoch seconds), or nil if it
    // can't be read. sysctl(KERN_PROC_PID) — a single syscall, no subprocess. Used
    // only to defeat pid reuse in `alive` above.
    private func procStartTime(_ pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    // Is an open op's host still around? A shell/Claude op lives while its process
    // does (tab open / session running); an external `joystick log` op (no local
    // pid) lives until its TTL elapses. Single source of truth: the running-view
    // filter, the active-tick liveOpen check, and fold pruning all gate on
    // this, so "hidden from the view" and "freed from memory" can't drift apart.
    private func opHostAlive(_ op: Op, nowTs: Double) -> Bool {
        op.isExternal ? (nowTs - op.start < Self.externalTTL) : alive(op.pid, since: op.start)
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
        let ports = listeningPorts(pids: fgPids)
        if !ports.isEmpty { return .service(ports) }
        if busy || idle < stallSecs { return nil }
        return .waiting(idle)
    }

    // The listening TCP ports the given pids hold, sorted and de-duped. Empty ⇒
    // not a service. Same lsof query we used to gate service detection, minus the
    // `-t` (terse, pids-only) flag so we keep the address:port column we were
    // throwing away — plus `-P -n` to keep ports/hosts numeric (no /etc/services
    // name resolution, so "3000" not "hbci"; also faster). A process that listens
    // on both IPv4 and IPv6 of one port shows two lines → the de-dupe collapses
    // them. Cost is unchanged: one lsof call per probed tty, as before.
    nonisolated static func listeningPorts(pids: [String]) -> [Int] {
        guard !pids.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", pids.joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return [] }
        var ports: [Int] = []
        for line in out.split(separator: "\n") where line.contains("(LISTEN)") {
            // NAME column is "TCP <addr>:<port>"; the addr:port token (e.g. *:3000,
            // 127.0.0.1:3000, [::1]:3000) sits just before the "(LISTEN)" token.
            let toks = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let li = toks.firstIndex(of: "(LISTEN)"), li > 0,
                  let colon = toks[li - 1].lastIndex(of: ":") else { continue }
            if let port = Int(toks[li - 1][toks[li - 1].index(after: colon)...]),
               !ports.contains(port) { ports.append(port) }
        }
        return ports.sorted()
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

    private func persistSlotOrder() {
        UserDefaults.standard.set(slotOrder, forKey: "slotOrder")
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

// Long worktree paths (~/fndr/oasis/.claude/worktrees/foo) swamp the metadata
// line, so once a path runs deep we keep the first three segments (root + repo)
// and the leaf, eliding the middle with "…". Shallow paths pass through whole.
// Display-only — copy still uses the full op.cwd.
func elidePath(_ path: String) -> String {
    let t = tilde(path)
    let parts = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 5 else { return t }
    return (parts.prefix(3) + ["…"] + parts.suffix(1)).joined(separator: "/")
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

    // ctx-fill warnings on Claude rows: warm gold at 80%+, red at 90%+. Reuses
    // the waiting light's gold (0xFFC107) and the agent palette's Dracula red.
    static let ctxWarn = Color(hex: 0xFFC107)
    static let ctxDanger = Color(hex: 0xff5858)

    // Directory path tint: a desaturated cool slate, deliberately OFF every STATE
    // hue (gold 0xFFC107 = waiting / ctx-warn, terracotta claudeOrange = Claude
    // working, sage = serving) so a tinted path reads as a quiet reference label,
    // never as status. Was a warm dusty-rose (0xC08497) — too saturated, it read
    // as the loudest thing on the row; muting it to neutral slate calms the whole
    // view and lets the gold topic + state glyphs carry the eye. Mid-tone so it
    // still carries on the dark window vibrancy. One knob for the directory color.
    static let dirTint = Color(hex: 0x8B93A3)

    // Serving (◉) is ambient infrastructure that by definition never needs you,
    // so it must be the QUIETEST state — not the loud Dracula success green
    // (0x50fa7b) it used to borrow, which made always-up services pull the eye
    // like a fresh ✓. A desaturated sage: still legibly "green = healthy/up",
    // but settled into the background. One knob to tune how far serving recedes.
    static let servingGreen = Color(hex: 0x6E9C7E)

    // Claude's auto-generated topic (the inferred session-title eyebrow above a
    // row) — a pale gold so the inferred summary reads as a soft warm tint, set
    // apart from the neutral-grey prompt and metadata without pulling the eye like
    // the warm STATE hues. Kept subtle so it recedes on the window vibrancy rather
    // than announcing itself.
    static let summaryYellow = Color(hex: 0xDCC98F)

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

// A row that needs you, shown as a soft golden light that gently breathes —
// opacity eased in and out on a sine, calm rather than an attention-grabbing
// on/off blink. No glow/halo: the light stays contained within the circle's
// perimeter. TimelineView drives the redraw, so it pauses when the row is
// off-screen and survives row reloads with no manual Timer/@State to leak or
// reset — same approach as ClaudeThinkingIcon.
struct WaitingLight: View {
    private static let period = 2.0          // seconds per full breath
    private static let fps = 24.0
    private static let gold = Color(hex: 0xFFC107)   // warm golden, not lemon-yellow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / Self.fps)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t / Self.period * 2 * Double.pi) + 1) / 2   // 0…1, smooth
            let level = 0.3 + 0.7 * phase                                // 0.3…1.0
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Self.gold)
                .opacity(level)
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

// A worktree marker, shown on a Claude row whose session lives in a LINKED git
// worktree (not the main checkout). Several Claude sessions on one repo —
// the everyday parallel-work setup here — otherwise look identical; this names
// the worktree so you know which is which. Neutral grey + a branch glyph so it
// reads as "where," staying out of the agent-color rename pill's lane.
struct WorktreeChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .semibold))
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        .help("git worktree: \(name)")
    }
}

// The session's GOAL — the `/goal` completion condition it's working toward.
// Where the worktree chip says WHERE a session lives and the rename pill says
// WHO it is, this says WHAT it's trying to achieve, so it's the most prominent
// thing in the eyebrow: full-strength text on a quiet capsule, and it stands in
// for the auto-topic rather than crowding beside it. The target glyph carries
// the meaning. Deliberately NOT a status-light hue (yellow/blue/green) — a goal
// is an intent, not a state, so it stays out of that grammar.
struct GoalChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "target")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        .help("goal: \(text)")
    }
}

struct OpRow: View {
    let op: Op
    let nowTs: Double
    var jumpNumber: Int? = nil      // ⌘N jump hint (window nav only); nil = none
    var showJumpSlot = false        // reserve the trailing slot so the time column stays aligned

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
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                if let blurb = op.summary, !blurb.isEmpty, !op.isRunning {
                    // What Claude said when it finished — the reply, distinct
                    // from the prompt above and the metadata below.
                    Text("↳ \(blurb)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                subtitleText
                    .font(.system(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(timeText)
                // Deliberately small — the time is a glance detail; the command is
                // the row's focus, not this.
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(op.isService ? Color.servingGreen
                                 : (op.isRunning && op.isClaude && !op.isWaiting) ? Color.claudeOrange
                                 : op.isRunning ? Color.accentColor : .secondary)
            // The ⌘1–9 jump keycap used to sit here; removed for now (it crowded the
            // command's trailing edge). The shortcut still works via the key monitor,
            // and the hint footer still documents it. jumpNumber/showJumpSlot are left
            // wired up so restoring the keycap is a one-line change.
        }
        .padding(.vertical, 3)
    }

    private var statusIcon: some View {
        Group {
            if op.isWaiting {
                WaitingLight()         // soft yellow breathing light = needs you
            } else if op.isService {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Color.servingGreen)
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
        .font(.system(size: 11))
    }

    private var subtitleText: Text {
        // Most segments inherit the row's secondary grey (set on the view); only
        // the ctx-fill segment overrides its own color, so we build Text runs and
        // concatenate them rather than joining a plain String.
        var parts: [Text] = []
        if let since = op.waitingSince {
            let what = (op.waitingMsg?.isEmpty == false) ? op.waitingMsg! : "needs you"
            parts.append(Text("✋ \(what) — \(fmt(nowTs - since))"))
        } else if let idle = op.stallIdle {
            parts.append(Text("✋ waiting for input? quiet \(fmt(idle))"))
        } else if op.isRunning, op.liveSubagents.count == 1 {
            parts.append(Text("⚙ \(op.liveSubagents[0].label)"))          // a lone subagent reads inline, as before
        } else if op.isRunning, op.liveSubagents.count >= 2 {
            parts.append(Text("⚙ \(op.liveSubagents.count) agents running"))  // fan-out: count here, list below
        } else if op.isRunning, let act = op.activity, !act.isEmpty {
            parts.append(Text("⚙ \(act)"))       // live agent activity (PostToolUse)
        } else if op.isService {
            let p = op.ports.map { ":\($0)" }.joined(separator: " ")
            parts.append(Text(p.isEmpty ? "serving" : "serving \(p)"))
        }
        // Background shells (run_in_background) run alongside whatever the turn is
        // doing and outlive it, so they get their own segment — not part of the
        // status chain above. The actual commands list beneath the row.
        if !op.bgShells.isEmpty {
            parts.append(Text("▷ \(op.bgShells.count) shell\(op.bgShells.count == 1 ? "" : "s")"))
        }
        // Subagents that outlived the turn: while the turn runs they show inline (⚙)
        // above, but once it's marked done a still-running agent gets its own "⟳ N bg"
        // chip — the row stays truthful that the session is still working (the TUI's
        // "Waiting for N background agents to finish"). Commands list beneath the row.
        if !op.isRunning, !op.liveSubagents.isEmpty {
            parts.append(Text("⟳ \(op.liveSubagents.count) bg"))
        }
        // Directory: tint the whole path with a warm, desaturated dirTint so it
        // reads as its own thing — easy to scan for "which project" this row is —
        // without claiming a STATE color (see Color.dirTint). .foregroundColor
        // (not .foregroundStyle) so the run stays concatenable into the " · " chain.
        parts.append(Text(elidePath(op.cwd)).foregroundColor(.dirTint))
        if !op.tty.isEmpty { parts.append(Text(op.tty)) }
        if let code = op.exitCode, code != 0 {
            parts.append(Text(code == -1 ? "killed" : "exit \(code)"))
        }
        if let end = op.endTs { parts.append(Text(fmt(nowTs - end) + " ago")) }
        if op.isClaude {   // session context fill + model + notable mode (from meta)
            if op.ctxTokens > 0 {
                let limit = op.ctxTokens > 200_000 ? 1_000_000.0 : 200_000.0
                let pct = Int((op.ctxTokens / limit) * 100)
                var seg = Text("\(pct)% ctx")
                let hot = pct >= 80   // gold/red — getting full, you need to see it now
                if pct >= 90 { seg = seg.foregroundColor(.ctxDanger) }       // running out of room
                else if pct >= 80 { seg = seg.foregroundColor(.ctxWarn) }    // getting full
                // Calm ctx is just one more grey segment, fine to truncate off the
                // right edge of this single-line chain. But once it's gold/red,
                // lift it to the front so the warning can't be the thing that gets
                // truncated away exactly when the session is about to run out of room.
                if hot { parts.insert(seg, at: 0) } else { parts.append(seg) }
            }
            if !op.model.isEmpty { parts.append(Text(shortModel(op.model))) }
            if op.mode == "bypassPermissions" { parts.append(Text("⚠ bypass")) }
        }
        guard var joined = parts.first else { return Text("") }
        // Text interpolation (not `+`, deprecated in macOS 26) — keeps each run's
        // own color, so the ctx segment stays gold/red while the rest is grey.
        for seg in parts.dropFirst() { joined = Text("\(joined) · \(seg)") }
        return joined
    }

    private var timeText: String {
        op.isRunning ? fmt(nowTs - op.start) : fmt(op.dur ?? 0)
    }
}

// macOS spends the first click on a background window just to activate it, so a
// click on a Joystick row while another app is frontmost only raises Joystick —
// you'd need a second click to actually jump. This transparent overlay makes
// that first click count: it accepts the first mouse and runs the row's action
// directly. It claims the hit ONLY while the window is in the background
// (hitTest returns nil once Joystick is key), so when we're already frontmost
// SwiftUI's own tap gesture, hover and right-click context menu behave exactly
// as before. Safe because the row action is non-destructive (focus a terminal);
// ending a task is keyboard-only and gated, never reachable from a stray click.
private struct FirstMouseView: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { Catcher(action: action) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catcher)?.action = action
    }

    final class Catcher: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Defer entirely to the SwiftUI content underneath while Joystick is key;
        // only become the hit target (and thus catch the first-mouse click) when
        // the window is in the background — the exact case we're fixing.
        override func hitTest(_ point: NSPoint) -> NSView? {
            (window?.isKeyWindow ?? false) ? nil : super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) { action() }
    }
}

struct GroupRow: View {
    let group: SurfaceGroup
    let nowTs: Double
    var focusedSurface: String? = nil
    var isSelected: Bool = false   // under the keyboard cursor (window nav only)
    var keyboardNav: Bool = false  // window list — shows the ⌘N jump hint
    var jumpNumber: Int? = nil     // this row's ⌘N number (1–9), if in range
    var markUnread: (Op) -> Void = { _ in }
    var clearRow: (Op) -> Void = { _ in }
    var canReorder: Bool = false   // window nav, >1 row — gates "Move up/down"
    var moveRow: (Int) -> Void = { _ in }   // -1 = up, +1 = down
    let action: () -> Void

    // .key only when OUR window is the key window. The selection fill means
    // "arrow keys steer this row" — true ONLY while we hold keyboard focus — so
    // we fade it when we don't, matching the macOS active/inactive-selection
    // convention. Without this the vivid fill lingers while you're in Ghostty
    // and invites arrow presses that go nowhere.
    @Environment(\.controlActiveState) private var controlActiveState

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
            // Eyebrow above the prompt: the worktree chip (if this session runs
            // in a linked git worktree) + your rename pill (if set) + the session
            // goal chip (if a `/goal` is set) OR Claude's auto-generated topic.
            // The prompt stays the label below; the rename pill is tinted by the
            // session's agent color. A set goal SUPERSEDES the auto-topic — it's
            // the session's own stated objective, a truer summary than the
            // inferred title — so the two never show together.
            let badgeName = group.current.sessionName
            let goal = group.current.goal
            let topic = goal.isEmpty ? group.current.title : ""
            let worktree = group.current.worktree
            if !worktree.isEmpty || !badgeName.isEmpty || !goal.isEmpty || !topic.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 43)   // align under the command text
                    if !worktree.isEmpty {
                        WorktreeChip(name: worktree)
                    }
                    if !badgeName.isEmpty {
                        SessionEyebrow(name: badgeName,
                                       tint: Color.claudeAgent(group.current.agentColor))
                    }
                    if !goal.isEmpty {
                        GoalChip(text: goal)
                    }
                    if !topic.isEmpty {
                        Text(topic)
                            .font(.caption2)
                            .foregroundStyle(Color.summaryYellow)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            OpRow(op: group.current, nowTs: nowTs,
                  jumpNumber: jumpNumber, showJumpSlot: keyboardNav)
            // Live subagent fan-out: list each Task beneath the row (the main line
            // shows the count/chip). Shown for a running fan-out (2+ at once) OR for a
            // subagent still running after the turn was marked done (the ⟳ bg case) —
            // there the single agent's label only lives here. ≤3 shown, like the
            // history below; the rest fold into "+N more" so the row stays bounded.
            let kids = group.current.liveSubagents
            if kids.count >= 2 || (!group.current.isRunning && !kids.isEmpty) {
                ForEach(kids.prefix(3)) { kid in
                    HStack(spacing: 0) {
                        Spacer().frame(width: 43)  // align under the command text
                        Text("⚙ \(kid.label)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if kids.count > 3 {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 43)
                        Text("+\(kids.count - 3) more")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .opacity(0.55)
                        Spacer(minLength: 0)
                    }
                }
            }
            // Background shells (run_in_background): list each running shell's command
            // beneath the row. NOT gated on isRunning — a shell outlives the turn that
            // launched it, so it shows even while the session's current op sits idle.
            // ▷ (a running operation) keeps them distinct from ⚙ subagents and the
            // ◉ green of a port-holding service. Same ≤3 + "+N more" cap as history.
            if !group.current.bgShells.isEmpty {
                let shells = group.current.bgShells
                ForEach(shells.prefix(3)) { sh in
                    HStack(spacing: 0) {
                        Spacer().frame(width: 43)  // align under the command text
                        Text("▷ \(sh.label)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if shells.count > 3 {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 43)
                        Text("+\(shells.count - 3) more")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .opacity(0.55)
                        Spacer(minLength: 0)
                    }
                }
            }
            // History is trimmed to the two most-recent earlier results — enough
            // breadcrumb to read the row's recent arc without the full transcript
            // that tripled each row's height. Anything older folds into a quiet
            // "+N more" count. The full ≤3 still lives in the model if we later
            // add hover-to-expand.
            ForEach(group.history.prefix(2)) { op in
                HStack(spacing: 0) {
                    Spacer().frame(width: 43)  // align under the command text
                    Text(historyLine(op))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // Right-clicking a specific history line copies that line's
                // command (innermost context menu wins over the row's).
                .contextMenu { copyMenu(for: op) }
            }
            if group.history.count > 2 {
                HStack(spacing: 0) {
                    Spacer().frame(width: 43)
                    Text("+\(group.history.count - 2) more")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .opacity(0.4)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        // Let the click land on the FIRST press even when Joystick is in the
        // background (see FirstMouseView). Transparent while we're frontmost.
        .overlay { FirstMouseView(action: action) }
        .help("Click to focus this tab in Ghostty · right-click to copy")
        .contextMenu {
            copyMenu(for: group.current)
            // A serving row holds one+ listening ports (parsed from lsof). Offer to
            // open each as http://localhost:<port>. Deliberately one explicit click
            // per port, NOT the row's primary click (that focuses the tab) and NOT
            // auto-linkified — a LISTEN socket may be Postgres/Redis/a debugger, not
            // a web server, so the user decides which to open rather than us guessing.
            if group.current.isService, !group.current.ports.isEmpty {
                Divider()
                ForEach(group.current.ports, id: \.self) { port in
                    Button {
                        if let url = URL(string: "http://localhost:\(port)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: { Label("Open localhost:\(port)", systemImage: "safari") }
                }
            }
            // Hand-reordering lives only in the keyboard-nav window (the menubar
            // keeps its prioritized sort). Mirrors ⌘↑/⌘↓ and wraps, so even the
            // top/bottom row can Move Up/Down (to the other end).
            if keyboardNav {
                Divider()
                Button { moveRow(-1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(!canReorder)
                Button { moveRow(1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(!canReorder)
            }
            // "Clear" and "Mark unread" are inverses and never both apply: a row
            // is either flagging something to clear, or already clear (markable).
            if group.current.isWaiting || group.current.unseen {
                Divider()
                let waiting = group.current.isWaiting
                Button { clearRow(group.current) } label: {
                    Label(waiting ? "Clear" : "Mark as read",
                          systemImage: waiting ? "bell.slash" : "circle")
                }
            } else if canMarkUnread(group.current) {
                Divider()
                Button { markUnread(group.current) } label: {
                    Label("Mark unread", systemImage: "circle.fill")
                }
            }
        }
        // The keyboard cursor: a 3px gold rail in the left margin + a faint gold
        // wash, instead of the old heavy accent fill. The rail lives in the row's
        // inset gutter (left of the content), so it's well clear of the blue
        // unseen-result dot — the collision that originally forced a full fill.
        // Gold ties the cursor to the app's identity and reads distinctly from the
        // quiet neutral-grey "you are here" wash (no rail). Priority: selection
        // beats focus beats nothing. Both the rail and wash fade when our window
        // isn't key — the cursor only moves under the arrow keys while we hold
        // focus, so a dim cursor signals a keypress would land in Ghostty, not here.
        .listRowBackground(
            ZStack(alignment: .leading) {
                if isSelected {
                    Color.summaryYellow.opacity(controlActiveState == .key ? 0.10 : 0.05)
                    Rectangle().fill(Color.summaryYellow)
                        .frame(width: 3)
                        .opacity(controlActiveState == .key ? 1.0 : 0.4)
                } else if isFocused {
                    Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.35)
                } else {
                    Color.clear
                }
            }
        )
        // Deliberate vertical rhythm: more air BETWEEN groups (so each terminal
        // reads as its own unit) and a hairline-faint separator, instead of the
        // default tight inset where groups blurred together.
        .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
        .listRowSeparatorTint(Color.primary.opacity(0.07))
    }

    // Right-click → copy. Command first (the row's main text), then its
    // directory. cmd is copied as shown (Claude rows keep their » prefix).
    @ViewBuilder
    private func copyMenu(for op: Op) -> some View {
        Button { copyToPasteboard(op.cmd) } label: { Label("Copy command", systemImage: "doc.on.doc") }
        if !op.cwd.isEmpty {
            Button { copyToPasteboard(op.cwd) } label: { Label("Copy directory", systemImage: "folder") }
        }
    }

    // Only a finished, surfaced result that's currently SEEN can be marked unread.
    // Running rows have no unread concept; external rows have no surface; an
    // already-unseen row has nothing to do (the dot is already showing).
    private func canMarkUnread(_ op: Op) -> Bool {
        !op.isRunning && !op.isExternal && !op.surface.isEmpty && !op.unseen
    }

    private func historyLine(_ op: Op) -> String {
        let mark = (op.exitCode ?? 0) == 0 ? "✓" : "✗"
        let ago = fmt(nowTs - (op.endTs ?? nowTs))
        return "\(mark) \(op.cmd) — \(fmt(op.dur ?? 0)) (\(ago) ago)"
    }
}

// First-run onboarding: auto-appears when the hooks aren't wired. One button
// runs the bundled install.sh (idempotent, backs up every file it edits) — no
// terminal, no pasting. Shows per-item status, surfaces errors, and nudges
// "open a new terminal" on success (the zsh hook only takes effect in new shells).
struct SetupBanner: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isSettingUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Setting up…").font(.callout)
                }
            } else if store.needsSetup {
                Text("Connect Joystick").font(.headline)
                Text("Wire the shell and Claude Code hooks so your terminals show up here. Idempotent, and every file it edits is backed up first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow("Shell integration (zsh)", store.shellWired)
                statusRow("Claude Code hooks", store.claudeWired)
                if case .failed(let msg) = store.setupResult {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { store.runSetup() } label: {
                    Text(store.setupResult == nil ? "Enable" : "Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {   // wired — success nudge until dismissed
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected — open a new terminal to start tracking.").font(.callout)
                    Spacer(minLength: 8)
                    Button("Done") { store.setupResult = nil }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(label).font(.callout)
            Spacer()
        }
    }
}

// Shown when macOS automation permission to control Ghostty has been denied —
// without it, click-to-focus (the core feature) silently does nothing. Deep-links
// to the exact Privacy pane so the user can flip it back on.
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't control Ghostty").font(.callout.weight(.semibold))
                Text("Click-to-focus needs Automation permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var floatOnTop = false
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    // The windowed instance turns on keyboard-first navigation (filter field,
    // arrow/Enter/Esc handling, the cursor highlight, hint footer). The menubar
    // popover keeps the plain click-only behavior — arrow keys there fight the
    // popover's own event handling, and you can't ⌘-Tab to a menubar dropdown.
    var keyboardNav = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if keyboardNav {
                searchField
                Divider()
            }
            if store.showSetupBanner {
                SetupBanner(store: store)
            }
            if store.automation == .denied {
                PermissionBanner()
            }
            opList
            if keyboardNav {
                Divider()
                hintFooter
            }
        }
        .frame(minWidth: 400, minHeight: 320)
        .background {
            if keyboardNav {
                // Frosted glass, but dialed well back: a heavier window-colored
                // tint over the behind-window vibrancy so only a hint of the
                // desktop bleeds through. The blur reads as a solid, settled
                // backdrop — and crucially the near-opaque tint stops bright
                // windows behind from showing as colored slivers at the edges.
                VisualEffectBackground()
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            store.refreshWiring()
            store.refreshAutomation()
            store.reload()
            // Apply the default pin state — onChange only fires on a *change*,
            // so without this the toggle and the actual window level could drift
            // apart until the first manual toggle.
            for w in NSApp.windows { w.level = floatOnTop ? .floating : .normal }
            if keyboardNav {
                Summoner.shared.reopen = { openWindow(id: "main") }
                installKeyMonitor()
                persistWindowFrame()
                styleMainWindow()
                store.selectForSummon()
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onDisappear { if keyboardNav { removeKeyMonitor() } }
        .onChange(of: floatOnTop) { _, pinned in
            for w in NSApp.windows { w.level = pinned ? .floating : .normal }
        }
        .onChange(of: store.filterText) { _, _ in
            if keyboardNav { store.ensureSelection() }
        }
        // Hotkey summon: clear any stale filter and pre-select the top "needs
        // you" row, then grab the field so you can type-to-filter immediately.
        .onReceive(NotificationCenter.default.publisher(for: Summoner.didSummon)) { _ in
            guard keyboardNav else { return }
            styleMainWindow()   // re-assert non-opacity in case SwiftUI reset it
            store.filterText = ""
            store.selectForSummon()
            searchFocused = true
        }
    }

    // Always-focused filter box (Raycast-style): plain typing narrows the list,
    // while ↑/↓/⏎/esc/⌘-number are intercepted by the key monitor so they drive
    // selection instead of editing the text.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Filter terminals…", text: $store.filterText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var hintFooter: some View {
        Text("↑↓ move · ⌘↑↓ reorder · ⏎ focus · ⌘1–9 jump · esc close")
            .font(.system(.caption2))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
                .font(.system(.subheadline).weight(.semibold))
            Spacer()
            Text("❯ \(store.commandsToday) turns")
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .help("Shell commands + Claude turns today (the day starts at 4am)")
            // Pin as a quiet icon button rather than a labelled switch — the
            // "Pin" word + toggle track crowded the header's trailing edge; a
            // single pin glyph (gold when on) says the same in a fraction of the
            // width and matches the keep-it-calm chrome.
            Button { floatOnTop.toggle() } label: {
                Image(systemName: floatOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(floatOnTop ? Color.summaryYellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(floatOnTop ? "Pinned above all windows — click to unpin"
                             : "Keep this window above all others")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var opList: some View {
        let nowTs = store.now.timeIntervalSince1970
        // A calm collapse when a terminal's surface closes: a row leaving the
        // list fades while the rows below slide up to close the gap, mirroring
        // the Ghostty tab closing rather than snapping out. Keyed to the group
        // ids (stable surface id / claude-<sid>), so it fires ONLY on membership
        // and order changes — never on the 1 Hz relabel of an existing row.
        // The menubar token folds in the Running/Finished split so a row floating
        // up to "needs you" or settling into Finished glides too.
        let animToken: [String] = keyboardNav
            ? store.visibleGroups.map(\.id)
            : store.activeGroups.map(\.id) + ["—"] + store.idleGroups.map(\.id)
        return ScrollViewReader { proxy in
            List {
                if keyboardNav {
                    // One flat, fixed-order list: every terminal holds its slot,
                    // state is the glyph not the position, nothing reshuffles.
                    Section("Terminals") {
                        if store.visibleGroups.isEmpty {
                            Text(store.filterText.isEmpty ? "No terminals yet" : "No matches")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(store.visibleGroups.enumerated()), id: \.element.id) { idx, g in
                                row(g, nowTs, index: idx)
                            }
                        }
                    }
                } else {
                    // Menubar glance view keeps the prioritized Running / Finished
                    // split (needs-you floats up) — it's click-only, not cycled.
                    Section("Running") {
                        if store.activeGroups.isEmpty {
                            Text("Nothing running")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.activeGroups) { g in row(g, nowTs) }
                        }
                    }
                    if !store.idleGroups.isEmpty {
                        Section("Finished") {
                            ForEach(store.idleGroups) { g in row(g, nowTs) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)   // let the window's vibrancy show through the rows
            .animation(.easeOut(duration: 0.22), value: animToken)
            // Keep the keyboard cursor on screen as it moves through a long list.
            .onChange(of: store.selectedKey) { _, key in
                guard keyboardNav, let key else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }

    private func row(_ g: SurfaceGroup, _ nowTs: Double, index: Int = 0) -> some View {
        GroupRow(group: g, nowTs: nowTs,
                 focusedSurface: store.focusedSurface,
                 isSelected: keyboardNav && g.key == store.selectedKey,
                 keyboardNav: keyboardNav,
                 jumpNumber: (keyboardNav && index < 9) ? index + 1 : nil,
                 markUnread: { store.markUnread($0) },
                 clearRow: { store.clearRow($0) },
                 canReorder: keyboardNav && store.visibleGroups.count > 1,
                 moveRow: { store.moveRow(g.key, $0) }) {
            store.selectedKey = g.key   // a mouse click also moves the cursor
            store.focus(g.current)
        }
    }

    // MARK: Keyboard monitor

    // A local key-down monitor intercepts the navigation keys before the focused
    // text field sees them, so one always-focused field can both filter (plain
    // typing) and drive selection (arrows/enter/esc/⌘-number). Reliable where
    // SwiftUI's .onKeyPress fights the field for arrow keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let store = self.store
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Return a Bool (not the NSEvent) across the isolation hop, so we
            // don't trip the NSEvent-isn't-Sendable check; map it to consume/pass.
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Only steer the list while OUR window is key — the menubar
                // popover and any sheets keep their own key handling.
                guard let w = event.window, w.title == "Joystick", w.canBecomeMain else { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                switch Int(event.keyCode) {
                // ⌘ test is `.contains`, NOT `== .command`: macOS reports arrow
                // keys as function keys, so their flags ALWAYS carry .numericPad
                // + .function — `flags == .command` is never true for ⌘↓/⌘↑ and
                // the reorder silently degraded to a plain cursor move.
                case 125:                                           // ↓  (⌘↓ reorders down)
                    if flags.contains(.command) { store.moveSelectedRow(1) } else { store.moveSelection(1) }
                    return true
                case 126:                                           // ↑  (⌘↑ reorders up)
                    if flags.contains(.command) { store.moveSelectedRow(-1) } else { store.moveSelection(-1) }
                    return true
                case 36, 76:                                        // ⏎ / enter
                    store.activateSelection()   // focus Ghostty; leave Joystick up
                    return true
                case 53:                                            // esc
                    if store.filterText.isEmpty { Summoner.shared.dismiss() }
                    else { store.filterText = "" }
                    return true
                default: break
                }
                if flags == .control, let ch = event.charactersIgnoringModifiers {
                    if ch == "n" { store.moveSelection(1); return true }    // emacs-y
                    if ch == "p" { store.moveSelection(-1); return true }
                }
                if flags == .command, let ch = event.charactersIgnoringModifiers,
                   let n = Int(ch), (1...9).contains(n) {
                    store.jump(toIndex: n - 1)   // focus Ghostty; leave Joystick up
                    return true
                }
                return false   // everything else falls through to the filter field
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // Remember the window's size/position across hides and relaunches. SwiftUI's
    // own restoration doesn't reliably survive our manual show/hide, so pin it
    // explicitly with an AppKit frame autosave. On first run (nothing saved yet)
    // seed the frame we settled on: 400×686, anchored to the top-right of the
    // screen — the menubar-companion shape, out of the way of editor windows.
    private func persistWindowFrame() {
        guard let w = NSApp.windows.first(where: { $0.title == "Joystick" && $0.canBecomeMain }) else { return }
        let name = NSWindow.FrameAutosaveName("JoystickMain")
        if !w.setFrameUsingName(name), let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
            let size = NSSize(width: 400, height: min(686, vf.height))
            let origin = NSPoint(x: vf.maxX - size.width, y: vf.maxY - size.height)
            w.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        w.setFrameAutosaveName(name)
    }

    // Frosted-glass chrome for the summoned window: a behind-window vibrancy
    // material fills the content (VisualEffectBackground in body), so the window
    // itself must be non-opaque with a clear backing for the blur to show what's
    // behind it. titleVisibility is left alone so w.title stays "Joystick" and
    // Summoner's window lookup still resolves.
    private func styleMainWindow() {
        guard let w = NSApp.windows.first(where: { $0.title == "Joystick" && $0.canBecomeMain }) else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
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

// MARK: - Global hotkey & summon

// One system-wide hotkey (⌃⌘J by default; see HotKeySpec) that brings Joystick
// up from anywhere — including from inside Ghostty — so triage never needs the
// mouse. Carbon's
// RegisterEventHotKey is used deliberately: it works with NO Accessibility
// permission prompt (unlike a CGEventTap), and is precise about the chord.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onFire() }   // Carbon → main run loop
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: 0x4A4F5953 /* 'JOYS' */, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id,
                                  GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// Bridges the global hotkey (AppKit/Carbon side) to the SwiftUI window: holds
// the openWindow action so it can reopen a closed window, and posts a
// notification the window listens for to grab the field + seed selection.
final class Summoner {
    static let shared = Summoner()
    static let didSummon = Notification.Name("JoystickDidSummon")
    var reopen: (() -> Void)?

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Joystick" && $0.canBecomeMain }
    }

    // Toggle: if our window is already key & frontmost, tuck it away; otherwise
    // bring it up, focused and ready for the keyboard.
    func summon() {
        if NSApp.isActive, mainWindow?.isKeyWindow == true {
            NSApp.hide(nil)   // toggle off (Cmd-H — keeps the window and its size)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            reopen?()   // window was fully closed — let SwiftUI build a fresh one
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: Self.didSummon, object: nil)
        }
    }

    // After ⏎ / ⌘-number focuses a Ghostty tab, step aside so the (often pinned,
    // floating) window doesn't sit on top of where we just jumped. We HIDE the
    // app (Cmd-H) rather than close the window, so its size/position survive and
    // the next summon brings the very same window back.
    func dismiss() { NSApp.hide(nil) }
}

// Parses the summon-shortcut spec into the (keyCode, Carbon-modifier-mask) pair
// RegisterEventHotKey wants. Default is ⌃⌘J; override without a rebuild via
//   defaults write dev.kishan.joystick summonHotKey "ctrl+cmd+j"
// Tokens are cmd/opt/ctrl/shift + one letter/digit/space/return, split on
// space/+/- and case-insensitive. We deliberately default OFF the ⌥⌘+letter
// plane — browsers own it for devtools (⌥⌘J = JS console, ⌥⌘I = inspector, …)
// and a global hotkey wins system-wide, so ⌥⌘J would silently eat the console
// shortcut for anyone running Chrome/Firefox.
enum HotKeySpec {
    static let `default` = "ctrl+cmd+j"

    // Carbon virtual keycodes worth binding to a summon chord. Exotic keys aren't
    // worth a table — a launcher shortcut is a modifier + a letter/digit/space.
    private static let keyCodes: [String: UInt32] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
        "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,
        "l":37,"j":38,"k":40,"n":45,"m":46,
        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
        "space":49,"return":36,"enter":36,
    ]

    // → (keyCode, modifiers); nil if no modifier, no/unknown key, or >1 key
    // (caller falls back to the default so a typo can't disable summon).
    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in spec.lowercased().split(whereSeparator: { " +-".contains($0) }) {
            switch String(raw) {
            case "cmd", "command":       mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control":      mods |= UInt32(controlKey)
            case "shift":                mods |= UInt32(shiftKey)
            case let t:
                guard let code = keyCodes[t], key == nil else { return nil }
                key = code
            }
        }
        guard let k = key, mods != 0 else { return nil }
        return (k, mods)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ note: Notification) {
        let spec = UserDefaults.standard.string(forKey: "summonHotKey") ?? HotKeySpec.default
        register(HotKeySpec.parse(spec))
        // A bad override, OR a chord already claimed by another global hotkey
        // (HotKey init returns nil), both fall back to the default so summon
        // never silently dies.
        if hotKey == nil, spec != HotKeySpec.default {
            register(HotKeySpec.parse(HotKeySpec.default))
        }
    }

    private func register(_ chord: (keyCode: UInt32, modifiers: UInt32)?) {
        guard let chord else { return }
        hotKey = HotKey(keyCode: chord.keyCode, modifiers: chord.modifiers) {
            Summoner.shared.summon()
        }
    }
}

// A frosted-glass backdrop: an AppKit NSVisualEffectView bridged into SwiftUI.
// behindWindow blending samples whatever is behind a non-opaque window (see
// ContentView.styleMainWindow) and blurs it — the Spotlight/Raycast material.
// state = .active keeps it frosted even when the app isn't the key window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

@main
struct JoystickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        // A single, UNIQUE window (not WindowGroup) — the summon hotkey must never
        // spawn a second copy; openWindow(id:) just refocuses this one.
        Window("Joystick", id: "main") {
            ContentView(keyboardNav: true).environmentObject(store)
        }
        .defaultSize(width: 400, height: 686)

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
