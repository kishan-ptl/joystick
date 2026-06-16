#!/bin/zsh
# Tests _joystick_rotate_log (joystick.zsh): a rotation keeps the last $keep lines
# AND preserves the start line of any still-open op, so a long-running service's
# row survives a 5MB rotation instead of being deleted with the oldest lines.
# Run after changing the rotation block in joystick.zsh.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
# Sourcing the emitter defines _joystick_rotate_log and points JOYSTICK_LOG at our
# temp dir; its own startup rotation sees a 0-byte log and no-ops. (worktree-aware)
source ${0:A:h}/../joystick.zsh
LOG=$JOYSTICK_LOG
# Sourcing also registers the live preexec/precmd hooks. Unhook them, or the test's
# own commands log real start/end events into the crafted log we're about to rotate
# (production never hits this: scripts don't source ~/.zshrc, so the emitter is
# interactive-only). Without this the rotation faithfully preserves those stray
# open starts and the counts go wrong.
add-zsh-hook -d preexec _joystick_preexec
add-zsh-hook -d precmd  _joystick_precmd
add-zsh-hook -d zshexit _joystick_exit

pass=0; fail=0
want()    { if "$@"; then ((pass++)); else ((fail++)); print -r -- "FAIL (wanted ok):  $*"; fi }
wantnot() { if "$@"; then ((fail++)); print -r -- "FAIL (wanted fail): $*"; else ((pass++)); fi }
eq()      { if [[ $1 == $2 ]]; then ((pass++)); else ((fail++)); print -r -- "FAIL: $3 (got '$1', want '$2')"; fi }

# Craft a log whose OLDEST lines are an open service + a closed op, followed by
# enough recent traffic that both fall outside a keep=10 tail window.
: > "$LOG"
print -r -- '{"v":1,"kind":"shell","ev":"start","id":"svc-OPEN","cmd":"npx expo start","ts":1}'  >> "$LOG"
print -r -- '{"v":1,"kind":"shell","ev":"start","id":"old-CLOSED","cmd":"ls","ts":2}'            >> "$LOG"
print -r -- '{"v":1,"ev":"end","id":"old-CLOSED","exit":0,"dur":1,"ts":3}'                       >> "$LOG"
# A claude id reused across turns: turn 1 closes, turn 2 is still open. The LAST
# start (open) must be the one preserved, not mistaken for closed by the early end.
print -r -- '{"v":1,"kind":"claude","ev":"start","id":"claude-x","cmd":"» one","ts":4}'          >> "$LOG"
print -r -- '{"v":1,"ev":"end","id":"claude-x","exit":0,"dur":1,"ts":5}'                         >> "$LOG"
print -r -- '{"v":1,"kind":"claude","ev":"start","id":"claude-x","cmd":"» two","ts":6}'          >> "$LOG"
for i in {1..30}; do   # recent, all closed → these are what the tail keeps
  print -r -- "{\"v\":1,\"kind\":\"shell\",\"ev\":\"start\",\"id\":\"f$i\",\"cmd\":\"echo $i\",\"ts\":$((100 + i))}" >> "$LOG"
  print -r -- "{\"v\":1,\"ev\":\"end\",\"id\":\"f$i\",\"exit\":0,\"dur\":0,\"ts\":$((101 + i))}"                     >> "$LOG"
done

JOYSTICK_ROTATE_KEEP=10 _joystick_rotate_log

# Open ops survive even though they're the oldest lines in the file.
want    grep -q '"id":"svc-OPEN"'  "$LOG"
want    grep -q '"id":"claude-x".*two' "$LOG"   # the still-open 2nd turn
# Closed old history is dropped (outside the tail, not open).
wantnot grep -q '"id":"old-CLOSED"' "$LOG"
wantnot grep -q '» one'             "$LOG"      # the closed 1st claude turn
# Result = keep(10) tail + 2 preserved open starts = 12 lines.
eq "$(wc -l < "$LOG" | tr -d ' ')" 12 "line count is keep + open-starts"
# Preserved starts come BEFORE the tail so the fold stays chronological.
eq "$(head -1 "$LOG" | grep -o 'svc-OPEN')" "svc-OPEN" "open start is first line"
# Rotated file is locked back down to 600 (principle #6), not left at the umask.
eq "$(stat -f '%Lp' "$LOG")" "600" "rotated log is chmod 600"

print -r -- "pass=$pass fail=$fail"
(( fail == 0 ))
