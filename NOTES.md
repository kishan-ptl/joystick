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
- Viewers:
  - `~/Applications/Joystick.app` — SwiftUI (source: Joystick.swift, build:
    build-app.sh)
  - `~/.config/swiftbar/joystick.1s.py` — SwiftBar menubar plugin
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

## Roadmap

### v0.1 — shareable (1–2 weekends)
- [ ] One app: MenuBarExtra absorbs the SwiftBar plugin (menubar + window +
      notifications in a single .app; drop SwiftBar/python dependency)
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
- [ ] Global hotkey to summon window; ⌘1–9 jump to nth op
- [ ] bash (bash-preexec) + fish support
- [ ] Settings UI: thresholds, ignore list, notification rules
- [ ] Launch at login; Sparkle auto-updates

### v0.3
- [ ] Document the event format; `joystick log` CLI for custom events
      (EAS webhooks → ntfy/joystick for --no-wait builds)
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
- Interrupted Claude turns (Esc) may leave a dangling running row until the
  next prompt overwrites it (Stop hook doesn't fire on interrupt)
- Ad-hoc codesigning → TCC automation re-prompts after each rebuild (fixed by
  real Developer ID signing in v0.1)
- Two viewers duplicate parse/filter logic (Swift + python) — accepted until
  MenuBarExtra absorbs the SwiftBar plugin in v0.1
- 1s timer polling (mtime-gated since 2026-06-12 review, so cheap) — FSEvents
  is the proper fix, v0.1
- SwiftBar plugin runs osascript (live surfaces) every 5s refresh
- Dev note: SourceKit flags "'main' attribute cannot be used..." on
  Joystick.swift — false positive; build-app.sh passes -parse-as-library

## Resolved in 2026-06-12 architecture review
- Log re-parsed every 1s tick on main thread → now gated on (mtime, size)
- ttyInputWait (ps spawn) blocked main thread → background queue, throttled 5s
- UserDefaults seen-state written every 2s → only on focus change
- joystick-redact.zsh assumed default zsh options (bash_rematch would silently
  break MATCH vars) → emulate -L zsh in both functions
- Redaction test suite lived in /tmp → ~/joystick/tests/redact-test.zsh
- Swift concurrency: ttyInputWait/stallSecs nonisolated; build has 0 warnings
