#!/bin/zsh
# claude-hook.sh — Claude Code hook handler for joystick. Wired in
# ~/.claude/settings.json to: UserPromptSubmit, Stop, StopFailure, Notification,
# PostToolUse, PostToolUseFailure.
#
# UserPromptSubmit      -> "start" (turn shows as running)
# Stop / StopFailure    -> "end" (exit 0 / 1) + done / failed desktop notification
# Notification          -> "waiting" (blocked on you) + notification
# PostToolUse(Failure)  -> "active" carrying live activity (or "⚠ tool failed")
set -u

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/joystick/events.jsonl"
mkdir -p "${LOG:h}"
MIN_NOTIFY_SECS=30
source "$HOME/joystick/joystick-redact.zsh"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
now=$(date +%s)
id="claude-$sid"

# Walk up the process tree to find the long-lived claude process, so the
# viewer's pid-liveness check tracks the session, not this hook.
claude_pid() {
  local p=$PPID comm i
  for i in 1 2 3 4 5; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "${comm:t}" in
      claude*|node*) print -r -- "$p"; return ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [[ -n $p && $p != 0 && $p != 1 ]] || break
  done
  print -r -- "$PPID"
}

ghostty_frontmost() {
  lsappinfo info -only name "$(lsappinfo front 2>/dev/null)" 2>/dev/null | grep -qi ghostty
}

notify() {  # $1 = title, $2 = message
  [[ -n ${JOYSTICK_NO_NOTIFY:-} ]] && return 0   # silence (used by tests)
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
    -e 'end run' "$1" "$2" 2>/dev/null
}

# Close this session's open turn (if any) with the given exit code. Decides
# open/closed from start/end lines only — a turn that went start→waiting→active
# (you approved a permission prompt) has `active` last; including it would
# wrongly skip the end + notification, exactly when you stepped away. Stop also
# fires on /clear/resume/compact, which have no open turn.
close_turn() {  # $1 = exit code  $2 = notify title  $3 = notify verb
  rm -f "${LOG:h}/waiting-$sid"
  local last start_ts elapsed
  last=$(tail -n 2000 "$LOG" 2>/dev/null | grep -F "\"id\":\"$id\"" | grep -E '"ev":"(start|end)"' | tail -1)
  [[ $last == *'"ev":"start"'* ]] || return 0
  start_ts=$(jq -r '.ts // 0' <<<"$last")
  elapsed=$(( now - start_ts ))
  jq -cn --arg id "$id" --argjson ts "$now" --argjson dur "$elapsed" --argjson ex "$1" \
    '{v:1,ev:"end",id:$id,exit:$ex,dur:$dur,ts:$ts}' >> "$LOG"
  if (( elapsed >= MIN_NOTIFY_SECS )) && ! ghostty_frontmost; then
    notify "$2" "$3 after $((elapsed / 60))m$((elapsed % 60))s in ${cwd:t}"
  fi
}

