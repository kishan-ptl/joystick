#!/bin/zsh
# claude-hook.sh — Claude Code hook handler for joystick.
# Wired to UserPromptSubmit / Stop / Notification in ~/.claude/settings.json.
#
# UserPromptSubmit -> joystick "start" event (turn shows as running in Joystick)
# Stop             -> joystick "end" event + desktop notification if the turn
#                     ran >= MIN_NOTIFY_SECS and Ghostty isn't frontmost
# Notification     -> desktop notification (Claude waiting on permission/input)
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
    # The 120-char prompt cap keeps the line < PIPE_BUF (4096) so concurrent
    # appends from other shells/hooks stay atomic — don't raise it materially.
    jq -cn --arg id "$id" --arg cmd "🤖 ${prompt[1,120]}" --arg cwd "$cwd" \
      --arg surface "$surface" --argjson pid "$(claude_pid)" --argjson ts "$now" \
      '{v:1,kind:"claude",ev:"start",id:$id,cmd:$cmd,cwd:$cwd,pid:$pid,tty:"",surface:$surface,ts:$ts}' >> "$LOG"
    ;;
  Stop)
    rm -f "${LOG:h}/waiting-$sid"
    # Only act if this session's turn is still open. Decide open/closed from
    # start/end lines ONLY: a turn that went start→waiting→active (you approved
    # a permission prompt) has `active` as its last line — including waiting/
    # active here would wrongly skip the end + done-notification, exactly when
    # you stepped away. Stop also fires on /clear/resume/compact (no open turn).
    last=$(tail -n 2000 "$LOG" 2>/dev/null | grep -F "\"id\":\"$id\"" | grep -E '"ev":"(start|end)"' | tail -1)
    [[ $last == *'"ev":"start"'* ]] || exit 0
    start_ts=$(jq -r '.ts // 0' <<<"$last")
    elapsed=$(( now - start_ts ))
    jq -cn --arg id "$id" --argjson ts "$now" --argjson dur "$elapsed" \
      '{v:1,ev:"end",id:$id,exit:0,dur:$dur,ts:$ts}' >> "$LOG"
    if (( elapsed >= MIN_NOTIFY_SECS )) && ! ghostty_frontmost; then
      notify "Claude Code — done" "Finished after $((elapsed / 60))m$((elapsed % 60))s in ${cwd:t}"
    fi
    ;;
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
    # Cheap guard: only relevant if this session is currently marked waiting.
    marker="${LOG:h}/waiting-$sid"
    [[ -f $marker ]] || exit 0
    rm -f "$marker"
    jq -cn --arg id "$id" --argjson ts "$now" '{v:1,ev:"active",id:$id,ts:$ts}' >> "$LOG"
    ;;
esac
exit 0
