// Joystick — the log event model and the pure fold of the event stream.
//
// Foundation-only on purpose: no SwiftUI/AppKit, no file I/O, no syscalls. That
// keeps EventFold (the densest correctness logic in the app — the queued-prompt
// race, the late-end supersede guard, subagent tracking, the daily tally) a pure
// value type that compiles and unit-tests standalone. See tests/eventfold-test.swift.
//
// Store (Joystick.swift) owns the impure parts: reading the log, deciding liveness
// (kill(pid,0)), and grouping ops into rows. It feeds decoded events to a single
// EventFold and reads back its open/done/meta.

import Foundation

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
    let sub: String?       // subagent key (Task tool_use_id), on `active` events that track a live Task
    let shell: String?     // background-shell key (run_in_background Bash tool_use_id), on `active` events that track a live bg shell
    let subdone: Bool?     // true on the `active` event that ENDS a tracked subagent or bg shell
    let title: String?     // session topic (ai-title), on `meta` events
    let model: String?     // model id, on `meta` events
    let mode: String?      // permission mode, on `meta` events
    let ctx: Double?       // context-window tokens used, on `meta` events
    let name: String?      // user-set session title (rename), on `meta` events
    let color: String?     // user-set session color (agent color), on `meta` events
    let wt: String?        // git worktree leaf the session runs in (linked worktrees only), on `meta` events
    let goal: String?      // session goal (the `/goal` completion condition), on `meta` events; absent/empty when unset or met
}

// A subagent (Task) running inside a Claude turn. Keyed by the Task's tool_use_id
// so its start (PreToolUse) and finish (PostToolUse) line up — concurrent
// subagents each get their own live line instead of fighting over one activity.
struct LiveChild: Identifiable { let id: String; let label: String }

struct Op: Identifiable {
    let key: String
    let cmd: String
    let cwd: String
    let tty: String        // real device for shell ops; "" for claude/external
    let surface: String
    let kind: String       // "shell" | "claude" | "external"
    let pid: Int32
    let start: Double
    let seq: Int           // unique creation order, assigned by EventFold. SwiftUI identity
                           // only — disambiguates same-key ops that share an integer-second
                           // start (the log clock is whole seconds, so start alone collides).
    var endTs: Double? = nil
    var exitCode: Int? = nil
    var dur: Double? = nil
    var waitingSince: Double? = nil   // explicit waiting event (Claude hooks)
    var waitingMsg: String? = nil
    var activity: String? = nil       // live: tool the agent is currently using (Claude)
    var liveSubagents: [LiveChild] = []  // live: subagents (Task) for this session; attached at render time from EventFold.subagents. Session-scoped (like bgShells) — a subagent can OUTLIVE the turn that launched it (the row is marked done while it runs on), so it's not stored on the per-turn Op.
    var bgShells: [LiveChild] = []       // live: background shells (run_in_background) for this session; attached at render time from EventFold.bgShells. They OUTLIVE the turn that launched them, so like liveSubagents they're session-scoped, not per-op.
    var stallIdle: Double? = nil      // heuristic: tty quiet + fg proc asleep
    var isService = false             // fg process group holds a listening port
    var ports: [Int] = []             // listening TCP ports the fg group holds (services only)
    var unseen = false                // finished, and surface not viewed since
    var summary: String? = nil        // Claude's closing blurb, on the end event
    var title = ""                    // session topic (from meta events), Claude rows
    var model = ""                    // model id (from meta events)
    var mode = ""                     // permission mode (from meta events)
    var ctxTokens: Double = 0         // context-window fill (from meta events)
    var sessionName = ""              // user-given session title (rename), from meta
    var agentColor = ""               // user-given session color name, from meta
    var worktree = ""                 // git worktree leaf (linked worktrees only), from meta
    var goal = ""                     // session goal (the `/goal` completion condition), from meta; "" when unset or met

