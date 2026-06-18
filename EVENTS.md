# Event format

Joystick reads one append-only JSONL file —
`~/.local/state/joystick/events.jsonl` (or `$XDG_STATE_HOME/joystick/...`),
one JSON object per line. **This is the integration surface:** anything that
can append a line can put work on the board.

## Event types

Each operation is two events sharing an `id` — a `start` and an `end`.
`waiting`/`active` optionally toggle the needs-you state in between.

```jsonc
// start
{"v":1,"kind":"shell","ev":"start","id":"<unique>","cmd":"<text>","cwd":"<path>","pid":<int>,"tty":"<dev>","surface":"<ghostty-id>","ts":<unix>}
// end   (dur optional — viewer computes end.ts - start.ts if omitted; exit -1 = killed)
//        (msg optional — Claude turns carry the closing blurb; shown on the finished row)
{"v":1,"ev":"end","id":"<same id>","exit":<int>,"dur":<secs>,"ts":<unix>}
// waiting / active  (optional — drives the amber "needs you" state)
{"v":1,"ev":"waiting","id":"<id>","msg":"<why>","ts":<unix>}
{"v":1,"ev":"active","id":"<id>","act":"<what it's doing>","ts":<unix>}
// active + sub  (Claude only — one live SUBAGENT line; `sub` = Task tool_use_id)
//        start: carries `act` (the subagent's label); finish: carries subdone:true.
//        SESSION-scoped: a subagent can outlive its turn (the row is marked done while
//        it runs on), so the line persists until its <task-notification> finish.
{"v":1,"ev":"active","id":"<id>","act":"Task: <desc>","sub":"<tool_use_id>","ts":<unix>}
{"v":1,"ev":"active","id":"<id>","sub":"<tool_use_id>","subdone":true,"ts":<unix>}
// active + shell  (Claude only — one live BACKGROUND-SHELL line; run_in_background Bash)
//        Like `sub`, also SESSION-scoped: a bg shell outlives the turn that launched it,
//        so its line persists across turns until its <task-notification> finish.
{"v":1,"ev":"active","id":"<id>","act":"<command>","shell":"<tool_use_id>","ts":<unix>}
{"v":1,"ev":"active","id":"<id>","shell":"<tool_use_id>","subdone":true,"ts":<unix>}
// meta  (Claude only — emitted on turn close; session-level, not per-turn)
//        (name/color optional — a deliberate rename + agent color; shown as a row badge)
//        (wt optional — git worktree leaf when the session runs in a LINKED worktree; shown as a row chip)
//        (goal optional — the `/goal` completion condition; shown as a row chip, superseding the auto-topic. Absent/empty when unset or met)
{"v":1,"ev":"meta","id":"<id>","title":"<topic>","model":"<id>","mode":"<perm-mode>","name":"<rename>","color":"<palette>","wt":"<worktree>","goal":"<condition>","ctx":<tokens>,"ts":<unix>}
// reset  (Claude only — emitted on /clear|/resume|/compact, before any prompt)
//        A new session took over this terminal: id = the NEW claude-<sid>, pid = the
//        (unchanged) claude process. Retires any earlier session's row on that pid NOW,
//        so the cleared terminal stops showing the old conversation. No new op opens.
{"v":1,"ev":"reset","id":"<new id>","pid":<int>,"ts":<unix>}
```

> **Line-size invariant (load-bearing):** keep every line **under ~4096 bytes
> (PIPE_BUF)** so concurrent `>>` appends from multiple producers stay atomic
> and never interleave. Cap free-text fields — Joystick caps `cmd` at 300
> chars and Claude prompts at 120. Raising those caps past ~3KB can corrupt the
> log under concurrency.

## Fields

| field | meaning |
|---|---|
| `v` | schema version (currently `1`); absent on pre-versioning events |
| `kind` | `shell` / `claude` / `external` — producer type (on `start`). Legacy events omit it; derive from `tty` |
| `id` | groups start/end; Claude sessions reuse `claude-<sid>` across turns |
| `cmd` | command line / prompt / op name (**sanitized** — see PRIVACY.md) |
| `cwd` | working directory (click-to-focus / jump target) |
| `pid` | local process id; the viewer drops a running row when it dies |
| `tty` | terminal device (shell ops only; empty for claude/external — see `kind`) |
| `surface` | Ghostty surface id, for click-to-focus |
| `ts` | unix seconds |
| `exit` / `dur` / `msg` | end status / duration / reason (waiting why, or Claude's closing blurb on `end`) |
| `act` | `active` only — live subtitle (tool just used, or a subagent's label); **sanitized** |
| `sub` / `subdone` | `active` only — a live subagent line: `sub` = Task `tool_use_id` (matches start↔finish; the completion `<task-notification>` carries the same id); `subdone:true` ends it. Concurrent subagents each get their own line. **Session-scoped** — it persists across the turn's end (the row stays marked done with a "⟳ bg" chip) until the agent exits |
| `shell` / `subdone` | `active` only — a live background-shell line: `shell` = the `run_in_background` Bash `tool_use_id` (matches start↔finish; the completion `<task-notification>` carries the same id); `subdone:true` ends it. **Session-scoped** like `sub` — it persists across turns until the shell exits |
| `title` / `model` / `mode` / `ctx` | `meta` only — session topic, model id, permission mode, context-window tokens used |
| `name` / `color` | `meta` only — user-set session rename (**sanitized**) + agent color name; shown as a row badge. Empty/absent when unset |
| `wt` | `meta` only — git worktree leaf (the worktree directory's basename) when the session runs in a LINKED worktree; shown as a row chip. Empty/absent on the main checkout |
| `goal` | `meta` only — the session's `/goal` completion condition (**sanitized**); shown as a row chip that supersedes the auto-topic. Empty/absent when no goal is set or it has been met |

## Producers

- **`joystick.zsh`** — local shell commands (`kind: shell`; preexec/precmd hooks).
- **`claude-hook.sh`** — Claude Code turns (`kind: claude`).
- **`joystick` CLI** — external / CI / webhook events (`kind: external`), below.

## External events — the `joystick` CLI

Emit from anywhere with a shell — CI, webhooks, Makefiles, cron:

```
joystick log done  <name> [--exit N] [--took S]   # completed op → Finished
joystick log start <name> [--id ID]               # begin → running; prints its id
joystick log end   <id>   [--exit N]              # finish a started op
```

External events (`kind: external`) have no Ghostty surface or live pid, so the viewer
keeps them regardless of surface/pid liveness — running ones expire 24h after
`start` if no `end` arrives. They are informational: not click-to-focus (no
tab) and they don't raise the unseen badge.

### Examples

EAS build webhook fires when a cloud build finishes:
```sh
joystick log done "eas build (ios prod)" --exit "$STATUS" --took "$SECONDS"
```

Makefile target:
```make
deploy:
	@id=$$(joystick log start deploy); ./do-deploy.sh; joystick log end "$$id" --exit $$?
```

Manual long op:
```sh
id=$(joystick log start "migrating prod DB"); ...; joystick log end "$id"
```
