// Unit tests for EventFold — the pure left-fold of the log (EventLog.swift).
// Run via tests/eventfold-test.sh. Characterizes EXISTING behavior so the
// EventFold extraction is a provable no-op; the two KNOWN-landmine cases at the
// end pin current (buggy) behavior so a follow-up fix has a target.

import Foundation

@main
struct EventFoldTests {
    static func ev(_ json: String) -> RawEvent {
        try! JSONDecoder().decode(RawEvent.self, from: Data(json.utf8))
    }

    static func main() {
        var pass = 0, fail = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fail += 1; print("FAIL: \(name)") }
        }

        // 1. shell start -> one open running op, nothing finished
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"shell","ev":"start","id":"s1","cmd":"make","ts":100}"#))
            check("shell start opens an op", f.open["s1"]?.cmd == "make" && f.open["s1"]?.isRunning == true)
            check("nothing finished yet", f.done.isEmpty)
        }

        // 2. start -> end moves to done with exit + dur
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"shell","ev":"start","id":"s1","cmd":"make","ts":100}"#))
            f.apply(ev(#"{"ev":"end","id":"s1","exit":2,"dur":5,"ts":105}"#))
            check("end closes the op", f.open["s1"] == nil)
            check("end recorded exit+dur", f.done.last?.exitCode == 2 && f.done.last?.dur == 5)
        }

        // 3. end with no matching open is dropped
        do {
            var f = EventFold()
            f.apply(ev(#"{"ev":"end","id":"ghost","exit":0,"ts":100}"#))
            check("orphan end dropped", f.open.isEmpty && f.done.isEmpty)
        }

        // 4. claude turn: start -> waiting -> active -> end (with closing blurb)
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» hi","ts":100}"#))
            f.apply(ev(#"{"ev":"waiting","id":"claude-x","msg":"approve?","ts":101}"#))
            check("waiting recorded", f.open["claude-x"]?.waitingSince == 101 && f.open["claude-x"]?.waitingMsg == "approve?")
            f.apply(ev(#"{"ev":"active","id":"claude-x","act":"Bash: ls","ts":102}"#))
            check("active clears waiting + sets activity", f.open["claude-x"]?.waitingSince == nil && f.open["claude-x"]?.activity == "Bash: ls")
            f.apply(ev(#"{"ev":"end","id":"claude-x","exit":0,"dur":5,"ts":105,"msg":"done"}"#))
            check("claude end carries blurb", f.done.last?.summary == "done")
        }

        // 5. queued-prompt race: a second claude start (same id, no end between) closes
        //    the prior turn into history and opens the new one.
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» first","ts":100}"#))
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» second","ts":110}"#))
            check("prior turn closed to history", f.done.count == 1 && f.done.last?.cmd == "» first")
            check("new turn is open", f.open["claude-x"]?.cmd == "» second" && f.open["claude-x"]?.isRunning == true)
            check("plausible gap kept as synthetic dur", f.done.last?.dur == 10)
        }

        // 6. late-end supersede guard: an end whose turn (ts-dur) predates the open op's
        //    start is stale and must NOT close the newer open turn.
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» new","ts":200}"#))
            f.apply(ev(#"{"ev":"end","id":"claude-x","exit":0,"dur":50,"ts":150}"#))  // turn began at 100
            check("stale end ignored, op stays open", f.open["claude-x"]?.isRunning == true && f.done.isEmpty)
        }

        // 7. concurrent subagents each get a live line; subdone drops one
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» go","ts":100}"#))
            f.apply(ev(#"{"ev":"active","id":"claude-x","act":"Task: A","sub":"tu1","ts":101}"#))
            f.apply(ev(#"{"ev":"active","id":"claude-x","act":"Task: B","sub":"tu2","ts":102}"#))
            check("two concurrent subagents tracked", f.open["claude-x"]?.liveSubagents.count == 2)
            f.apply(ev(#"{"ev":"active","id":"claude-x","sub":"tu1","subdone":true,"ts":103}"#))
            check("subdone drops one subagent", f.open["claude-x"]?.liveSubagents.map(\.id) == ["tu2"])
        }

        // 8. meta keyed by claude-<sid>
        do {
            var f = EventFold()
            f.apply(ev(#"{"ev":"meta","id":"claude-x","title":"Topic","mode":"auto","ctx":51000,"ts":105}"#))
            check("meta stored", f.meta["claude-x"]?.title == "Topic" && f.meta["claude-x"]?.ctx == 51000)
        }

        // 9. trimDone caps retained finished ops
        do {
            var f = EventFold()
            for i in 0..<(EventFold.maxDoneRetained + 50) {
                f.apply(ev(#"{"kind":"shell","ev":"start","id":"s\#(i)","cmd":"c","ts":\#(Double(i))}"#))
                f.apply(ev(#"{"ev":"end","id":"s\#(i)","exit":0,"ts":\#(Double(i))}"#))
            }
            f.trimDone()
            check("done capped at maxDoneRetained", f.done.count == EventFold.maxDoneRetained)
        }

        // 10. pruneOpen keeps only ops passing the predicate
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"shell","ev":"start","id":"keep","cmd":"a","pid":1,"ts":100}"#))
            f.apply(ev(#"{"kind":"shell","ev":"start","id":"drop","cmd":"b","pid":2,"ts":100}"#))
            f.pruneOpen { $0.pid == 1 }
            check("pruneOpen keeps only matching", Array(f.open.keys) == ["keep"])
        }

        // 11. tally helpers (pure)
        check("shell counts toward tally", EventFold.countsTowardTally(ev(#"{"kind":"shell","ev":"start","id":"x","ts":1}"#)))
        check("claude counts toward tally", EventFold.countsTowardTally(ev(#"{"kind":"claude","ev":"start","id":"x","ts":1}"#)))
        check("external excluded from tally", !EventFold.countsTowardTally(ev(#"{"kind":"external","ev":"start","id":"x","ts":1}"#)))

        // 12. fourAMDayStart: 03:00 belongs to the PREVIOUS 4am-day; 05:00 to today's
        do {
            let cal = Calendar.current
            func at(_ hour: Int, _ day: Int) -> Date {
                var c = DateComponents(); c.year = 2026; c.month = 6; c.day = day; c.hour = hour
                return cal.date(from: c)!
            }
            check("3am rolls into yesterday's 4am-day", EventFold.fourAMDayStart(at(3, 15)) == EventFold.fourAMDayStart(at(23, 14)))
            check("5am is its own day", EventFold.fourAMDayStart(at(5, 15)) != EventFold.fourAMDayStart(at(3, 15)))
        }

        // 13. session-id rotation (/clear, /resume, restart): a NEW claude-<sid> on
        //     the SAME surface (or pid) retires the prior session's ops — open and
        //     finished alike — so one terminal shows one Claude row, not a stale
        //     duplicate. A bystander session in another tab (different surface + pid)
        //     is untouched.
        do {
            var f = EventFold()
            // Old session: a finished turn on surface S, pid 42.
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-old","cmd":"» how important is 1?","surface":"S","pid":42,"ts":100}"#))
            f.apply(ev(#"{"ev":"end","id":"claude-old","exit":0,"dur":5,"ts":105,"msg":"bye"}"#))
            // A bystander session in another tab (surface T, pid 99) must survive.
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-other","cmd":"» elsewhere","surface":"T","pid":99,"ts":106}"#))
            // /clear rotates the id; the new session reuses surface S (and pid 42).
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-new","cmd":"» okay next","surface":"S","pid":42,"ts":200}"#))
            check("rotated session's finished row retired", !f.done.contains { $0.key == "claude-old" })
            check("new session is the open op", f.open["claude-new"]?.isRunning == true)
            check("bystander in another tab survives", f.open["claude-other"]?.isRunning == true)
        }

        // 13b. surface capture can miss (empty surface) — pid then carries the match,
        //      and a still-OPEN prior turn (cleared mid-run) is dropped, not kept.
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-old","cmd":"» a","surface":"","pid":42,"ts":100}"#))
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-new","cmd":"» b","surface":"","pid":42,"ts":200}"#))
            check("pid match retires prior session when surface unknown",
                  f.open["claude-old"] == nil && f.open["claude-new"]?.isRunning == true && f.done.isEmpty)
        }

        // --- the two former landmines, now fixed ---

        // L1. Op.id must be unique per op even when same-session turns share an integer
        //     second (the log clock is whole seconds). Three same-second turns -> two
        //     done + one open, all with distinct ids (SwiftUI identity, no row flicker).
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» a","ts":100}"#))
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» b","ts":100}"#))  // closes a
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» c","ts":100}"#))  // closes b
            let ids = [f.done[0].id, f.done[1].id, f.open["claude-x"]!.id]
            check("same-second turns get distinct ids", f.done.count == 2 && Set(ids).count == 3)
        }

        // L2. The queued-prompt close fabricates the prior turn's dur from the gap. A
        //     plausible gap is kept (see test 5); an implausible one (interrupted turn that
        //     sat for hours) is recorded as unknown, not a huge fake "success".
        do {
            var f = EventFold()
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» a","ts":100}"#))
            f.apply(ev(#"{"kind":"claude","ev":"start","id":"claude-x","cmd":"» b","ts":10000}"#))  // ~2.75h gap
            check("implausible gap -> unknown dur, not fake success", f.done.last?.dur == nil)
        }

        print("pass=\(pass) fail=\(fail)")
        if fail != 0 { exit(1) }
    }
}
