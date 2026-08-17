#!/bin/zsh
# codex-hook.sh — Codex CLI hook handler for joystick. The Codex analogue of
# claude-hook.sh, wired in ~/.codex/hooks.json to: SessionStart,
# UserPromptSubmit, PostToolUse, PermissionRequest, Stop.
#
# Codex 0.144+ ships a Claude-compatible hooks engine (events configured in
# ~/.codex/hooks.json, JSON delivered on stdin) — SEPARATE from the single
# `notify` slot in config.toml, so this composes with the desktop app's notify
# client and any plugin hooks instead of clobbering them.
#
# SessionStart       -> "reset" on clear|resume|compact (retire prior row now)
# UserPromptSubmit   -> "start" (turn shows as running) + "meta" (model/mode)
# PostToolUse        -> "active" (live activity subtitle; clears waiting)
# PermissionRequest  -> "waiting" (blocked on you)
# Stop               -> "end" (exit 0) + closing blurb
#
# Codex is cleaner than Claude in two ways we lean on: every payload carries
# `model` + `permission_mode` (so meta needs no transcript parse), and Stop
# hands us `last_assistant_message` directly (no transcript-poll race).
#
# Like the Claude hook, this only ever WRITES to the log — no desktop
# notifications; the app's session strip is the push channel now.
set -u

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/joystick/events.jsonl"
mkdir -p "${LOG:h}"
# Source our shared sanitizer from our OWN directory (this hook is executed by
# Codex from $JOYSTICK_HOME when installed, or ~/joystick in the dev repo).
_jdir=${0:A:h}
[[ -r $_jdir/joystick-redact.zsh ]] || _jdir=${JOYSTICK_HOME:-$HOME/.config/joystick}
[[ -r $_jdir/joystick-redact.zsh ]] || _jdir=$HOME/joystick
source "$_jdir/joystick-redact.zsh"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
model=$(jq -r '.model // empty' <<<"$input")
mode=$(jq -r '.permission_mode // empty' <<<"$input")
now=$(date +%s)
id="codex-$sid"

[[ -n $sid ]] || exit 0   # nothing to key on; fail silent like every emitter

# Walk up the process tree to find the long-lived codex process, so the viewer's
# pid-liveness check tracks the session, not this short-lived hook. Codex runs
# hooks via `$SHELL -lc`, so our parent is a shell whose parent is codex; the
# real binary's basename is codex-<arch>-apple-darwin, so match codex*.
codex_pid() {
  local p=$PPID comm i
  for i in 1 2 3 4 5 6; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "${comm:t}" in
      codex*) print -r -- "$p"; return ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [[ -n $p && $p != 0 && $p != 1 ]] || break
  done
  print -r -- "$PPID"
}

# Session metadata: model + permission mode, both carried on EVERY Codex hook
# payload, so unlike Claude this needs no transcript read. Emitted at turn start
# and turn close so a mid-session model/mode switch shows on the next turn.
emit_meta() {
  [[ -n $model || -n $mode ]] || return 0
  jq -cn --arg id "$id" --arg model "${model:-}" --arg mode "${mode:-}" --argjson ts "$now" \
    '{v:1,ev:"meta",id:$id,model:$model,mode:$mode,ts:$ts}' >> "$LOG"
}

