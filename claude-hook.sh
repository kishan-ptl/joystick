#!/bin/zsh
# claude-hook.sh — Claude Code hook handler for joystick. Wired in
# ~/.claude/settings.json to: SessionStart, UserPromptSubmit, PreToolUse, Stop,
# StopFailure, Notification, PostToolUse, PostToolUseFailure.
#
# SessionStart          -> "reset" on /clear|/resume|/compact (retire prior row now)
# UserPromptSubmit      -> "start" (turn shows as running)
# PreToolUse            -> "active" at the START of a Task/Agent (subagents only)
# Stop / StopFailure    -> "end" (exit 0 / 1) + done / failed desktop notification
# Notification          -> "waiting" (blocked on you) + notification
# PostToolUse(Failure)  -> "active" carrying live activity (or "⚠ tool failed")
set -u

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/joystick/events.jsonl"
mkdir -p "${LOG:h}"
MIN_NOTIFY_SECS=30
# Source our shared sanitizer from our OWN directory (this hook is executed by
# Claude from $JOYSTICK_HOME when installed, or ~/joystick in the dev repo).
_jdir=${0:A:h}
[[ -r $_jdir/joystick-redact.zsh ]] || _jdir=${JOYSTICK_HOME:-$HOME/.config/joystick}
[[ -r $_jdir/joystick-redact.zsh ]] || _jdir=$HOME/joystick
source "$_jdir/joystick-redact.zsh"

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

# Resolve this turn's transcript file: the hook-provided path, else the
# conventional ~/.claude/projects/<cwd>/<sid>.jsonl location. Echoes the path,
# or nothing if neither exists.
claude_transcript() {
  local tpath
  tpath=$(jq -r '.transcript_path // empty' <<<"$input")
  [[ -f $tpath ]] || tpath="$HOME/.claude/projects/${cwd//\//-}/$sid.jsonl"
  [[ -f $tpath ]] && print -r -- "$tpath"
}

# Drop one tracked background shell (emit its `subdone`), guarded by a per-shell
# marker so each shell drops exactly ONCE no matter how many paths see its
# completion. A bg shell's completion <task-notification> can reach us two ways —
# as a fresh UserPromptSubmit (session was idle) OR only in the transcript (it
# finished mid-turn, folded into the running turn with no UserPromptSubmit) — so
# both the prompt handler and the Stop-time drain call this; the marker makes the
# second a no-op. $1 = the shell's tool_use_id.
drop_shell() {
  local mk="${LOG:h}/jshell-$sid-$1"
  [[ -n $1 && -e $mk ]] || return 0
  # Write the clear FIRST, drop the marker SECOND. If the hook is interrupted
  # between them (Claude Code kills a hook that overruns its timeout — and the
  # Stop-time drain loops over every tool_use_id), the marker survives and the
  # next drain retries. The old rm-first order stranded the line forever on a
  # crash (marker gone, no subdone); a rare duplicate subdone is harmless (the
  # fold's removeAll is idempotent). $now is always set (top of script).
  jq -cn --arg id "$id" --arg sh "$1" --argjson ts "$now" \
    '{v:1,ev:"active",id:$id,shell:$sh,subdone:true,ts:$ts}' >> "$LOG"
  rm -f "$mk"
}

# Drop one tracked subagent (emit its `subdone`) — the Task analogue of drop_shell,
# keyed by `sub` (the Task tool_use_id) instead of `shell`, and marker-guarded the
# same way for exactly-once across the two completion paths. A subagent is now
# session-scoped too: when its turn is marked done while it runs on (the TUI's
# "Waiting for N background agents to finish"), this is what eventually clears the
# row's "⟳ bg" chip. $1 = the Task's tool_use_id.
drop_agent() {
  local mk="${LOG:h}/jagent-$sid-$1"
  [[ -n $1 && -e $mk ]] || return 0
  # Clear-then-unmark, same crash-safe order as drop_shell (see there).
  jq -cn --arg id "$id" --arg sub "$1" --argjson ts "$now" \
    '{v:1,ev:"active",id:$id,sub:$sub,subdone:true,ts:$ts}' >> "$LOG"
  rm -f "$mk"
}

