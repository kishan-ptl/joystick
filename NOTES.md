# Joystick — product notes

Mission control for your terminal. Watches everything running across Ghostty
tabs (shell commands + Claude/agent sessions) with zero workflow change, and
gets you back to the right tab in under a second.

## Positioning

- NOT another agent manager/wrapper (Conductor, Crystal, claude-squad make you
  live inside their app). Joystick is terminal-native: you keep your tabs.
- Wedge: "I have 12 tabs and 5 Claude sessions — which one needs me?"
- Killer feature: the **inbox of things waiting on you**, not the running list.
  Waiting state sorted by how long it's been blocked.
- Don't position as a "Claude Code manager" (Anthropic's own views evolve
  fast). Position: terminal ops view that happens to understand agents best.

## Current architecture (2026-06-12)

- Event log: `~/.local/state/joystick/events.jsonl` (open JSONL format — this is
  a feature; anything can emit events: CI, EAS webhooks, Makefiles).
  Events: `start` / `end` / `waiting` / `active`. Fields: id, cmd, cwd, pid,
  tty, surface (Ghostty surface UUID), ts, exit, dur, msg.
- Emitters:
  - `joystick.zsh` — zsh preexec/precmd hooks (sourced from ~/.zshrc)
  - `claude-hook.sh` — Claude Code hooks (UserPromptSubmit/Stop/Notification/
    PostToolUse in ~/.claude/settings.json)
- Viewer: `~/Applications/Joystick.app` — SwiftUI (source: Joystick.swift,
  build: build-app.sh). Owns both the menubar (MenuBarExtra) and the window.
  (SwiftBar python plugin retired 2026-06-13; preserved in git history.)
- Click-to-focus: `joystick-focus.sh` — AppleScript, exact Ghostty surface id,
  cwd fallback.
- Waiting detection:
  - Claude: Notification hook → `waiting` event + `waiting-<sid>` marker;
    next PostToolUse clears it with an `active` event.
  - Shell (eas submit etc.): heuristic in viewers — tty mtime stale ≥20s
    (no output) + foreground proc sleeping at ~0% CPU → "waiting for input?"

## Design principles (learned by using it)

- The app is a **live mirror of Ghostty tabs/panes** — never an inbox to
  manage. No dismiss buttons, no clearing. Closing a tab is the dismissal.
- Finished ops show only while their surface still exists.
- **The row unit is the terminal, not the command** (2026-06-12): one
  SurfaceGroup per surface — current op (running, or latest result) is the
  row; up to 3 earlier results render as dimmed history lines beneath it;
  anything older simply isn't shown. Dock badge counts unseen *terminals*.
- **Unseen badges**: finished ops carry a blue dot (+ Dock badge count) until
  their surface is focused after the op ended — cleared equally by clicking a
  Joystick row or by navigating to the tab in Ghostty directly. "Viewed" means
  surface focused while Ghostty is frontmost (sampled every 2s); seen-state
  persists in UserDefaults and is pruned with dead surfaces.

## Keyboard-first window (2026-06-14)

Ships the v0.2 "global hotkey + ⌘1–9 jump" item. The **window** (not the menubar
popover) is now fully drivable without the mouse, Raycast-style:

- **⌥⌘J** — global summon/toggle (Carbon `RegisterEventHotKey`; no Accessibility
  prompt). Brings the window up focused from anywhere, incl. inside Ghostty;
  press again to hide.
- **↑/↓ (or ⌃n/⌃p)** move a keyboard cursor; **⏎** focuses that Ghostty surface;
  **⌘1–9** jump to the Nth row; **type** to filter; **esc** clears filter / hides.
- **⏎ leaves Joystick up** (does NOT hide) — it's a stay-open HUD; the Pin toggle
  decides on-top vs. behind. esc / ⌥⌘J are the explicit dismiss.