    var id: String { "\(key)#\(seq)" }
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
struct SessionMeta { var title = ""; var model = ""; var mode = ""; var ctx: Double = 0; var name = ""; var color = ""; var wt = ""; var goal = "" }

// MARK: - EventFold

// A left-fold of the append-only log into the live picture: which ops are open,
// which finished (recent tail), and per-session metadata. Identical semantics
// whether applied incrementally (new lines) or over a full re-read — that's why
// Store can keep a running fold and only ever feed it forward.
struct EventFold {
    private(set) var open: [String: Op] = [:]    // id -> currently-open op
    private(set) var done: [Op] = []             // finished ops, oldest first (tail-capped)
    private(set) var meta: [String: SessionMeta] = [:]  // claude-<sid> -> session metadata
    private(set) var bgShells: [String: [LiveChild]] = [:]  // claude-<sid> -> live background shells (run_in_background). Session-scoped, NOT per-op: a bg shell outlives the turn that launched it, so it can't ride along on a turn's Op.
    private(set) var subagents: [String: [LiveChild]] = [:]  // claude-<sid> -> live subagents (Task). Session-scoped like bgShells: a subagent can outlive the turn that launched it (the row is marked done while the agent runs on — the TUI's "Waiting for N background agents to finish"), so it can't ride on a turn's Op either.
    private var nextSeq = 0                              // monotonic id source for Op.seq

    static let maxDoneRetained = 2000   // incremental parse accumulates; cap retained finished ops
    // A queued-prompt close (below) fabricates the prior turn's duration from the gap
    // to the new turn's start — right for the common case (its end just hadn't folded
    // yet), but an interrupted turn (Esc, no Stop) can sit open for hours. Beyond this
    // gap, treat the duration as unknown rather than report a huge fake "success".
    static let maxLateEndGapSecs = 2.0 * 3600

