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

# Source our shared sanitizer from our OWN directory, so this works whether
# we're installed to $JOYSTICK_HOME (~/.config/joystick) or run from the dev
# repo (~/joystick). ${0:A:h} is this file's dir; fall back if shell options
# hid argzero. (Top-level: no `local`, so tidy up the temp var after.)
_joystick_dir=${0:A:h}
[[ -r $_joystick_dir/joystick-redact.zsh ]] || _joystick_dir=${JOYSTICK_HOME:-$HOME/.config/joystick}
[[ -r $_joystick_dir/joystick-redact.zsh ]] || _joystick_dir=$HOME/joystick
source "$_joystick_dir/joystick-redact.zsh"
unset _joystick_dir

# Opt-outs, set in ~/.zshrc before sourcing this file:
#   JOYSTICK_NOLOG_DIRS=(~/secrets ~/work/client-x)  — never log in these trees
#   JOYSTICK_LOG_MODE=head — log only "cmd subcommand", never arguments

# Rotate the log when it outgrows the cap: keep the most recent $keep lines, but
# NEVER drop the `start` line of an op that's still open (a start with no matching
# end). A blind `tail` deletes a long-running service's start — it's the OLDEST
# line in the file — and the viewer then loses that row permanently (the data is
# gone, not merely outside a read window, so even a full re-read can't recover it).
# Preserving open starts keeps `npx expo start`, `next dev`, ngrok, etc. visible
# across a rotation; a dead-but-unclosed op is harmless — the app's pid-liveness
# prune drops it after folding. JOYSTICK_ROTATE_KEEP overrides the count for the
# test only; production is always 2000. Re-chmod after the mv: the rotated file
# lands with the umask, not 600, and principle #6 wants the plaintext locked down
# now, not only at the next shell startup.
_joystick_rotate_log() {
  local log=$JOYSTICK_LOG keep=${JOYSTICK_ROTATE_KEEP:-2000}
  [[ -f $log ]] || return 0
  awk -v keep="$keep" '
    function val(s, key) {
      if (match(s, "\"" key "\":\"")) { s = substr(s, RSTART + RLENGTH); sub(/".*/, "", s); return s }
      return ""
    }
    { line[NR] = $0
      ev = val($0, "ev"); id = val($0, "id")
      if (ev == "start") open[id] = NR          # last start wins (claude reuses an id across turns)
      else if (ev == "end") delete open[id] }   # ...and its end closes it
    END {
      from = NR - keep + 1; if (from < 1) from = 1
      n = 0
      for (id in open) if (open[id] < from) keep_ln[n++] = open[id]   # open starts in the dropped head
      for (i = 1; i < n; i++) {                                       # insertion-sort into chronological order
        v = keep_ln[i]; j = i - 1
        while (j >= 0 && keep_ln[j] > v) { keep_ln[j+1] = keep_ln[j]; j-- }
        keep_ln[j+1] = v
      }
      for (i = 0; i < n; i++) print line[keep_ln[i]]                  # preserved open starts, oldest first
      for (i = from; i <= NR; i++) print line[i]                      # then the recent tail
    }
  ' "$log" > "$log.tmp" && mv "$log.tmp" "$log" && chmod 600 "$log" 2>/dev/null
}

# Housekeeping once per shell startup: rotate the log past ~5MB and drop
# stale Claude session surface caches.
if [[ -f $JOYSTICK_LOG ]] && (( $(stat -f %z "$JOYSTICK_LOG" 2>/dev/null || echo 0) > 5242880 )); then
  _joystick_rotate_log
fi
command find "${JOYSTICK_LOG:h}" \( -name 'surface-*' -o -name 'waiting-*' -o -name 'cpid-*' \) -mtime +7 -delete 2>/dev/null
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
    ( { osascript -e 'tell application "Ghostty" to get id of focused terminal of selected tab of front window' > "$cache"; } 2>/dev/null ) &!
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
  # brace-group the redirect so a deleted log dir can't spew "no such file"
  # to the prompt: zsh reports a failed >> open on its OWN stderr while setting
  # up the command, so a trailing `2>/dev/null` is too late — only wrapping is.
  { print -r -- "{\"v\":1,\"kind\":\"shell\",\"ev\":\"start\",\"id\":\"$_joystick_id\",\"cmd\":\"$cmd\",\"cwd\":\"$cwd\",\"pid\":$$,\"tty\":\"${TTY:t}\",\"surface\":\"$surface\",\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG"; } 2>/dev/null
}

_joystick_precmd() {
  local code=$?
  [[ -n ${_joystick_id:-} ]] || return 0
  { print -r -- "{\"v\":1,\"ev\":\"end\",\"id\":\"$_joystick_id\",\"exit\":$code,\"dur\":$((EPOCHSECONDS - _joystick_start)),\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG"; } 2>/dev/null
  unset _joystick_id _joystick_start
}

# If the shell exits while a command is still running (tab closed, SIGHUP),
# emit an end event with exit -1 so the viewer doesn't show it forever.
_joystick_exit() {
  [[ -n ${_joystick_id:-} ]] || return 0
  { print -r -- "{\"v\":1,\"ev\":\"end\",\"id\":\"$_joystick_id\",\"exit\":-1,\"dur\":$((EPOCHSECONDS - _joystick_start)),\"ts\":$EPOCHSECONDS}" >> "$JOYSTICK_LOG"; } 2>/dev/null
}

add-zsh-hook preexec _joystick_preexec
add-zsh-hook precmd  _joystick_precmd
add-zsh-hook zshexit _joystick_exit