# Drain background work (shells AND subagents) that FINISHED — scan the transcript
# for the tool_use_ids carried by completion <task-notification>s and drop each
# (markers guard against double-drop). This catches work that finished mid-turn,
# whose notification never arrived as its own UserPromptSubmit. $1 = transcript path.
drain_finished_bg() {
  [[ -n $1 && -f $1 ]] || return 0
  # Cheap gate: do nothing unless this session actually has an open shell or agent.
  # The marker glob is a stat, not a transcript read — so the overwhelmingly common
  # case (a turn with no background work) pays nothing, and the scan below only runs
  # while shells/agents are genuinely in flight.
  setopt local_options nullglob
  local markers=("${LOG:h}/jshell-$sid-"* "${LOG:h}/jagent-$sid-"*)
  (( ${#markers} )) || return 0
  tail -n 1200 "$1" 2>/dev/null | grep -F '<task-notification>' \
    | grep -oE 'tool-use-id>toolu_[A-Za-z0-9]+' | sed 's/.*>//' | sort -u \
    | while read -r tuid; do drop_shell "$tuid"; drop_agent "$tuid"; done
}

# Close this session's open turn (if any) with the given exit code. Decides
# open/closed from start/end lines only — a turn that went start→waiting→active
# (you approved a permission prompt) has `active` last; including it would
# wrongly skip the end + notification, exactly when you stepped away. Stop also
# fires on /clear/resume/compact, which have no open turn.
close_turn() {  # $1 = exit code  $2 = notify title  $3 = notify verb
  rm -f "${LOG:h}/waiting-$sid"
  local last start_ts elapsed tpath summary=""
  last=$(tail -n 2000 "$LOG" 2>/dev/null | grep -F "\"id\":\"$id\"" | grep -E '"ev":"(start|end)"' | tail -1)
  [[ $last == *'"ev":"start"'* ]] || return 0
  start_ts=$(jq -r '.ts // 0' <<<"$last")
  # Claude's closing blurb = the text of the turn's final assistant message,
  # the one whose stop_reason is "end_turn". (An intermediate "let me…" line
  # before a tool call is stop_reason "tool_use" — selecting on end_turn skips
  # it, so we get the closing reply, not a mid-turn aside.) That final message
  # often flushes to the transcript a few hundred ms AFTER Stop fires, so a
  # single read races the writer and grabs the PREVIOUS turn's blurb. Poll for
  # an end_turn message stamped at/after THIS turn's start: the timestamp gate
  # guarantees we never show a stale prior-turn reply, and the poll waits out
  # the flush. On StopFailure (interrupt/failure — $1≠0) there's no closing
  # reply coming, so skip the poll entirely and stay instant on the action you
  # most want snappy; on a normal Stop, give up blank (omit msg) after ~1.5s if
  # no end_turn shows (a turn that ended on a tool call). Then flatten to one
  # line + redact + cap like every free-text field (< PIPE_BUF, no secrets).
  tpath=$(claude_transcript)
  # Drain background work (shells + subagents) that finished during this turn,
  # including mid-turn completions whose notification never fired its own
  # UserPromptSubmit drop.
  drain_finished_bg "$tpath"
  if [[ $1 == 0 && -n $tpath ]]; then
    local tries=0
    while (( tries < 15 )); do
      summary=$(tail -n 400 "$tpath" | jq -rc --argjson since "$start_ts" \
        'select(.type=="assistant" and .message.stop_reason=="end_turn")
         | ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | (fromdateiso8601? // 0)) as $ets
         | select($ets >= $since)
         | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -1)
      [[ -n $summary ]] && break
      sleep 0.1
      (( tries++ ))
    done
    summary=${summary//[$'\n\t\r']/ }
    _joystick_redact "$summary"; summary=${REPLY[1,240]}
  fi
  # Re-stamp after the blurb poll (above) so ts/dur reflect close time, not the
  # up-to-1.5s we may have spent waiting for the final message to flush.
  now=$(date +%s); elapsed=$(( now - start_ts ))
  jq -cn --arg id "$id" --arg msg "$summary" --argjson ts "$now" --argjson dur "$elapsed" --argjson ex "$1" \
    '{v:1,ev:"end",id:$id,exit:$ex,dur:$dur,ts:$ts} + (if $msg != "" then {msg:$msg} else {} end)' >> "$LOG"
  if (( elapsed >= MIN_NOTIFY_SECS )) && ! ghostty_frontmost; then
    notify "$2" "$3 after $((elapsed / 60))m$((elapsed % 60))s in ${cwd:t}"
  fi
  emit_meta "$tpath"
}

# The git worktree this session lives in, if any. A LINKED worktree keeps its
# git-dir under .../worktrees/<name>; the main checkout does not. We surface the
# worktree's directory leaf so several Claude sessions on the same repo (a
# common parallel-work setup here) are told apart on the board. Empty for the
# main checkout or a non-git dir — one cheap `git rev-parse`, fully fail-silent.
worktree_name() {  # $1 = dir
  local gd top
  gd=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 0
  [[ $gd == */worktrees/* ]] || return 0
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  print -r -- "${top:t}"
}

# Emit session metadata from the Claude transcript: topic title, model,
# permission mode, and context-window fill (the latest request's token count =
# input + cache_read + cache_creation). Runs on turn close (async).
# $1 = the transcript path close_turn already resolved (empty if none).
emit_meta() {  # $1 = transcript path (may be empty)
  local tpath=$1 title mode model ctx name color wt
  [[ -n $tpath ]] || return 0
  title=$(grep -F '"type":"ai-title"' "$tpath" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
  mode=$(grep -F '"type":"permission-mode"' "$tpath" 2>/dev/null | tail -1 | jq -r '.permissionMode // empty' 2>/dev/null)
  model=$(tail -100 "$tpath" | jq -r 'select(.message.model != null) | .message.model' 2>/dev/null | tail -1)
  ctx=$(tail -100 "$tpath" | jq -r 'select(.message.usage != null) | .message.usage | (.input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens)' 2>/dev/null | tail -1)
  # A deliberate rename (custom-title) + assigned agent color, if you set them.
  # The viewer shows these as a badge atop the row — distinct from the auto
  # ai-title above (which is the row's label). The auto title is NOT the badge.
  name=$(grep -F '"type":"custom-title"' "$tpath" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
  color=$(grep -F '"type":"agent-color"' "$tpath" 2>/dev/null | tail -1 | jq -r '.agentColor // empty' 2>/dev/null)
  [[ -n $title ]] && { _joystick_redact "$title"; title=${REPLY[1,80]}; }
  [[ -n $name  ]] && { _joystick_redact "$name";  name=${REPLY[1,40]}; }
  [[ -n $color ]] && color=${color[1,16]}   # a palette name; cap, no redaction needed
  # Worktree leaf: a path component (already present unredacted in `cwd`), so
  # cap only — no redaction needed; the cap keeps the line < PIPE_BUF.
  wt=$(worktree_name "$cwd"); wt=${wt[1,40]}
  jq -cn --arg id "$id" --arg title "${title:-}" --arg model "${model:-}" --arg mode "${mode:-}" \
    --arg name "${name:-}" --arg color "${color:-}" --arg wt "${wt:-}" --argjson ctx "${ctx:-0}" --argjson ts "$now" \
    '{v:1,ev:"meta",id:$id,title:$title,model:$model,mode:$mode,name:$name,color:$color,wt:$wt,ctx:$ctx,ts:$ts}' >> "$LOG"
}

case $event in
  SessionStart)
    # /clear, /resume and /compact each rotate to a NEW session_id on the SAME
    # claude process and terminal, with no prompt submitted yet. Without a signal
    # here the cleared row keeps showing the OLD conversation until your first
    # prompt's `start` retires it. Emit a `reset` now so the viewer retires the
    # prior session's row immediately. (startup is a fresh process — nothing to
    # retire — so skip it.) The pid carries the match: the claude process is
    # unchanged across the rotation, and no two live processes share a pid. The
    # viewer's `case "reset"` runs the same supersede rule as a new `start`.
    src=$(jq -r '.source // empty' <<<"$input")
    case $src in clear|resume|compact) ;; *) exit 0 ;; esac
    cpid=$(claude_pid)
    # Cache the resolved pid for the new sid so the first prompt skips the ps
    # walk — but only a confidently-resolved claude/node pid, never the $PPID
    # fallback (caching that would make the row look dead next turn).
    comm=$(ps -o comm= -p "$cpid" 2>/dev/null)
    case "${comm:t}" in claude*|node*) print -r -- "$cpid" > "${LOG:h}/cpid-$sid" ;; esac
    jq -cn --arg id "$id" --argjson pid "$cpid" --argjson ts "$now" \
      '{v:1,ev:"reset",id:$id,pid:$pid,ts:$ts}' >> "$LOG"
    ;;
  UserPromptSubmit)
    rm -f "${LOG:h}/waiting-$sid"
    prompt=$(jq -r '.prompt // ""' <<<"$input")
    # A background subagent (Task) finishing wakes the session with an injected
    # <task-notification> — not something you typed. Keep it as a turn (the
    # session IS working again) but label it from the notification's <summary>,
    # never the raw XML (which would dump the whole subagent result into the row).
    if [[ $prompt == *'<task-notification>'* ]]; then
      # A background shell OR subagent finished and woke the session. Drop the live
      # line for every tool_use_id the notification(s) carry — drop_shell and
      # drop_agent are each marker-guarded, so exactly the one that matches fires and
      # the other is a no-op. This is the fast path (idle completion → its own turn);
      # mid-turn completions are caught by the drain (Stop-time, and prompt-time just
      # below). Emitted BEFORE the turn's start so the finished line clears first.
      print -r -- "$prompt" | grep -oE 'tool-use-id>toolu_[A-Za-z0-9]+' | sed 's/.*>//' \
        | while read -r tuid; do drop_shell "$tuid"; drop_agent "$tuid"; done
      sm=${prompt#*<summary>}; sm=${sm%%</summary>*}
      [[ $sm == "$prompt" || -z $sm ]] && sm="background agent finished"
      prompt=$sm
    fi
    # Reconcile background work that finished during the PRIOR turn. The Stop-time
    # drain usually catches a mid-turn completion and the fast path above catches one
    # delivered as its own prompt — but re-draining here, at every prompt, is the
    # cheap correct backstop that keeps a missed completion from stranding the line
    # until pid death. It scans the transcript and clears ONLY children whose
    # completion <task-notification> has actually landed, so a still-RUNNING agent
    # keeps its line (the outlive-the-turn feature stays intact). When the session
    # has no bg work in flight the marker glob short-circuits before any transcript
    # scan, so a normal prompt's only added cost is resolving the path.
    drain_finished_bg "$(claude_transcript)"
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
    jq -cn --arg id "$id" --arg cmd "» ${prompt[1,120]}" --arg cwd "$cwd" \
      --arg surface "$surface" --argjson pid "$cpid" --argjson ts "$now" \
      '{v:1,kind:"claude",ev:"start",id:$id,cmd:$cmd,cwd:$cwd,pid:$pid,tty:"",surface:$surface,ts:$ts}' >> "$LOG"
    # Refresh session meta at turn START too (backgrounded, so no turn-start
    # latency). A /rename fires no hook, so without this the new name only lands
    # on the next turn CLOSE; this makes it show on your next prompt.
    tp=$(jq -r '.transcript_path // empty' <<<"$input")
    [[ -f $tp ]] || tp="$HOME/.claude/projects/${cwd//\//-}/$sid.jsonl"
    emit_meta "$tp" &!
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
    _joystick_redact "$msg"; msg=${REPLY[1,240]}   # a tool invocation can carry secrets
    jq -cn --arg id "$id" --arg msg "$msg" --argjson ts "$now" \
      '{v:1,ev:"waiting",id:$id,msg:$msg,ts:$ts}' >> "$LOG"
    : > "${LOG:h}/waiting-$sid"
    if ! ghostty_frontmost; then
      notify "Claude Code — waiting" "$msg (${cwd:t})"
    fi
    ;;
  PreToolUse)
    # A subagent (Task) runs long and in the BACKGROUND: its tool call returns at
    # dispatch, so PostToolUse can't mark it finished (it fires immediately too).
    # Emit a live subagent line at the START of each Task/Agent, keyed by the
    # tool_use_id, so several CONCURRENT subagents each show their own line under the
    # session row, and drop a per-agent marker so its completion drops it exactly
    # once. The line is SESSION-scoped (like a bg shell): it survives the turn's
    # Stop, so a subagent that outlives its turn keeps the row's "⟳ bg" chip lit
    # until it reports back — via a <task-notification> (its own UserPromptSubmit, or
    # the Stop-time drain for completions that landed mid-turn). Scoped to Task/Agent
    # on purpose: other tools complete fast enough that their PostToolUse is timely.
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    case $tool in
      Task|Agent) d=$(jq -r '.tool_input.description // .tool_input.subagent_type // ""' <<<"$input") ;;
      *)          exit 0 ;;
    esac
    sub=$(jq -r '.tool_use_id // empty' <<<"$input")   # ties this start to its finish; "" → old latest-wins
    _joystick_redact "Task: $d"; act=${REPLY[1,120]}   # redact secrets; keep line < PIPE_BUF
    jq -cn --arg id "$id" --arg act "$act" --arg sub "$sub" --argjson ts "$now" \
      '{v:1,ev:"active",id:$id,act:$act,sub:$sub,ts:$ts}' >> "$LOG"
    [[ -n $sub ]] && : > "${LOG:h}/jagent-$sid-$sub"   # mark it open so the drain/notification drops it exactly once
    ;;
  PostToolUse)
    # Surface the tool just used as the live activity subtitle, and clear any
    # waiting state. Fires on every tool use (async hook), so keep it cheap.
    rm -f "${LOG:h}/waiting-$sid"
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    # A Task/Agent's PostToolUse fires at DISPATCH, not completion — subagents run
    # in the background and report finishing later via a <task-notification>
    # (handled in UserPromptSubmit). So nothing to do here: the PreToolUse START
    # line already shows the subagent, and it clears when this turn ends (the
    # viewer hides subagent lines once the op stops running). Emitting `subdone`
    # here was the bug that made subagent lines vanish the instant they appeared.
    [[ $tool == Task || $tool == Agent ]] && exit 0
    case $tool in
      Bash)
        d=$(jq -r '.tool_input.command // ""' <<<"$input")
        # A run_in_background Bash is a SERVICE-like op that outlives this turn: it
        # keeps running (often for minutes, across turns) until it exits and reports
        # via a <task-notification>. Track it by tool_use_id as a live background
        # shell so the session row can show it; the notification (UserPromptSubmit)
        # drops it. Plain Bash falls through to the latest-wins activity line below.
        if [[ $(jq -r '.tool_input.run_in_background // false' <<<"$input") == true ]]; then
          sh=$(jq -r '.tool_use_id // empty' <<<"$input")
          _joystick_redact "$d"; act=${REPLY[1,120]}   # the bare command; keep line < PIPE_BUF
          [[ -n $sh ]] && {
            jq -cn --arg id "$id" --arg act "$act" --arg sh "$sh" --argjson ts "$now" \
              '{v:1,ev:"active",id:$id,act:$act,shell:$sh,ts:$ts}' >> "$LOG"
            : > "${LOG:h}/jshell-$sid-$sh"   # mark it open so the drain drops it exactly once
          }
          exit 0
        fi
        act="Bash: $d" ;;
      Edit|Write|Read|MultiEdit|NotebookEdit)
                  d=$(jq -r '.tool_input.file_path // ""' <<<"$input"); act="$tool ${d:t}" ;;
      Grep|Glob)  d=$(jq -r '.tool_input.pattern // ""' <<<"$input"); act="$tool: $d" ;;
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
    # A Task that fails to LAUNCH (a dispatch-level error — the subagent never
    # ran) drops its live line via drop_agent, keyed by the same tool_use_id its
    # start used (the PreToolUse marker still exists), so it doesn't hang under the
    # row and its marker is cleaned. (A subagent that runs and then fails reports
    # via a <task-notification>, not here.)
    if [[ $tool == Task || $tool == Agent ]]; then
      drop_agent "$(jq -r '.tool_use_id // empty' <<<"$input")"
    fi
    jq -cn --arg id "$id" --arg act "⚠ $tool failed" --argjson ts "$now" \
      '{v:1,ev:"active",id:$id,act:$act,ts:$ts}' >> "$LOG"
    ;;
esac
exit 0
