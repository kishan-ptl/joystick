# Privacy

Joystick watches what your terminals are doing. That means it records the
commands you run — so the only acceptable design is one you can fully predict.
This document is the whole story: what's stored, where, how it's masked, and
how to turn it off.

**TL;DR:** 100% local, no network, ever. One plaintext log file, `chmod 600`,
excluded from Time Machine, with commands sanitized before they're written.

## What's stored

A single append-only file: `~/.local/state/joystick/events.jsonl`
(or `$XDG_STATE_HOME/joystick/events.jsonl`).

One JSON object per line, two events per operation (`start` and `end`):

| Field | Example | Notes |
|---|---|---|
| `cmd` | `git push origin main` | the command (or `❯ <prompt>` for a Claude turn) — **sanitized**, see below |
| `cwd` | `/Users/you/project` | working directory |
| `pid`, `tty`, `surface` | | process id, terminal device, Ghostty surface id |
| `ts`, `dur`, `exit` | | timestamps, duration, exit code |

Alongside it: small `surface-*` / `waiting-*` marker files (Ghostty surface ids
and transient waiting state), pruned after 7 days.

## What's NOT stored

- **No command output.** Only the command line itself — never stdout/stderr.
- **No network, no telemetry, no analytics, no cloud.** Joystick makes zero
  network calls. The viewers only ever read the local log.
- **No keystrokes** — only whole commands, captured by your shell's own
  `preexec` hook (the same mechanism that writes your shell history).

## How commands are masked

Before any command is written, `joystick-redact.zsh` sanitizes it with two
**deterministic** rules — no heuristics, no "secret detection," nothing that
guesses. It's predictable by design:

1. **Context masking** — the value is replaced with `•••` when it's clearly a
   credential by position:
   - sensitive-named flags: `--password X`, `--token=X`, `--api-key X`, `--auth …`
   - sensitive env assignments: `PGPASSWORD=…`, `STRIPE_SECRET_KEY=…`
   - URL userinfo: `https://user:pass@host` → `https://•••@host`
   - `Authorization: Bearer …` / `Basic …`, and `curl -u user:pass`
2. **Structural elision** — any standalone token ≥24 chars that isn't a flag,
   path, or URL is shortened to its first 4 chars + `…` (e.g. `ghp_AbCd…`).
   We don't claim it's a secret; long opaque blobs just aren't worth storing in
   full, and this catches every provider's tokens with no list to maintain.

This is **not** marketed as secret detection — it's "here is exactly what we
store and how we mask it." Verified by `tests/redact-test.zsh`.

### Honest gaps

No local rule can catch everything, because a secret is defined by intent, not
shape. Known gaps: a bare password with no flag context (`mysql -phunter2`), and
secrets that look like ordinary words. For those, use the opt-outs below.

## Your controls

- **`JOYSTICK_NOLOG_DIRS`** — never log anything run in these directory trees:
  ```sh
  JOYSTICK_NOLOG_DIRS=(~/secrets ~/work/client-x)   # set before sourcing joystick.zsh
  ```
- **`JOYSTICK_LOG_MODE=head`** — log only the command head (`eas build`), never
  arguments. A by-construction guarantee, at the cost of detail.
- **Scrub retroactively** — `joystick-scrub.sh` re-applies the current masking
  rules to the existing log (keeps a backup you delete once verified).
- **Delete it all** — `rm ~/.local/state/joystick/events.jsonl`. Joystick
  recreates an empty one; nothing else depends on it.

## At-rest protection

- The log is `chmod 600` (only your user can read it).
- The state directory is excluded from Time Machine backups.
- The log auto-rotates past ~5MB (keeps the recent tail).

## Perspective

Your shell already stores every command you run, unredacted and forever, in
`~/.zsh_history`. Joystick's log is the same class of data, but **masked,
`600`, backup-excluded, and trimmed** — strictly better protected than what's
already on your disk. The realistic threat is another process running as you,
and that process can already read your shell history.

## Roadmap

An optional **ephemeral mode** (events kept in memory only, nothing written to
disk) is planned for users who want zero on-disk footprint — at the cost of
finished-history persistence and the duration-estimate feature. Per-line
encryption was considered and rejected: it can't stop a same-user attacker (the
app must decrypt to display) and would destroy the open, inspectable log format.