    // Fold one event into the running state.
    mutating func apply(_ e: RawEvent) {
        switch e.ev {
        case "start":
            // Prefer the explicit kind; fall back to the old tty sentinels for
            // events written before the kind field existed.
            let kind = e.kind ?? (e.tty == "claude" ? "claude"
                                  : e.tty == "cli" ? "external" : "shell")
            // Session-id rotation: /clear, /resume and /compact each spin up a NEW
            // claude-<sid> (so does exiting and restarting `claude` in a tab), and
            // Claude rows group by that id — so the cleared conversation would
            // otherwise linger as a stale DUPLICATE row for the same terminal,
            // un-reapable because its pid is the still-alive claude process shared
            // with the new session. A Ghostty surface hosts exactly one live claude
            // process, so when a NEW claude session starts on a surface (or pid) an
            // earlier one held, that earlier session is gone: retire its ops (open
            // and recent history alike). Never the same id — that's the queued-prompt
            // case handled just below. (A `reset` event does the same retirement at
            // /clear time, before the first prompt — see that case.) See NOTES.md.
            if kind == "claude" {
                retireSuperseded(byId: e.id, surface: e.surface ?? "", pid: e.pid ?? -1)
            }
            // Out-of-order guard (Claude turns share one id across turns): a queued
            // or auto-injected prompt's `start` can land in the log just BEFORE the
            // prior turn's `end`. The Stop handler is slow — it reads the transcript
            // for the closing blurb — while UserPromptSubmit, with surface+pid
            // cached, is fast, so the new start overtakes the pending end. If we
            // still hold an open op for this id, the prior turn ended but its end
            // hasn't folded yet: close it out now so it survives as history, rather
            // than let the late end (dropped below) swallow this NEW turn's op and
            // freeze the new prompt as a finished row. See NOTES.md.
            if kind == "claude", var prev = open[e.id] {
                let gap = e.ts - prev.start
                prev.endTs = e.ts
                // Real duration only when the gap is plausible (the end was merely late);
                // beyond that the prior turn was interrupted and sat open — duration unknown.
                prev.dur = (gap >= 0 && gap <= Self.maxLateEndGapSecs) ? gap : nil
                prev.exitCode = 0
                done.append(prev)
            }
            open[e.id] = Op(key: e.id, cmd: e.cmd ?? "?", cwd: e.cwd ?? "",
                            tty: e.tty ?? "", surface: e.surface ?? "", kind: kind,
                            pid: e.pid ?? -1, start: e.ts, seq: nextSeq)
            nextSeq += 1
        case "end":
            guard var op = open[e.id] else { break }
            // Drop a stale end whose turn the open op has already superseded. An end
            // closes the turn that began at (ts − dur); the emitter derives both
            // from the same integer-second clock, so for the matching turn that
            // equals op.start exactly. A strictly-later open op is a newer turn (the
            // queued-prompt race above) — leave it live, don't close it.
            if op.isClaude, let dur = e.dur, op.start > e.ts - dur { break }
            open.removeValue(forKey: e.id)
            op.endTs = e.ts
            op.exitCode = e.exit ?? 0
            op.dur = e.dur ?? max(0, e.ts - op.start)
            op.summary = e.msg        // Claude's closing blurb (claude turns only)
            done.append(op)
        case "waiting":
            if var op = open[e.id] {
                op.waitingSince = e.ts
                op.waitingMsg = e.msg
                op.activity = nil          // blocked on you, not running a tool
                open[e.id] = op
            }
        case "active":
            // Background shells (run_in_background Bash) AND subagents (Task) are both
            // tracked at SESSION level, not on the turn's op: each can outlive the turn
            // that launched it — a bg shell runs across many turns, and a subagent the
            // row already marked done is still running (the TUI's "Waiting for N
            // background agents to finish"). Keyed by tool_use_id; added on start,
            // dropped on finish (the <task-notification> carries the same id). Both are
            // independent of whether an op is currently open for this session.
            if let sh = e.shell, !sh.isEmpty {
                bgShells[e.id, default: []].removeAll { $0.id == sh }
                if e.subdone != true {
                    bgShells[e.id, default: []].append(LiveChild(id: sh, label: e.act ?? "shell"))
                }
                break
            }
            if let sub = e.sub, !sub.isEmpty {
                // A tracked subagent (Task): add on start, drop on finish, so concurrent
                // subagents each get their own live line under the session row instead of
                // overwriting one latest-wins activity. A launch/finish also means the
                // session is unblocked, so clear any waiting on a still-open op.
                subagents[e.id, default: []].removeAll { $0.id == sub }
                if e.subdone != true {
                    subagents[e.id, default: []].append(LiveChild(id: sub, label: e.act ?? "Task"))
                }
                if var op = open[e.id] { op.waitingSince = nil; op.waitingMsg = nil; open[e.id] = op }
                break
            }
            if var op = open[e.id] {
                op.waitingSince = nil
                op.waitingMsg = nil
                op.activity = e.act    // live "what it's doing now" (non-Task tools)
                open[e.id] = op
            }
        case "meta":
            // Session metadata (title/model/mode/ctx). Keyed by claude-<sid>;
            // attached to the group's current op at render time. Emitted AFTER
            // the end event, so the op is already in `done` — keep it separate.
            meta[e.id] = SessionMeta(title: e.title ?? "", model: e.model ?? "",
                                     mode: e.mode ?? "", ctx: e.ctx ?? 0,
                                     name: e.name ?? "", color: e.color ?? "",
                                     wt: e.wt ?? "", goal: e.goal ?? "")
        case "reset":
            // A new Claude session took over this terminal — /clear, /resume and
            // /compact each rotate to a new claude-<sid> on the SAME claude process
            // — but no prompt has been submitted yet, so there's no `start` to carry
            // the supersede. The emitter fires this on SessionStart so the cleared
            // row retires NOW, instead of lingering on the old conversation until your
            // first prompt. Same retirement as `start`; pid carries the match (the
            // claude process is unchanged across the rotation, and no two live
            // processes share a pid). See NOTES.md.
            retireSuperseded(byId: e.id, surface: e.surface ?? "", pid: e.pid ?? -1)
        default:
            break
        }
    }

    // Retire any Claude op an EARLIER session held on this surface or pid: a new
    // session has taken the terminal, so the old one is gone — drop its ops from
    // both `open` and `done`. Shared by `start` (the first prompt of the new
    // session) and `reset` (the session rotated via /clear etc., before any
    // prompt). Never matches the same id (the queued-prompt case, handled in
    // `start`). Surface is the normal match; pid is the airtight fallback when
    // surface capture missed (live processes don't share pids).
    private mutating func retireSuperseded(byId id: String, surface: String, pid: Int32) {
        func superseded(_ op: Op) -> Bool {
            op.isClaude && op.key != id
                && ((!surface.isEmpty && op.surface == surface) || (pid > 0 && op.pid == pid))
        }
        // Drop the retired session's bg shells and subagents too, so any whose
        // completion notification never arrives (session killed mid-run) don't
        // orphan a line.
        let retiredIds = Set(open.values.filter(superseded).map(\.key))
            .union(done.filter(superseded).map(\.key))
        for rid in retiredIds { bgShells.removeValue(forKey: rid); subagents.removeValue(forKey: rid) }
        open = open.filter { !superseded($0.value) }
        done.removeAll(where: superseded)
    }

