// Unit tests for DayDigest — the deterministic day recap (EventLog.swift).
// Run via tests/daydigest-test.sh. Same harness shape as eventfold-test.swift.

import Foundation

@main
struct DayDigestTests {
    static func ev(_ json: String) -> RawEvent {
        try! JSONDecoder().decode(RawEvent.self, from: Data(json.utf8))
    }

    static func main() {
        var pass = 0, fail = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fail += 1; print("FAIL: \(name)") }
        }

        let HOME = "/Users/t"
        let DAY = 1000.0   // digest window start; anything earlier is yesterday

        // 1. repoKey: repo under ~, bare path elsewhere, ~ itself, empty cwd
        check("repoKey repo under home", DayDigest.repoKey("/Users/t/joystick/tests", home: HOME) == "joystick")
        check("repoKey outside home", DayDigest.repoKey("/opt/build", home: HOME) == "/opt/build")
        check("repoKey home itself", DayDigest.repoKey("/Users/t", home: HOME) == "~")
        check("repoKey empty cwd", DayDigest.repoKey("", home: HOME) == "~")

        // 2. a two-turn Claude session: turns/secs summed, LAST blurb wins,
        //    goal outranks title for the label, "» " stripped from prompts.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"claude","ev":"start","id":"claude-a","cmd":"» fix the tests","cwd":"/Users/t/joystick","ts":1100}"#),
                ev(#"{"ev":"end","id":"claude-a","exit":0,"dur":60,"ts":1160,"msg":"first blurb"}"#),
                ev(#"{"kind":"claude","ev":"start","id":"claude-a","cmd":"» now the docs","cwd":"/Users/t/joystick","ts":1200}"#),
                ev(#"{"ev":"end","id":"claude-a","exit":0,"dur":40,"ts":1240,"msg":"second blurb"}"#),
                ev(#"{"ev":"meta","id":"claude-a","title":"Test fixing","goal":"all tests green","wt":"day-digest","ts":1240}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            check("one repo", d.repos.count == 1 && d.repos[0].name == "joystick")
            let s = d.repos[0].sessions.first
            check("turns + secs summed", s?.turns == 2 && s?.secs == 100)
            check("goal outranks title", s?.label == "all tests green")
            check("last blurb wins", s?.blurb == "second blurb")
            check("worktree carried", s?.worktree == "day-digest")
        }

        // 3. label fallbacks: title when no goal/rename; first prompt when no meta.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"claude","ev":"start","id":"claude-t","cmd":"» hi","cwd":"/Users/t/a","ts":1100}"#),
                ev(#"{"ev":"end","id":"claude-t","exit":0,"dur":5,"ts":1105}"#),
                ev(#"{"ev":"meta","id":"claude-t","title":"Greeting","ts":1105}"#),
                ev(#"{"kind":"claude","ev":"start","id":"claude-p","cmd":"» raw prompt","cwd":"/Users/t/b","ts":1200}"#),
                ev(#"{"ev":"end","id":"claude-p","exit":0,"dur":5,"ts":1205}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            let byName = Dictionary(uniqueKeysWithValues: d.repos.map { ($0.name, $0) })
            check("title fallback", byName["a"]?.sessions.first?.label == "Greeting")
            check("prompt fallback strips »", byName["b"]?.sessions.first?.label == "raw prompt")
        }

        // 4. yesterday is excluded: turns before dayStart don't count, and an end
        //    whose start was yesterday doesn't leak into today.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"claude","ev":"start","id":"claude-old","cmd":"» y","cwd":"/Users/t/a","ts":900}"#),
                ev(#"{"ev":"end","id":"claude-old","exit":0,"dur":50,"ts":1500,"msg":"late"}"#),
                ev(#"{"kind":"shell","ev":"start","id":"s-old","cmd":"make","cwd":"/Users/t/a","ts":950}"#),
                ev(#"{"ev":"end","id":"s-old","exit":1,"dur":600,"ts":1550}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            check("yesterday excluded entirely", d.isEmpty)
        }

        // 5. an open turn is credited up to `now`.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"claude","ev":"start","id":"claude-o","cmd":"» go","cwd":"/Users/t/a","ts":1900}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            check("open turn credited to now", d.repos.first?.sessions.first?.secs == 100)
        }

        // 6. shell aggregates: commands, fails, commits, longest ≥ 2min.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"shell","ev":"start","id":"s1","cmd":"make build","cwd":"/Users/t/j","ts":1100}"#),
                ev(#"{"ev":"end","id":"s1","exit":0,"dur":300,"ts":1400}"#),
                ev(#"{"kind":"shell","ev":"start","id":"s2","cmd":"git commit -m x","cwd":"/Users/t/j","ts":1500}"#),
                ev(#"{"ev":"end","id":"s2","exit":0,"dur":1,"ts":1501}"#),
                ev(#"{"kind":"shell","ev":"start","id":"s3","cmd":"pytest","cwd":"/Users/t/j","ts":1600}"#),
                ev(#"{"ev":"end","id":"s3","exit":2,"dur":30,"ts":1630}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            let r = d.repos.first
            check("commands counted", r?.commands == 3)
            check("fail counted", r?.fails == 1)
            check("commit counted", r?.commits == 1)
            check("longest is the 5m build", r?.longestCmd == "make build" && r?.longestSecs == 300)
        }

        // 7. repo ordering by Claude seconds; session cap surfaces as moreSessions.
        do {
            var events: [RawEvent] = [
                ev(#"{"kind":"claude","ev":"start","id":"claude-big","cmd":"» big","cwd":"/Users/t/busy","ts":1100}"#),
                ev(#"{"ev":"end","id":"claude-big","exit":0,"dur":500,"ts":1600}"#),
                ev(#"{"kind":"shell","ev":"start","id":"sh1","cmd":"ls","cwd":"/Users/t/quiet","ts":1100}"#),
                ev(#"{"ev":"end","id":"sh1","exit":0,"dur":1,"ts":1101}"#),
            ]
            for i in 0..<6 {   // 6 sessions in one repo → 4 shown + 2 more
                events.append(ev(#"{"kind":"claude","ev":"start","id":"claude-m\#(i)","cmd":"» s\#(i)","cwd":"/Users/t/many","ts":\#(1200 + i)}"#))
                events.append(ev(#"{"ev":"end","id":"claude-m\#(i)","exit":0,"dur":\#(10 + i),"ts":\#(1300 + i)}"#))
            }
            let d = DayDigest.build(events: events, dayStart: DAY, now: 2000, home: HOME)
            check("busiest repo first", d.repos.first?.name == "busy")
            let many = d.repos.first { $0.name == "many" }
            check("session cap + moreSessions", many?.sessions.count == 4 && many?.moreSessions == 2)
            check("sessions sorted by secs", many?.sessions.first?.secs == 15)
        }

        // 8. interactive apps (the taxonomy IGNORE set) are not shell activity:
        //    not counted, never "longest" — a 7h claude TUI is a hosted session.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"shell","ev":"start","id":"i1","cmd":"claude","cwd":"/Users/t/j","ts":1100}"#),
                ev(#"{"ev":"end","id":"i1","exit":0,"dur":26000,"ts":27100}"#),
                ev(#"{"kind":"shell","ev":"start","id":"i2","cmd":"vim notes.md","cwd":"/Users/t/j","ts":1200}"#),
                ev(#"{"ev":"end","id":"i2","exit":0,"dur":900,"ts":2100}"#),
                ev(#"{"kind":"shell","ev":"start","id":"s1","cmd":"make","cwd":"/Users/t/j","ts":1300}"#),
                ev(#"{"ev":"end","id":"s1","exit":0,"dur":10,"ts":1310}"#),
            ], dayStart: DAY, now: 30000, home: HOME)
            let r = d.repos.first
            check("interactive apps not counted", r?.commands == 1)
            check("interactive apps never longest", r?.longestCmd == "")
        }

        // 9. a blurb is quoted, not reprinted: capped at maxBlurbChars with an ellipsis.
        do {
            let long = String(repeating: "x", count: 400)
            let d = DayDigest.build(events: [
                ev(#"{"kind":"claude","ev":"start","id":"claude-b","cmd":"» go","cwd":"/Users/t/j","ts":1100}"#),
                ev("{\"ev\":\"end\",\"id\":\"claude-b\",\"exit\":0,\"dur\":5,\"ts\":1105,\"msg\":\"\(long)\"}"),
            ], dayStart: DAY, now: 2000, home: HOME)
            let b = d.repos.first?.sessions.first?.blurb ?? ""
            check("blurb capped", b.count == DayDigest.maxBlurbChars && b.hasSuffix("…"))
        }

        // 10. external ops render one line each; markdown carries the day's shape.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"external","ev":"start","id":"cli-1","cmd":"deploy staging","cwd":"","ts":1100}"#),
                ev(#"{"ev":"end","id":"cli-1","exit":0,"dur":90,"ts":1190}"#),
                ev(#"{"kind":"claude","ev":"start","id":"claude-a","cmd":"» ship it","cwd":"/Users/t/joystick","ts":1200}"#),
                ev(#"{"ev":"end","id":"claude-a","exit":0,"dur":60,"ts":1260,"msg":"shipped"}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            check("external rendered", d.externals == ["deploy staging ✓ (1m30s)"])
            let md = d.markdown(dayLabel: "Today — Tue Jul 1")
            check("markdown header", md.hasPrefix("# Today — Tue Jul 1"))
            check("markdown session line", md.contains("- ship it (1 turn, 1m00s) — shipped"))
            check("markdown external line", md.contains("- deploy staging ✓ (1m30s)"))
        }

        // 11. a Codex session accumulates as a session just like Claude: turns +
        //     secs summed, blurb from its closing message, label from the prompt.
        do {
            let d = DayDigest.build(events: [
                ev(#"{"kind":"codex","ev":"start","id":"codex-a","cmd":"» audit the backend","cwd":"/Users/t/core","ts":1100}"#),
                ev(#"{"ev":"end","id":"codex-a","exit":0,"dur":40,"ts":1140,"msg":"found 3 red flags"}"#),
                ev(#"{"kind":"codex","ev":"start","id":"codex-a","cmd":"» fix the first one","cwd":"/Users/t/core","ts":1200}"#),
                ev(#"{"ev":"end","id":"codex-a","exit":0,"dur":20,"ts":1220,"msg":"patched the N+1"}"#),
            ], dayStart: DAY, now: 2000, home: HOME)
            let s = d.repos.first?.sessions.first
            check("codex session recorded", d.repos.first?.name == "core")
            check("codex turns + secs summed", s?.turns == 2 && s?.secs == 60)
            check("codex prompt label strips »", s?.label == "audit the backend")
            check("codex last blurb wins", s?.blurb == "patched the N+1")
        }

        print("pass=\(pass) fail=\(fail)")
        exit(fail == 0 ? 0 : 1)
    }
}