case $event in
  SessionStart)
    # clear/resume/compact rotate to a NEW session_id on the SAME codex process
    # and terminal, with no prompt submitted yet — emit a `reset` so the viewer
    # retires the prior session's row immediately instead of showing the old
    # conversation until your first prompt. startup is a fresh process (nothing
    # to retire), so skip it. The pid carries the match (the codex process is
    # unchanged across the rotation, and no two live processes share a pid).
    # New incarnation, maybe a new pane (a resume after the old tab closed): drop
    # the sid-keyed surface cache so the first prompt re-captures where you are —
    # same reasoning as claude-hook.sh. Every source; startup has none.
    rm -f "${LOG:h}/surface-$sid"
    src=$(jq -r '.source // empty' <<<"$input")
    case $src in clear|resume|compact) ;; *) exit 0 ;; esac
    cpid=$(codex_pid)
    comm=$(ps -o comm= -p "$cpid" 2>/dev/null)
    case "${comm:t}" in codex*) print -r -- "$cpid" > "${LOG:h}/cpid-$sid" ;; esac
    jq -cn --arg id "$id" --argjson pid "$cpid" --argjson ts "$now" \
      '{v:1,ev:"reset",id:$id,pid:$pid,ts:$ts}' >> "$LOG"
    ;;
  UserPromptSubmit)
    rm -f "${LOG:h}/waiting-$sid"
    prompt=$(jq -r '.prompt // ""' <<<"$input")
    _joystick_redact "$prompt"; prompt=$REPLY
    # Which Ghostty surface is this session in? The user just typed a prompt, so
    # the focused surface is ours. Cached per session id (same cache scheme as
    # claude-hook — codex session ids are UUIDs, a disjoint namespace).
    surface="" scache="${LOG:h}/surface-$sid"
    if [[ -s $scache ]]; then
      surface=$(<"$scache")
    else
      surface=$(osascript -e 'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null) || surface=""
      [[ -n $surface ]] && print -r -- "$surface" > "$scache"
    fi
    # The session's long-lived codex pid is stable across all its turns, so
    # resolve it once (the ps walk) and cache by sid. Only cache a confidently
    # resolved codex pid — never the $PPID fallback, which can be a transient
    # that would make the row look dead on the next turn.
    pcache="${LOG:h}/cpid-$sid" cpid=""
    [[ -s $pcache ]] && cpid=$(<"$pcache")
    if [[ -z $cpid || $cpid == *[!0-9]* ]]; then
      cpid=$(codex_pid)
      comm=$(ps -o comm= -p "$cpid" 2>/dev/null)
      case "${comm:t}" in codex*) print -r -- "$cpid" > "$pcache" ;; esac
    fi
    # The 120-char prompt cap keeps the line < PIPE_BUF (4096) so concurrent
    # appends from other shells/hooks stay atomic — don't raise it materially.
    jq -cn --arg id "$id" --arg cmd "» ${prompt[1,120]}" --arg cwd "$cwd" \
      --arg surface "$surface" --argjson pid "$cpid" --argjson ts "$now" \
      '{v:1,kind:"codex",ev:"start",id:$id,cmd:$cmd,cwd:$cwd,pid:$pid,tty:"",surface:$surface,ts:$ts}' >> "$LOG"
    emit_meta
    ;;
  PostToolUse)
    # Surface the tool just used as the live activity subtitle, and clear any
    # waiting state. Fires after every tool call, so keep it cheap. Codex tool
    # names and inputs mirror Claude's shape (tool_name + tool_input JSON).
    rm -f "${LOG:h}/waiting-$sid"
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    [[ -n $tool ]] || exit 0
    case $tool in
      Bash|shell)
                  d=$(jq -r 'if (.tool_input.command | type) == "array" then (.tool_input.command | join(" ")) else (.tool_input.command // "") end' <<<"$input")
                  d=${d//$'\n'/ }; act="Bash: $d" ;;
      Edit|Write|Read|MultiEdit|apply_patch|ApplyPatch)
                  d=$(jq -r '.tool_input.file_path // .tool_input.path // ""' <<<"$input"); act="$tool ${d:t}" ;;
      Grep|Glob)  d=$(jq -r '.tool_input.pattern // .tool_input.query // ""' <<<"$input"); act="$tool: $d" ;;
      *)          act="$tool" ;;
    esac
    _joystick_redact "$act"; act=${REPLY[1,120]}   # redact secrets; keep line < PIPE_BUF
    jq -cn --arg id "$id" --arg act "$act" --argjson ts "$now" \
      '{v:1,ev:"active",id:$id,act:$act,ts:$ts}' >> "$LOG"
    ;;
  PermissionRequest)
    # Codex is blocked on you (an approval prompt). Mark the open turn waiting;
    # the next PostToolUse means we're unblocked again. Prefer the tool's own
    # description, else name the tool it wants to run.
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    msg=$(jq -r '.tool_input.description // empty' <<<"$input")
    [[ -n $msg ]] || msg="wants to run: ${tool:-a tool}"
    _joystick_redact "$msg"; msg=${REPLY[1,240]}   # a tool invocation can carry secrets
    jq -cn --arg id "$id" --arg msg "$msg" --argjson ts "$now" \
      '{v:1,ev:"waiting",id:$id,msg:$msg,ts:$ts}' >> "$LOG"
    : > "${LOG:h}/waiting-$sid"
    ;;
  Stop)
    # A turn is stopping. Close the open turn with the closing blurb (handed to
    # us as last_assistant_message — no transcript poll needed). Codex has no
    # separate failure event, so a turn ends exit 0; liveness/pid death still
    # reaps a killed session's row.
    rm -f "${LOG:h}/waiting-$sid"
    start_ts=$(tail -n 2000 "$LOG" 2>/dev/null | grep -F "\"id\":\"$id\"" \
      | grep -E '"ev":"(start|end)"' | tail -1)
    [[ $start_ts == *'"ev":"start"'* ]] || exit 0   # no open turn (e.g. Stop after clear)
    start_ts=$(jq -r '.ts // 0' <<<"$start_ts")
    summary=$(jq -r '.last_assistant_message // empty' <<<"$input")
    summary=${summary//[$'\n\t\r']/ }
    [[ -n $summary ]] && { _joystick_redact "$summary"; summary=${REPLY[1,240]}; }
    elapsed=$(( now - start_ts ))
    jq -cn --arg id "$id" --arg msg "$summary" --argjson ts "$now" --argjson dur "$elapsed" \
      '{v:1,ev:"end",id:$id,exit:0,dur:$dur,ts:$ts} + (if $msg != "" then {msg:$msg} else {} end)' >> "$LOG"
    emit_meta
    ;;
esac
exit 0