    // Cap the retained finished ops (oldest dropped); the incremental parse only
    // ever appends, so this is what bounds `done`.
    mutating func trimDone() {
        if done.count > Self.maxDoneRetained {
            done.removeFirst(done.count - Self.maxDoneRetained)
        }
    }

    // Drop open ops whose host is gone, per the caller's liveness predicate (which
    // needs a syscall, so it lives in Store). This is what stops `open` growing
    // unbounded between rotations.
    mutating func pruneOpen(keep: (Op) -> Bool) {
        open = open.filter { keep($0.value) }
    }

    // Forget everything — used on rotation/truncation and on the 4am day rollover,
    // both of which force a full re-read from the top of the log.
    mutating func reset() {
        open = [:]; done = []; meta = [:]; bgShells = [:]; subagents = [:]; nextSeq = 0
    }

    // MARK: Tally helpers (pure; Store owns the @Published counter + persistence)

    // The 4am boundary (local time) of the "day" containing `date`. A day begins
    // at 4am, not midnight, so a late-night session counts under the day you
    // started it; before 4am, the current day began at yesterday's 4am.
    static func fourAMDayStart(_ date: Date) -> TimeInterval {
        let cal = Calendar.current
        let today4 = cal.date(bySettingHour: 4, minute: 0, second: 0, of: date) ?? date
        let start = today4 <= date ? today4
                  : (cal.date(byAdding: .day, value: -1, to: today4) ?? today4)
        return start.timeIntervalSince1970
    }

    // Shell commands + Claude turns count toward the daily tally; external
    // `joystick log` events don't (they aren't commands you ran).
    static func countsTowardTally(_ e: RawEvent) -> Bool {
        let kind = e.kind ?? (e.tty == "claude" ? "claude" : e.tty == "cli" ? "external" : "shell")
        return kind == "shell" || kind == "claude"
    }
}

// The interactive-app IGNORE set of the terminal taxonomy (principle #4): a
// command that IS the terminal session (an editor, a pager, the claude TUI) is
// neither an operation nor a service — the viewer never shows it as a row, and
// the day digest must not count it as shell activity (a `claude` process alive
// for 7h is a hosted session, not "your longest command"). Matched on the first
// token, the same way Store.ignored() does.
let interactiveApps: Set<String> = ["claude", "claude2", "vim", "nvim", "less", "man", "top", "htop", "tmux"]

func isInteractiveApp(_ cmd: String) -> Bool {
    interactiveApps.contains(cmd.split(separator: " ").first.map(String.init) ?? "")
}

// Compact duration ("42s", "3m07s", "2h13m"). Lives here, not in Joystick.swift,
// so the Foundation-only test binaries can use it too — the app links this file.
func fmt(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t < 60 { return "\(t)s" }
    if t < 3600 { return String(format: "%dm%02ds", t / 60, t % 60) }
    return String(format: "%dh%02dm", t / 3600, (t % 3600) / 60)
}

// MARK: - DayDigest

// A deterministic bulleted recap of the day (4am-aligned, same boundary as the
// header tally): one bullet per Claude session — its goal/rename/title/prompt
// plus Claude's own closing blurb — and one aggregate line of shell activity
// per repo. Selection, not generation: every line is data already in the log,
// and the only "rules" are fixed sorts and caps (principle #3's spirit — fully
// predictable, no cleverness).
//
// Deliberately NOT built on EventFold: the fold's job is the LIVE mirror, so it
// retires superseded sessions (/clear, /resume) and trims done — exactly the
// history a recap must keep. The digest re-reads the day's slice on demand
// instead; at ≤ a few thousand lines that's milliseconds.
struct DayDigest {
    struct Session {
        let label: String       // goal > rename > title > first prompt of the day
        let turns: Int          // prompts submitted today
        let secs: Double        // summed turn durations (an open turn counts to `now`)
        let blurb: String       // Claude's last closing blurb today ("" if none)
        let worktree: String    // linked-worktree leaf ("" for the main checkout)
    }
    struct Repo {
        let name: String        // first path component under ~, or the bare path
        var sessions: [Session] = []
        var moreSessions = 0    // sessions beyond maxSessionsPerRepo (never hidden silently)
        var commands = 0        // shell commands started today
        var fails = 0           // ...of which exited non-zero
        var commits = 0         // ...of which were `git commit`
        var longestCmd = ""     // longest shell op of the day, if ≥ minNotableSecs
        var longestSecs = 0.0
    }
    let dayStart: Double
    let repos: [Repo]           // busiest first (Claude seconds, then command count)
    let externals: [String]     // `joystick log` ops today, one rendered line each