- **Fixed, first-seen, flat list** (no Running/Finished split in the window).
  Each terminal keeps its slot for life — state shows in the glyph, not the
  position — so ↑/↓ and ⌘1–9 are stable muscle memory. New terminals join at the
  **TOP** (newest first); closed ones drop out. Order persists (UserDefaults
  `slotOrder`) and `reload()` never re-sorts, only adds/drops. (Manual
  **drag-to-reorder** was removed 2026-06-15 — it can't coexist with
  click-to-focus or first-mouse; see below.) Cursor on summon **pre-selects**
  the first waiting row (then the
  tab you're in, then top), so ⌥⌘J→⏎ still jumps to what needs you.
- Single **`Window`** scene (not `WindowGroup`) so the hotkey can't spawn
  duplicate windows; explicit frame autosave so size/position survive hide +
  relaunch. Selection cursor = accent bar/tint, kept distinct from the quiet
  grey "you are here" highlight.

Decision (Kishan, 2026-06-14): the window trades the auto waiting-inbox SORT for
a **stable order**, on purpose. The needs-you signal is still carried by the
Dock/blue badges, the breathing-amber light, the header count, and summon
pre-selection — and real users don't run enough sessions for a waiting row to get
lost. The **menubar popover keeps** the prioritized Running/Finished sort (a
glance surface, not cycled). Does not regress principle #1 (mirror, not inbox) —
arguably reinforces it.

Caveat to revisit before public/brew distribution: the `⌥⌘J` default collides
with Chrome/Firefox's "JavaScript console" shortcut (a global hotkey wins
system-wide). Fine personally; a **rebinding UI** (folds into the planned v0.2
Settings) should land before shipping the cask.

## Drag-to-reorder removed — can't coexist with click-to-focus + first-mouse (2026-06-15)

The window's manual **drag-to-reorder** (`.onMove` → `Store.moveSlots`) had
silently stopped working and was removed. It is NOT a small-fix regression — a
focused live bisection (each step = one build, drag-tested by hand) proved drag
can't coexist with the two click behaviors that ARE the feature:

- **Bare-`Text` rows in the same `List` reorder fine** → the blocker is in the
  row, not the list/container/macOS.
- The row's **`.onTapGesture { focus }` starves the reorder drag**: it claims the
  mouse-down so the press-drag never reaches the backing table view. It coexisted
  with `.onMove` when the window shipped (70fb9a6), so macOS has since tightened
  gesture arbitration — which is why drag "just stopped" with no change to that
  line (matches "not sure what happened").
- The per-row **`FirstMouseView` overlay** (first-click-from-background focus)
  **also independently blocks the drag** — clean A/B: overlay out → drags,
  overlay in → dead — even though its `hitTest` returns nil while the window is
  key. A hosted NSView in the row's cell disrupts NSTableView reorder regardless.
- Swapping `.onTapGesture` → `.simultaneousGesture(TapGesture())` lets the drag
  through but makes **single-click focus unreliable** (only double-click fires).

So drag needs BOTH the tap gesture and the overlay gone — i.e. it costs reliable
single-click focus AND first-click-from-background, both core (one-tap focus is
"THE feature, rock-solid"; first-mouse is "very important"). Not worth it. Kept:
the stable first-seen persisted slot order, ⌘1–9, and keyboard nav. To ever
revisit you'd need (both unverified): a **window-level** first-mouse (not a
per-row NSView overlay) and a single-click focus path that isn't `.onTapGesture`
(e.g. `List(selection:)` with a click-only binding kept separate from the
keyboard cursor).

## Worktree chip on Claude rows (2026-06-14)

We routinely run several Claude sessions on this repo at once, each in its own
`~/joystick-wt/<feature>` worktree (see CLAUDE.md "Parallel sessions"). On the
board those rows looked identical — same repo, same cwd tail — so you couldn't
tell which session was which. Now a Claude row whose session lives in a **linked**
git worktree carries a small grey branch chip (`⑂ <worktree>`) in the eyebrow,
left of the rename pill / topic.

- **Where it's computed:** `claude-hook.sh` `emit_meta()` runs one
  `git -C <cwd> rev-parse` per turn and carries the worktree leaf as a new
  optional `wt` field on the `meta` event (session-level, like title/model/ctx).
  It rides the existing meta → `SessionMeta` → `withMeta` → eyebrow path, so the
  viewer stays git-free.