case $event in
  UserPromptSubmit)
    rm -f "${LOG:h}/waiting-$sid"
    prompt=$(jq -r '.prompt // ""' <<<"$input")
    _joystick_redact "$prompt"; prompt=$REPLY
    # Which Ghostty surface is this session in? The user just typed a prompt,
    # so the focused surface is ours. Cached per session id.
    surface="" scache="${LOG:h}/surface-$sid"
    if [[ -s $scache ]]; then
      surface=$(<"$scache")
    else
      surface=$(osascript -e 'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null) || surface=""
      [[ -n $surface ]] && print -r -- "$surface" > "$scache"
    fi
    # The session's long-lived claude pid is stable across all its turns, so
    # resolve it once (the ps walk) and cache by sid. Only cache a confidently
    # resolved claude/node pid — never the $PPID fallback, which can be a
    # transient that would make the row look dead on the next turn.
    pcache="${LOG:h}/cpid-$sid" cpid=""
    [[ -s $pcache ]] && cpid=$(<"$pcache")
    if [[ -z $cpid || $cpid == *[!0-9]* ]]; then
      cpid=$(claude_pid)
      comm=$(ps -o comm= -p "$cpid" 2>/dev/null)
      case "${comm:t}" in claude*|node*) print -r -- "$cpid" > "$pcache" ;; esac
    fi
    # The 120-char prompt cap keeps the line < PIPE_BUF (4096) so concurrent
    # appends from other shells/hooks stay atomic — don't raise it materially.
    jq -cn --arg id "$id" --arg cmd "🤖 ${prompt[1,120]}" --arg cwd "$cwd" \
      --arg surface "$surface" --argjson pid "$cpid" --argjson ts "$now" \
      '{v:1,kind:"claude",ev:"start",id:$id,cmd:$cmd,cwd:$cwd,pid:$pid,tty:"",surface:$surface,ts:$ts}' >> "$LOG"
    ;;
  Stop)         close_turn 0 "Claude Code — done"   "Finished" ;;
  StopFailure)  close_turn 1 "Claude Code — failed" "Failed"   ;;
  Notification)
    # Claude is blocked on the user (permission prompt or idle). Mark the open
    # turn as waiting; the next PostToolUse means we're unblocked again.
    msg=$(jq -r '.message // "Claude needs your attention"' <<<"$input")
    # Claude Code's raw notification copy is permission-centric even for plain
    # questions; rewrite to short, accurate phrasing (row context already
    # shows it's a Claude session).
    case $msg in
      *"permission to use "*) msg="wants to run: ${msg##*permission to use }" ;;
      *"needs your permission"*) msg="wants your approval" ;;
      *"waiting for your input"*) msg="waiting on your reply" ;;
      *) msg=${msg#Claude } ;;
    esac
    jq -cn --arg id "$id" --arg msg "$msg" --argjson ts "$now" \
      '{v:1,ev:"waiting",id:$id,msg:$msg,ts:$ts}' >> "$LOG"
    : > "${LOG:h}/waiting-$sid"
    if ! ghostty_frontmost; then
      notify "Claude Code — waiting" "$msg (${cwd:t})"
    fi
    ;;
  PostToolUse)
    # Surface the tool just used as the live activity subtitle, and clear any
    # waiting state. Fires on every tool use (async hook), so keep it cheap.
    rm -f "${LOG:h}/waiting-$sid"
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    case $tool in
      Bash)       d=$(jq -r '.tool_input.command // ""' <<<"$input"); act="Bash: $d" ;;
      Edit|Write|Read|MultiEdit|NotebookEdit)
                  d=$(jq -r '.tool_input.file_path // ""' <<<"$input"); act="$tool ${d:t}" ;;
      Grep|Glob)  d=$(jq -r '.tool_input.pattern // ""' <<<"$input"); act="$tool: $d" ;;
      Task|Agent) d=$(jq -r '.tool_input.description // .tool_input.subagent_type // ""' <<<"$input"); act="Task: $d" ;;
      WebFetch)   d=$(jq -r '.tool_input.url // ""' <<<"$input"); act="WebFetch $d" ;;
      WebSearch)  d=$(jq -r '.tool_input.query // ""' <<<"$input"); act="Search: $d" ;;
      "")         act="" ;;
      *)          act="$tool" ;;
    esac
    if [[ -n $act ]]; then
      _joystick_redact "$act"; act=${REPLY[1,120]}   # redact secrets; keep line < PIPE_BUF
      jq -cn --arg id "$id" --arg act "$act" --argjson ts "$now" \
        '{v:1,ev:"active",id:$id,act:$act,ts:$ts}' >> "$LOG"
    fi
    ;;
  PostToolUseFailure)
    # A tool errored — surface it as the live activity so the row shows trouble.
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    [[ -n $tool ]] || exit 0
    jq -cn --arg id "$id" --arg act "⚠ $tool failed" --argjson ts "$now" \
      '{v:1,ev:"active",id:$id,act:$act,ts:$ts}' >> "$LOG"
    ;;
esac
exit 0