    static let maxSessionsPerRepo = 4
    static let minNotableSecs = 120.0
    static let maxBlurbChars = 160   // a recap quotes the blurb, it doesn't reprint it

    // "joystick" for ~/joystick/tests; the bare path outside $HOME; "~" at $HOME.
    static func repoKey(_ cwd: String, home: String) -> String {
        guard !cwd.isEmpty else { return "~" }
        guard cwd.hasPrefix(home) else { return cwd }
        guard let first = cwd.dropFirst(home.count).split(separator: "/").first
        else { return "~" }
        return String(first)
    }

    static func build(events: [RawEvent], dayStart: Double, now: Double, home: String) -> DayDigest {
        struct SessAcc {
            var firstPrompt = ""; var turns = 0; var secs = 0.0; var blurb = ""
            var cwd = ""; var openStart: Double? = nil
        }
        struct MetaAcc { var title = ""; var name = ""; var goal = ""; var wt = "" }
        // `start` info by id, so an `end` (which carries neither kind nor cwd)
        // can find its op — and be ignored when the op began before today.
        var started: [String: (kind: String, cwd: String, ts: Double, cmd: String)] = [:]
        var sess: [String: SessAcc] = [:]           // claude-<sid> → today's accumulation
        var metas: [String: MetaAcc] = [:]          // last meta wins, today or not
        var shell: [String: Repo] = [:]             // repoKey → aggregates
        var externals: [String] = []

        for e in events {
            switch e.ev {
            case "start":
                let kind = e.kind ?? (e.tty == "claude" ? "claude"
                                      : e.tty == "cli" ? "external" : "shell")
                started[e.id] = (kind, e.cwd ?? "", e.ts, e.cmd ?? "")
                guard e.ts >= dayStart else { break }
                switch kind {
                case "claude":
                    var s = sess[e.id] ?? SessAcc()
                    if s.turns == 0 {
                        // Prompts land as "» text"; the marker is row chrome, not content.
                        var p = e.cmd ?? ""
                        if p.hasPrefix("» ") { p = String(p.dropFirst(2)) }
                        s.firstPrompt = p
                    }
                    s.turns += 1
                    s.openStart = e.ts
                    if let c = e.cwd, !c.isEmpty { s.cwd = c }
                    sess[e.id] = s
                case "shell":
                    // Interactive apps (the taxonomy's IGNORE set) aren't ops:
                    // a 7h `claude` or `vim` is a hosted session, not activity.
                    guard !isInteractiveApp(e.cmd ?? "") else { break }
                    let key = repoKey(e.cwd ?? "", home: home)
                    var r = shell[key] ?? Repo(name: key)
                    r.commands += 1
                    if (e.cmd ?? "").hasPrefix("git commit") { r.commits += 1 }
                    shell[key] = r
                default:
                    break   // externals render from their end (below)
                }
            case "end":
                guard let s0 = started[e.id], s0.ts >= dayStart else { break }
                let dur = e.dur ?? max(0, e.ts - s0.ts)
                switch s0.kind {
                case "claude":
                    guard var s = sess[e.id] else { break }
                    s.secs += dur
                    s.openStart = nil
                    if let m = e.msg, !m.isEmpty { s.blurb = m }
                    sess[e.id] = s
                case "shell":
                    guard !isInteractiveApp(s0.cmd) else { break }
                    let key = repoKey(s0.cwd, home: home)
                    guard var r = shell[key] else { break }
                    if (e.exit ?? 0) != 0 { r.fails += 1 }
                    if dur >= Self.minNotableSecs, dur > r.longestSecs {
                        r.longestCmd = s0.cmd; r.longestSecs = dur
                    }
                    shell[key] = r
                default:
                    let mark = (e.exit ?? 0) == 0 ? "✓" : "✗"
                    externals.append("\(s0.cmd) \(mark) (\(fmt(dur)))")
                }
            case "meta":
                metas[e.id] = MetaAcc(title: e.title ?? "", name: e.name ?? "",
                                      goal: e.goal ?? "", wt: e.wt ?? "")
            default:
                break
            }
        }

        // A turn still running gets credited up to `now` — the digest is often
        // read while the day's last session is mid-flight.
        var repos: [String: Repo] = shell
        for (sid, var s) in sess {
            if let o = s.openStart { s.secs += max(0, now - o) }
            let m = metas[sid] ?? MetaAcc()
            let label = !m.goal.isEmpty ? m.goal
                      : !m.name.isEmpty ? m.name
                      : !m.title.isEmpty ? m.title : s.firstPrompt
            var blurb = s.blurb
            if blurb.count > Self.maxBlurbChars {
                blurb = String(blurb.prefix(Self.maxBlurbChars - 1)) + "…"
            }
            let key = repoKey(s.cwd, home: home)
            var r = repos[key] ?? Repo(name: key)
            r.sessions.append(Session(label: label, turns: s.turns, secs: s.secs,
                                      blurb: blurb, worktree: m.wt))
            repos[key] = r
        }
        var out = repos.values.map { r -> Repo in
            var r = r
            r.sessions.sort { $0.secs != $1.secs ? $0.secs > $1.secs : $0.label < $1.label }
            if r.sessions.count > Self.maxSessionsPerRepo {
                r.moreSessions = r.sessions.count - Self.maxSessionsPerRepo
                r.sessions.removeLast(r.moreSessions)
            }
            return r
        }
        out.sort {
            let a = $0.sessions.reduce(0) { $0 + $1.secs }
            let b = $1.sessions.reduce(0) { $0 + $1.secs }
            if a != b { return a > b }
            if $0.commands != $1.commands { return $0.commands > $1.commands }
            return $0.name < $1.name
        }
        return DayDigest(dayStart: dayStart, repos: out, externals: externals)
    }

