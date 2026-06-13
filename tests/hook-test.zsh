#!/bin/zsh
# joystick claude-hook regression tests — run after editing claude-hook.sh.
# Uses a throwaway $XDG_STATE_HOME so it never touches the real event log.
set -u
H=~/joystick/claude-hook.sh
TMP=$(mktemp -d)
export XDG_STATE_HOME=$TMP
export JOYSTICK_NO_NOTIFY=1            # don't fire real macOS notifications
LOG=$TMP/joystick/events.jsonl
pass=0 fail=0

fire()  { print -r -- "$1" | "$H" >/dev/null 2>&1 }
ends()  { grep "\"id\":\"claude-$1\"" "$LOG" 2>/dev/null | grep -c '"ev":"end"' }
lines() { grep -c "\"id\":\"claude-$1\"" "$LOG" 2>/dev/null; true }
check() { if [[ "$2" == "$3" ]]; then ((pass++)); else ((fail++)); print "FAIL: $1 (got '$2', want '$3')"; fi }

# #1 regression: a turn that hit a permission prompt (start→waiting→active→Stop)
# must still close (emit an end) so the done-notification fires.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp","prompt":"do x"}'
fire '{"hook_event_name":"Notification","session_id":"s1","cwd":"/tmp","message":"Claude needs your permission to use Bash"}'
fire '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash"}'
fire '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp"}'
check "permission turn closes" "$(ends s1)" "1"

# A duplicate Stop must not emit a second end.
fire '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp"}'
check "dup Stop: no double end" "$(ends s1)" "1"

# Stop with no open turn (/clear, resume, compact) emits nothing.
fire '{"hook_event_name":"Stop","session_id":"s2","cwd":"/tmp"}'
check "Stop on no turn: nothing" "$(lines s2)" "0"

# A plain turn (start→Stop) closes.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s3","cwd":"/tmp","prompt":"hi"}'
fire '{"hook_event_name":"Stop","session_id":"s3","cwd":"/tmp"}'
check "plain turn closes" "$(ends s3)" "1"

# PostToolUse surfaces the tool just used as activity (act on the active event).
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s4","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PostToolUse","session_id":"s4","cwd":"/tmp","tool_name":"Edit","tool_input":{"file_path":"/a/b/foo.swift"}}'
check "activity captured" "$(grep '"id":"claude-s4"' "$LOG" | grep '"ev":"active"' | jq -r '.act' | tail -1)" "Edit foo.swift"

# Every emitted event carries the schema version.
check "events are v:1" "$(grep -c '"v":1' "$LOG")" "$(grep -c '"ev":' "$LOG")"

rm -rf "$TMP"
print "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
