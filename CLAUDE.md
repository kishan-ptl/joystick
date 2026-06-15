# Joystick

Mission control for your terminal. A macOS dashboard that mirrors what every
Ghostty tab/pane is doing — shell commands, Claude Code sessions, dev servers —
and gets you back to the right tab in under a second. Zero workflow change: it
observes what you already do.

This repo (`~/joystick`, private GitHub `kishan-ptl/joystick`) IS the live
system — the running scripts/app are these files, not copies. Edit here.

## Architecture

Four layers, each fails without corrupting the others; the log is the only
shared state and doubles as the future integration API.

- **Emitters** (tiny, stateless, fail-silent) append events:
  - `joystick.zsh` — zsh preexec/precmd hooks (`_joystick_*`), sourced from `~/.zshrc`.
  - `claude-hook.sh` — Claude Code hooks (UserPromptSubmit / PreToolUse / Stop(+StopFailure) / Notification / PostToolUse(+…Failure)) in `~/.claude/settings.json`. `PreToolUse` emits live activity at the *start* of a Task/Agent only (subagents run long; without it the row sits dead at "working" until the subagent finishes). On turn close it also emits a `meta` event (session title/model/mode/context) and attaches Claude's closing blurb as `msg` on the `end` event.
  - `joystick` CLI (`joystick log …`, tty `cli`) — external events from CI, webhooks, Makefiles. Symlinked onto PATH at `~/.local/bin/joystick`. Schema + usage in `EVENTS.md`.
- **Event log** — `~/.local/state/joystick/events.jsonl`, append-only JSONL,
  one source of truth. Events: `start` / `end` / `waiting` / `active` / `meta`.
  Fields: id, cmd, cwd, pid, tty, surface, ts, exit, dur, msg (+ `meta` carries
  title, model, mode, ctx). `chmod 600`.
- **Viewer** — `Joystick.app` (SwiftUI), source `Joystick.swift`, built by
  `build-app.sh` → `~/Applications/Joystick.app`. Owns both the menubar
  (`MenuBarExtra`) and the window. The window is **keyboard-first**: a global
  hotkey (`⌥⌘J`, Carbon `RegisterEventHotKey`) summons/toggles it, and ↑↓ / ⏎ /
  ⌘1–9 / type-to-filter drive a stable, first-seen, drag-reorderable flat list
  (newest on top, slot order persisted) — while the menubar popover keeps the
  prioritized waiting-on-top sort. The window's fixed order is deliberate, not a
  regression of the sort; see NOTES.md "Keyboard-first window (2026-06-14)".
  (A SwiftBar python plugin was the original menubar; retired 2026-06-13 —
  recoverable from git history if ever needed.)
- **Interaction** — `joystick-focus.sh` (AppleScript): click a row → focus that
  exact Ghostty surface (by id; cwd fallback; reopen if the tab is gone).

`joystick-redact.zsh` (shared sanitizer) and `joystick-scrub.sh` (retroactive
log cleanup) support the emitters.

## Design principles — do not regress these

These were decided by using the tool; they define what it is.

1. **It is a live MIRROR of Ghostty, never an inbox to manage.** No dismiss
   buttons, no "clear." Closing a tab is the only dismissal; finished rows show
   only while their surface still exists.
2. **The row unit is the terminal, not the command.** One group per terminal:
   current op (running, or latest result) is the row; ≤3 earlier results are
   dimmed history beneath; older is dropped. Grouping key: shell commands by
   Ghostty **surface**, Claude sessions by **session id** (`claude-<sid>`,
   stable across turns — robust when surface capture misses).
3. **NO secret-detection heuristics.** `joystick-redact.zsh` does only two
   deterministic things: context masking (sensitive flag/env values, URL
   userinfo, Bearer/Basic, curl -u) and structural elision (standalone tokens
   ≥24 chars, not flag/path/URL → first-4-chars + "…"). Never claim or market
   "secret detection" — it's "what we store and how we mask it," fully
   predictable. Provider-token regex zoos and entropy guessing were rejected.
4. **Terminal taxonomy:** idle / running an **operation** (has an end you await)
   / hosting a **service** (runs until killed — detected by a listening TCP
   socket, never a command list) / interactive app (the IGNORE set). Services
   must never trigger "waiting for input?".
5. **State vocabulary (the whole UI at a glance):** a softly breathing yellow
   light = needs you now (calm pulse, not an alarming blink) · ▶ blue = working ·
   ◉ green = serving · ✓/✗ = result · blue dot = unseen result (cleared when you
   view that tab in Ghostty, by any means). The focused Ghostty tab's row also
   carries a quiet neutral-grey highlight ("you are here").
6. **100% local, no network.** The log records every command, so trust is the
   product: plaintext is `chmod 600`, Time-Machine-excluded, redacted at write
   time. Keep it that way.

## Working in this repo

- **Rebuild the app:** `./build-app.sh` (swiftc, ad-hoc codesign, bundle id
  `dev.kishan.joystick`), then `pkill -x Joystick; open ~/Applications/Joystick.app`.
- **After editing `joystick-redact.zsh`:** run `zsh tests/redact-test.zsh`
  (must stay green) — it's load-bearing.
- **After editing `Joystick.swift`:** rebuild + restart (above) to see changes.
- **zsh gotcha:** redaction uses `emulate -LR zsh` — the **R** matters. Plain `-L`
  does NOT reset an already-set `bash_rematch`/`glob_subst`, which silently breaks
  both `$MATCH` masking and the literal token elision. Keep the R.
- **Log lines must stay < ~4096 bytes (PIPE_BUF)** so concurrent `>>` appends
  from many shells/hooks stay atomic. That's why `cmd` is capped at 300 and
  prompts at 120 — do NOT raise those caps. Events carry `"v":1` (schema
  version); the log contract is in `EVENTS.md`.
- **SourceKit false positive:** "'main' attribute cannot be used in a module
  that contains top-level code" on `Joystick.swift` is expected — `build-app.sh`
  passes `-parse-as-library`. Not a real error.
- Already-open terminal tabs from before a change still run the old emitter;
  only fresh tabs / `source ~/.zshrc` pick up edits.

## Parallel sessions — work in a worktree by default

Several Claude/agent sessions often run on this repo at once and will clobber
each other otherwise (we've hit this repeatedly). **Default to working in a git
worktree, not the main checkout, unless the user explicitly tells you to edit
`main` directly.**

- Ideal: be launched with `claude --worktree <feature>` so you start isolated.
- If you're already on `main` and about to edit existing files, first:
  `git worktree add ~/joystick-wt/<feature> -b <feature>`, then work there.
- **Don't clobber the live app:** `build-app.sh` always writes to
  `~/Applications/Joystick.app` and the event log is shared, so a worktree
  build/run disturbs the running system. When testing from a worktree, build to
  a throwaway app path, or coordinate with the user before rebuilding the live app.
- **Scope your commits:** `git add <your specific files>`, never `git add -A` /
  `git commit -am` — another session may have uncommitted work in the tree, and
  a blanket add sweeps it into your commit. Check `git status` first.
- When done: commit on your branch, merge to `main`, then `git worktree remove`.
- Exception: purely **additive new files** can't collide — a worktree is
  optional for those (but still fine).

## More

`NOTES.md` holds the roadmap (v0.1 = shareable: single MenuBarExtra app,
onboarding installer, notarized, brew cask), the idea backlog, the debt
ledger, and the full decision history. Read it before larger changes.