    var isEmpty: Bool { repos.isEmpty && externals.isEmpty }

    // The copyable form — what lands on the pasteboard and in standup notes.
    func markdown(dayLabel: String) -> String {
        var lines = ["# \(dayLabel)"]
        for r in repos {
            lines.append("")
            lines.append("## \(r.name)")
            for s in r.sessions {
                var l = "- \(s.label)"
                if !s.worktree.isEmpty { l += " ⎇\(s.worktree)" }
                l += " (\(s.turns) turn\(s.turns == 1 ? "" : "s"), \(fmt(s.secs)))"
                if !s.blurb.isEmpty { l += " — \(s.blurb)" }
                lines.append(l)
            }
            if r.moreSessions > 0 {
                lines.append("- +\(r.moreSessions) more session\(r.moreSessions == 1 ? "" : "s")")
            }
            var agg: [String] = []
            if r.commands > 0 { agg.append("\(r.commands) command\(r.commands == 1 ? "" : "s")") }
            if r.commits > 0 { agg.append("\(r.commits) commit\(r.commits == 1 ? "" : "s")") }
            if r.fails > 0 { agg.append("\(r.fails) failed") }
            if !r.longestCmd.isEmpty { agg.append("longest: \(r.longestCmd) \(fmt(r.longestSecs))") }
            if !agg.isEmpty { lines.append("- \(agg.joined(separator: " · "))") }
        }
        if !externals.isEmpty {
            lines.append("")
            lines.append("## external")
            for x in externals { lines.append("- \(x)") }
        }
        return lines.joined(separator: "\n")
    }
}