- **"Linked worktree only":** the chip shows iff the git-dir sits under
  `.../worktrees/<name>` — i.e. a real linked worktree, never the main checkout
  (which would just clutter every row). Empty `wt` ⇒ no chip; non-git/`cwd` gone
  ⇒ fail-silent empty.
- **Name = the worktree directory's basename** (`rev-parse --show-toplevel`
  leaf), which in our workflow equals the branch — the name you'd recognize.
- **Scope:** Claude rows only (`wt` only flows through `meta`). Shell rows
  already show their `cwd` and aren't the parallel-session pain point.

## Queued-prompt race — new prompt swallowed by the prior turn's end (2026-06-14)

Symptom: a Claude session "misses a new prompt and keeps the old one" —
sometimes, and specifically when the prompt was **queued** (typed while the turn
was still running) or auto-injected (`<task-notification>`).

Root cause: every turn of a session shares one log id (`claude-<sid>`). The Stop
handler (`close_turn`) is slow — it re-reads the log tail and `tail -n 200 | jq`s
the transcript for the closing blurb — while `UserPromptSubmit` is fast (surface
+ pid cached). So when the next prompt fires the instant the turn ends (no human
delay, because it was queued), the new turn's `start` can be appended to the log
**before** the prior turn's `end`. The fold then sees `start(B)` open op B, then
`end(A)` remove it — marking the brand-new prompt as a finished row with the old
turn's duration/blurb, and dropping B's subsequent `active` events (no open op).
Confirmed in the live log: `start(B) ts=1781486173` immediately followed by
`end ts=1781486173 dur=343` — the 343s is turn A's real length, not 0.

Fix (viewer fold, `applyEvent`, order-robust like the existing out-of-order
`meta` handling): on a Claude `start`, if an op is still open for this id, the
prior turn's end is merely late — finalize it as history before opening the new
turn. On `end`, drop it if the open op started strictly later than the end's
implied start (`ts − dur`) — it belongs to a turn already superseded. The
emitter is left untouched (no cross-process lock; the log stays the only shared
state). Residual: if the prior turn was <1s AND queued the next, the timestamps
collide and the guard can't tell them apart — vanishingly rare.

## Mark unread (2026-06-14)

Right-click a finished row → "Mark unread" brings back its blue unseen dot (and
the dock tally). NOT inbox management — it's the inverse of a dismiss: you're
flagging a result to revisit, not clearing it (principle #1 stays intact; no
dismiss/clear, rows still vanish only when their tab closes).

Implementation reuses the existing surface-based seen model instead of adding
state: `markUnread` rewinds `seenAt[surface]` to just before the op ended, so
`unseen = seenAt < endTs` flips true. It clears the organic way — focusing that
Ghostty tab stamps `seenAt = now` again. The menu item only shows for a finished,
surfaced, currently-seen row (running/external/already-unseen have nothing to do).
Edge: marking unread the tab you're *currently* focused in Ghostty re-clears on
the next focus poll — correct, you're looking at it.

## Subagent lines vs. async Task dispatch (2026-06-15)

Symptom: live subagent (Task/Agent) lines never showed, despite the feature
being built — a row stayed dead during a long subagent run. Proven live: a 29s
subagent emitted its START and its DONE in the **same log second** while it kept
working.

Root cause: Claude Code now runs subagents **asynchronously**. The Task tool
call returns at *dispatch* ("Async agent launched successfully"), so its
`PostToolUse` fires immediately — it no longer means "subagent finished." The
hook was built for the old synchronous model and emitted `subdone` from that
PostToolUse, killing the live line the instant `PreToolUse` created it. The real
completion arrives much later as an injected `<task-notification>` carrying the
**original `<tool-use-id>`** (= the `sub` key the START used).

Fix (`claude-hook.sh`): stop emitting `subdone` from PostToolUse for Task/Agent.
The START line now lives until the turn ends, where the viewer's existing
`isRunning` gate (`endTs == nil`) hides it — **no Swift change needed**; a fresh
turn `start` also resets `liveSubagents`. Also: UserPromptSubmit now labels the
injected `<task-notification>` turn from its `<summary>` (e.g. `» Agent "…"
completed`) instead of dumping raw XML into the row.

