# 🕹 Joystick

**Mission control for your terminal.** A macOS dashboard that mirrors what every
Ghostty tab is doing — shell commands, Claude Code sessions, dev servers — and
gets you back to the right tab in one click. Zero workflow change: it just
observes what you already do.

> You have 12 tabs open and 5 Claude sessions running. Which one needs you?

Joystick answers that at a glance, from your menubar or a second monitor.

## What it shows

Every terminal becomes one row, sorted by urgency, in one of five states:

| | State | Meaning |
|---|---|---|
| ✋ | **needs you** (amber) | a prompt or agent is blocked waiting on your input |
| ▶ | **working** (blue) | a command/agent is running — with elapsed time |
| ◉ | **serving** (green) | a long-lived service (dev server) is up |
| ✓ / ✗ | **result** | finished — exit status and duration |
| • | **unseen** (blue dot) | a result you haven't looked at yet |

Click any row to jump straight to that Ghostty tab. Closing a tab is the only
"dismiss" — Joystick is a live mirror of your terminals, never an inbox to
manage.

It understands Claude Code sessions natively (each session is one row, its
prompts collapse into history) and tells you the moment one is blocked on a
permission prompt or question — so an agent never sits waiting unnoticed.

## How it works

Four small layers; the event log is the only shared state.

```
shell / Claude hooks  →  ~/.local/state/joystick/events.jsonl  →  menubar app
   (emitters)               (append-only JSONL, the source)        (viewer)
```

- **Emitters** — zsh `preexec`/`precmd` hooks and Claude Code hooks append
  `start`/`end`/`waiting` events. Tiny, stateless, fail-silent.
- **Event log** — one open JSONL file. Anything can emit to it (CI, webhooks,
  a Makefile), which is how Joystick grows beyond the terminal.
- **Viewer** — a native SwiftUI menubar app reads the log and renders the rows.
- **Focus** — clicking a row drives Ghostty via AppleScript to focus the exact
  surface (or reopen it at the right directory if the tab is gone).

## Requirements

- macOS 14+
- [Ghostty](https://ghostty.org) (the focus/jump features are Ghostty-specific)
- zsh

## Install (developer / pre-release)

> v0.1 packaging (one-click installer, signed app, Homebrew cask) is in
> progress — see [`PACKAGING.md`](PACKAGING.md). For now:

```sh
git clone https://github.com/kishan-ptl/joystick ~/joystick
cd ~/joystick

# 1. shell integration
echo '[ -f ~/joystick/joystick.zsh ] && source ~/joystick/joystick.zsh' >> ~/.zshrc

# 2. Claude Code hooks — merge the 4 hooks in claude-hook.sh into
#    ~/.claude/settings.json (UserPromptSubmit/Stop/Notification/PostToolUse)

# 3. build & launch the app
./build-app.sh && open ~/Applications/Joystick.app
```

Open a new tab and run something long (`sleep 20`) to see it appear.

## Privacy

Joystick records the commands you run, so trust is the product: **100% local,
no network, ever.** One `chmod 600` log, excluded from Time Machine, with
commands sanitized before they're written. Read the full story — including how
to exclude directories or log command-heads only — in
[`PRIVACY.md`](PRIVACY.md).

## Status

Pre-v0.1, Ghostty + zsh + macOS. Roadmap, design principles, and decision
history live in [`NOTES.md`](NOTES.md); the path to a shareable release is in
[`PACKAGING.md`](PACKAGING.md).
