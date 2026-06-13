# joystick — logs command start/end events from interactive zsh sessions.
# Sourced from ~/.zshrc. Joystick.app reads these events to show
# running/finished operations across terminal tabs.
#
# Events file: ~/.local/state/joystick/events.jsonl (one JSON object per line)

zmodload zsh/datetime 2>/dev/null
autoload -Uz add-zsh-hook

typeset -g JOYSTICK_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/joystick/events.jsonl"
mkdir -p "${JOYSTICK_LOG:h}"
[[ -e $JOYSTICK_LOG ]] || : >> "$JOYSTICK_LOG"
chmod 600 "$JOYSTICK_LOG" 2>/dev/null

source "$HOME/joystick/joystick-redact.zsh"

# Opt-outs, set in ~/.zshrc before sourcing this file:
#   JOYSTICK_NOLOG_DIRS=(~/secrets ~/work/client-x)  — never log in these trees
#   JOYSTICK_LOG_MODE=head — log only "cmd subcommand", never arguments

# Housekeeping once per shell startup: rotate the log past ~5MB and drop
# stale Claude session surface caches.
if [[ -f $JOYSTICK_LOG ]] && (( $(stat -f %z "$JOYSTICK_LOG" 2>/dev/null || echo 0) > 5242880 )); then
  tail -n 2000 "$JOYSTICK_LOG" > "$JOYSTICK_LOG.tmp" && mv "$JOYSTICK_LOG.tmp" "$JOYSTICK_LOG"
fi
command find "${JOYSTICK_LOG:h}" \( -name 'surface-*' -o -name 'waiting-*' \) -mtime +7 -delete 2>/dev/null
# Clear any stale surface cache for this PID (guards against PID reuse).
command rm -f "${JOYSTICK_LOG:h}/surface-shell-$$" 2>/dev/null

# _joystick_esc (JSON escaping) is provided by joystick-redact.zsh, sourced above.

# Identify which Ghostty surface this shell lives in, so viewers can focus the
# exact tab/split. The AppleScript round-trip is ~50-150ms, so it NEVER runs on
# the foreground path: fire it in the BACKGROUND and let the result land in a
# per-shell cache file. The first command in a tab logs with no surface (focus
# falls back to cwd); the next command reads the cache. A shell never moves
# surfaces, so the cached value stays correct.
_joystick_get_surface() {
  [[ -n ${_joystick_surface:-} ]] && return 0
  local cache="${JOYSTICK_LOG:h}/surface-shell-$$"
  if [[ -s $cache ]]; then
    typeset -g _joystick_surface=$(<"$cache")
    return 0
  fi
  # Not resolved yet — kick the lookup off the foreground path, once per shell.
  if [[ ${TERM_PROGRAM:-} == ghostty && -z ${_joystick_surface_pending:-} ]]; then
    typeset -g _joystick_surface_pending=1
    ( osascript -e 'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null > "$cache" ) &!
  fi
}

_joystick_preexec() {
  local d
  for d in ${JOYSTICK_NOLOG_DIRS:-}; do
    [[ $PWD == ${~d} || $PWD == ${~d}/* ]] && return 0
  done
  _joystick_get_surface
  local surface=${_joystick_surface:-}
  typeset -g _joystick_id="$$-$EPOCHSECONDS-$RANDOM"
  typeset -g _joystick_start=$EPOCHSECONDS
  local cmd cwd raw=$1
  if [[ ${JOYSTICK_LOG_MODE:-} == head ]]; then
    local -a w=(${(z)raw})
    raw=$w[1]
    [[ -n ${w[2]:-} && $w[2] != -* ]] && raw="$w[1] $w[2]"
  fi
  _joystick_redact "$raw"; raw=$REPLY      # redact before truncating, so a
  # cut token can't slip through. The 300-char cap is also LOAD-BEARING for
  # atomicity: concurrent ">>" appends from many shells/hooks only stay intact
  # while each line is < ~4096 bytes (PIPE_BUF). Don't raise it past ~3KB.
  _joystick_esc "${raw[1,300]}"; cmd=$REPLY
  _joystick_esc "$PWD"; cwd=$REPLY
  print -r -- "{\"v\":1,\"kind\":\"shell\",\"ev\":\"start\",\"id\":\"$_joystick_id\",\"cmd\":\"$cmd\",\"cwd\":\"$cwd\",\"pid\":$$,\"tty\":\"${TTY:t}\",\"surface\":\"$surface\",\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG"
}

_joystick_precmd() {
  local code=$?
  [[ -n ${_joystick_id:-} ]] || return 0
  print -r -- "{\"v\":1,\"ev\":\"end\",\"id\":\"$_joystick_id\",\"exit\":$code,\"dur\":$((EPOCHSECONDS - _joystick_start)),\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG"
  unset _joystick_id _joystick_start
}

# If the shell exits while a command is still running (tab closed, SIGHUP),
# emit an end event with exit -1 so the viewer doesn't show it forever.
_joystick_exit() {
  [[ -n ${_joystick_id:-} ]] || return 0
  print -r -- "{\"v\":1,\"ev\":\"end\",\"id\":\"$_joystick_id\",\"exit\":-1,\"dur\":$((EPOCHSECONDS - _joystick_start)),\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG" 2>/dev/null
}

add-zsh-hook preexec _joystick_preexec
add-zsh-hook precmd  _joystick_precmd
add-zsh-hook zshexit _joystick_exit