Tradeoff (accepted): a subagent that finishes **mid-turn** fires no hook
(mid-turn completions are injected silently, unlike idle ones which fire
UserPromptSubmit), so its line lingers until the turn ends — a minor over-show
vs. the prior zero-seconds. Rejected the alternative (scan the transcript for
completed notifications on every PostToolUse) as a real per-tool-call cost in the
hot path for marginal precision. Net perf is neutral-to-faster: removes a
per-Task log write, adds only a cheap string check in the once-per-turn
UserPromptSubmit path.

## Cleared-session orphan row — /clear rotates the session id (2026-06-15)

Symptom: after `/clear`, the terminal's row keeps showing the PREVIOUS prompt (a
stale finished turn) while the new turn shows up as a *second* row — one terminal,
two Claude rows — and the stale one never clears on its own.

Root cause: `/clear` (and `/resume`, `/compact`, or exiting+restarting `claude`
in a tab) spins up a NEW Claude Code `session_id` on the same surface and pid.
Claude rows group by `claude-<sid>` (deliberately — surface capture is best-
effort), so the cleared conversation becomes an orphaned group keyed by the dead
sid. It lingers because (a) finished rows show while their surface exists, and the
surface now hosts the new session, and (b) the only liveness reaper is `pruneOpen`
by pid — but that pid is the still-alive claude process now SHARED with the new
session, so even a dangling *running* orphan would never expire. Confirmed in the
live log: id flipped `claude-695bc69b…` → `claude-4a177f17…`, same surface
`124B6EC8`, same pid `37850`; the pre-clear turn had finished normally (a stray
idle `waiting` afterward was a no-op — the op had already left `open`).

