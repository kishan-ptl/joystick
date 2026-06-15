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
    let subdone: Bool?     // true on the `active` event that ENDS a tracked subagent
    let title: String?     // session topic (ai-title), on `meta` events
    let model: String?     // model id, on `meta` events
    let mode: String?      // permission mode, on `meta` events
    let ctx: Double?       // context-window tokens used, on `meta` events
    let name: String?      // user-set session title (rename), on `meta` events
    let color: String?     // user-set session color (agent color), on `meta` events
    let wt: String?        // git worktree leaf the session runs in (linked worktrees only), on `meta` events
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
    var liveSubagents: [LiveChild] = []  // live: subagents (Task) running this turn, in start order
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
    var worktree = ""                 // git worktree leaf (linked worktrees only), from meta

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
struct SessionMeta { var title = ""; var model = ""; var mode = ""; var ctx: Double = 0; var name = ""; var color = ""; var wt = "" }

// MARK: - EventFold

// A left-fold of the append-only log into the live picture: which ops are open,
// which finished (recent tail), and per-session metadata. Identical semantics
// whether applied incrementally (new lines) or over a full re-read — that's why
// Store can keep a running fold and only ever feed it forward.
struct EventFold {
    private(set) var open: [String: Op] = [:]    // id -> currently-open op
    private(set) var done: [Op] = []             // finished ops, oldest first (tail-capped)
    private(set) var meta: [String: SessionMeta] = [:]  // claude-<sid> -> session metadata
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
            // and recent history alike). Match on surface (the terminal) or pid (the
            // process), whichever the new start carries — never the same id, which is
            // the queued-prompt case handled just below. See NOTES.md.
            if kind == "claude" {
                let surface = e.surface ?? "", pid = e.pid ?? -1
                func superseded(_ op: Op) -> Bool {
                    op.isClaude && op.key != e.id
                        && ((!surface.isEmpty && op.surface == surface) || (pid > 0 && op.pid == pid))
                }
                open = open.filter { !superseded($0.value) }
                done.removeAll(where: superseded)
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
            if var op = open[e.id] {
                op.waitingSince = nil
                op.waitingMsg = nil
                if let sub = e.sub, !sub.isEmpty {
                    // A tracked subagent (Task): add on start, drop on finish, so
                    // concurrent subagents each get their own live line under the
                    // session row instead of overwriting one latest-wins activity.
                    op.liveSubagents.removeAll { $0.id == sub }
                    if e.subdone != true {
                        op.liveSubagents.append(LiveChild(id: sub, label: e.act ?? "Task"))
                    }
                } else {
                    op.activity = e.act    // live "what it's doing now" (non-Task tools)
                }
                open[e.id] = op
            }
        case "meta":
            // Session metadata (title/model/mode/ctx). Keyed by claude-<sid>;
            // attached to the group's current op at render time. Emitted AFTER
            // the end event, so the op is already in `done` — keep it separate.
            meta[e.id] = SessionMeta(title: e.title ?? "", model: e.model ?? "",
                                     mode: e.mode ?? "", ctx: e.ctx ?? 0,
                                     name: e.name ?? "", color: e.color ?? "",
                                     wt: e.wt ?? "")
        default:
            break
        }
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
        open = [:]; done = []; meta = [:]; nextSeq = 0
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