Fix (viewer fold, `EventFold.apply`, sibling to the queued-prompt guard): a
Ghostty surface hosts exactly one live claude process, so when a NEW claude
`start` arrives on a surface (or pid) an earlier session held, that earlier
session is gone — retire its ops from both `open` and `done`. Match on surface
(the terminal) OR pid (the process), whichever the new start carries; never the
same id (that's the queued-prompt case above). Surface is the normal match; pid
is the fallback when capture missed and is itself airtight (live processes don't
share pids). Emitter untouched, log stays the only shared state. Covered by
eventfold tests 13/13b.

Scope note: this also tidies a plain exit-then-restart of `claude` in one tab (the
old finished turn retires when the new session takes the surface) — correct per
the mirror principle (the row reflects what the terminal is doing now). It does
NOT touch the claude→shell-command-in-the-same-tab case (different group keys).

## Roadmap

### v0.1 — shareable (1–2 weekends)
- [x] One app: MenuBarExtra owns the menubar; SwiftBar plugin retired
      (2026-06-13). Notifications still osascript → UNUserNotificationCenter
      deferred to chunk 4 (needs signing).
- [ ] First-run onboarding: buttons to install shell integration (.zshrc),
      Claude hooks (settings.json merge), Ghostty notify config; demo with
      `sleep 8` so it works in the first 30 seconds
- [ ] Real Xcode project, Developer ID signing + notarization, DMG,
      `brew install --cask joystick`
- [ ] App icon, empty states
- [ ] Move polling → FSEvents file watching; move ps/stat checks off main thread
- [ ] git repo + open source (trust story: reads your commands → must be
      100% local, no network, open code)
- [ ] Post to Ghostty Discord for feedback

### v0.2
- [ ] Agent inbox: waiting items get their own section, sorted by blocked time
- [x] Global hotkey to summon window; ⌘1–9 jump to nth op (2026-06-14) —
      see "Keyboard-first window" below
- [ ] bash (bash-preexec) + fish support
- [ ] Settings UI: thresholds, ignore list, notification rules
- [ ] Launch at login; Sparkle auto-updates

### v0.3
- [x] Document the event format (EVENTS.md) + `joystick log` CLI for custom
      events — SHIPPED 2026-06-13. (EAS webhook → `joystick log done …` now
      works for --no-wait/cloud builds; viewer keeps external tty=cli events.)
- [ ] Other agent CLIs: Codex, Gemini
- [ ] Focus adapters: iTerm2/Terminal.app (AppleScript), tmux switch-client,
      VS Code deep links
- [ ] Launch: Show HN + 20s screen recording (6 tabs, 3 agents, the inbox)

## Service detection (terminals host services, not just ops)
Terminal taxonomy: idle / running an op / hosting a service / interactive app
(IGNORE list). Services (yarn dev, vite, tsc --watch) must not trigger
"waiting for input?".
- Signal 1 — SHIPPED 2026-06-12: at the moment the stall heuristic would
  fire, check fg process group for a listening TCP socket (lsof -sTCP:LISTEN);
  listener → suppress. Catches all port-bound dev servers on first run.
- Signal 2 — TODO: exit-history learning — command heads whose past runs never
  exited 0 (only kill/-1/130) are services; catches portless watchers
  (tsc --watch) from second run. Wants history keyed by (cmd head, cwd) —
  same refactor the ETA feature needs.
- Signal 3 — TODO: sticky unflag after self-resumed output (tty mtime
  advances without atime) so log-quiet servers don't flap amber.
- Display state — SHIPPED 2026-06-12: services get antenna icon (app) / ◉
  green (menubar), "serving" subtitle, green uptime, sorted below active ops;
  header reads "N running · M serving · K needs you". Verified live: caught
  ngrok http with zero config, not just yarn dev.
- Future: quiet endings — no done-notification/unseen badge when a service
  is intentionally Ctrl-C'd (exit -1/130).

## Idea backlog (2026-06-12 brainstorm, roughly prioritized)

1. **ETAs from history** — we have every past run of every command; show
   "usually ~14m, ~8m left" + progress bar on running rows. Median duration
   keyed on (first words of cmd, cwd). Unique to us; high delight, low effort.
2. **Names over commands** — show Claude session topic (terminal title via
   AppleScript `name`) instead of raw prompt; per-project colored chip
   (cwd basename); optional grouping by project.
3. **Command sanitizing — SHIPPED v2 (2026-06-12)** — `joystick-redact.zsh`
   (shared by both emitters, 18-case suite at /tmp/redact-test.zsh).
   Design decision (Kishan): NO secret-detection heuristics — provider regex
   zoos and entropy guessing surprise people and rot. Two deterministic rule
   kinds only: (1) context masking like git/CI do — sensitive flag/env
   values, URL userinfo, Bearer/Basic, curl -u; (2) structural elision —
   any standalone token ≥24 chars that isn't a flag/path/URL shows as
   first-4-chars+"…" (we never claim it's a secret; long blobs are
   unreadable in a dashboard anyway, and this catches every provider's
   tokens with no list). Never market as "secret detection" — market as
   "what we store and how we mask it", fully predictable. Plus: chmod 600,
   Time Machine exclusion, JOYSTICK_NOLOG_DIRS, JOYSTICK_LOG_MODE=head
   (by-construction guarantee, lossy), joystick-scrub.sh. Documented gaps:
   bare passwords w/o flag context (`mysql -phunter2`), slash-containing
   blobs (AWS secret keys — but those ride context rules in practice).
   zsh_history still stores everything unredacted — README note.
4. **Row actions** — re-run (Ghostty `input text` + `send key`), copy command,
   stop (signal pid). Especially on waiting rows: "stuck → kill" in place.
5. **Triage hotkey** — global shortcut jumps to longest-waiting item;
   summons window when nothing waits.
6. **Privacy story (v0.1)** — PRIVACY.md: exactly what's stored where, the
   masking rules, the modes; note that zsh_history keeps the same commands
   unredacted. Decision 2026-06-12: keep the plaintext log (threat model:
   same-user processes already have zsh_history; FileVault covers at-rest;
   Time Machine exclusion applied). **Ephemeral mode** (emitters → Unix
   socket → RAM only, zero disk) is the future opt-in for the paranoid
   cohort — costs Finished-history persistence and ETAs, so never the
   default. Per-line encryption evaluated and rejected (can't stop same-user
   attacker, kills the open JSONL format).
7. **Cloud lane (v0.4+)** — `joystick log` CLI + webhook ingestion (EAS
   --no-wait, GitHub Actions, Vercel). Opt-in separate section — don't break
   the mirror principle. CLI first, webhooks second.

Process note: use it for a week, keep an annoyances list below — the top 3
annoyances are the real v0.2.

## Considered & declined

- **Type-and-send terminal input from Joystick (2026-06-14)** — stay focused on
  the board, arrow through rows, compose and send your next input to the selected
  terminal/Claude session without switching. Mechanically feasible: Ghostty's
  AppleScript `perform action "text:…"` injects into a surface by id (no focus
  bounce, only Automation perms we already hold; not the Accessibility/keystroke
  hack). **Declined** anyway: the teleport (⌥⌘J → tab) is already <1s and IS the
  product, so input shaves an already-cheap step rather than filling a gap. Most
  terminal interaction is read-*then*-respond — answering blind is where you
  approve the wrong thing — so a composer only helps the proactive fire-and-forget
  case (queue Claude's next instruction), and even that is marginal outside heavy
  multi-agent triage. Bigger cost: it flips Joystick from observe-only mirror
  (principle #1) into an actor, denting the can't-hurt-you safety that makes the
  log trustworthy. **Reopen only if** the workflow becomes orchestration-console
  (dispatch a fleet of parallel agents from one surface); then build just the
  narrow Claude "queue next message" composer and degrade everything structured
  (permission prompts, shell input, passwords) to "⏎ jumps to the tab." Don't
  chase those — that's how it becomes a bad terminal emulator.

## Annoyances (add as encountered)

-

## Craft backlog
- Subtle pulse on running rows; amber treatment for waiting
- Actionable notifications (click → focus tab) via UNUserNotificationCenter
- Notification when an op *enters* waiting (the "eas submit sat for 10 min" fix)
- Pin state persistence; window vibrancy/translucency pass
- Name TBD — "joystick" is functional; control-tower/radar metaphor may
  screenshot better

## Known issues / debt
- Stall heuristic false-positives on silent network waits (rsync -q, hung ssh)
  — arguably still useful info; label it "waiting for input?" with the ?
- Interrupted Claude turns (Esc) leave a dangling running row until the next
  prompt (Stop hook doesn't fire on interrupt). Since the queued-prompt-race fix,
  that next prompt now closes the dangling turn into history instead of dropping
  it — but as a ✓ with a synthetic duration (no real exit/blurb), so an
  interrupted turn reads as a short success. Acceptable for now; an "ended,
  outcome unknown" glyph would be the real fix.
- Ad-hoc codesigning → TCC automation re-prompts after each rebuild (fixed by
  real Developer ID signing in v0.1)
- 1s timer polling (mtime-gated since 2026-06-12 review, so cheap) — FSEvents
  is the proper fix, v0.1
- Dev note: SourceKit flags "'main' attribute cannot be used..." on
  Joystick.swift — false positive; build-app.sh passes -parse-as-library
- Queued prompt (typed while a turn is still running) shows at queue-time, not
  pickup — the row jumps off the still-running turn onto the queued one. Root
  cause is upstream: `UserPromptSubmit` fires on **submit**, and there is no
  "picked up" hook event, so a `start` for a queued prompt is indistinguishable
  from "it's now running." The queued-prompt-race fix above assumes the prior
  turn just ended (right for a slow Stop) and promotes the new prompt
  immediately, which is wrong when the prior turn is genuinely still going. The
  behavior is also erratic + undocumented (one queued message fired
  `UserPromptSubmit` 4× over 83s; the hook's `start` ts preceded the transcript
  record by ~40s, i.e. submit-time not pickup-time). We can't reliably tell
  queued-vs-running from hook events, so we don't guess. Real fix: a Claude Code
  "turn actually started" signal — worth a /feedback request. (2026-06-15)

## Resolved in 2026-06-12 architecture review
- Log re-parsed every 1s tick on main thread → now gated on (mtime, size)
- ttyInputWait (ps spawn) blocked main thread → background queue, throttled 5s
- UserDefaults seen-state written every 2s → only on focus change
- joystick-redact.zsh assumed default zsh options (bash_rematch would silently
  break MATCH vars) → emulate -L zsh in both functions
- Redaction test suite lived in /tmp → ~/joystick/tests/redact-test.zsh
- Swift concurrency: ttyInputWait/stallSecs nonisolated; build has 0 warnings
