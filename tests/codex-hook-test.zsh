#!/bin/zsh
# joystick codex-hook regression tests — run after editing codex-hook.sh.
# Uses a throwaway $XDG_STATE_HOME so it never touches the real event log.
# The Codex analogue of hook-test.zsh (which covers claude-hook.sh).
set -u
H=${0:A:h}/../codex-hook.sh       # the hook beside this test (worktree-aware)
TMP=$(mktemp -d)
export XDG_STATE_HOME=$TMP
LOG=$TMP/joystick/events.jsonl
pass=0 fail=0

fire()  { print -r -- "$1" | "$H" >/dev/null 2>&1 }
ends()  { grep "\"id\":\"codex-$1\"" "$LOG" 2>/dev/null | grep -c '"ev":"end"' }
lines() { grep -c "\"id\":\"codex-$1\"" "$LOG" 2>/dev/null; true }
field() { grep "\"id\":\"codex-$1\"" "$LOG" | grep "\"ev\":\"$2\"" | jq -r "$3" | tail -1 }
check() { if [[ "$2" == "$3" ]]; then ((pass++)); else ((fail++)); print "FAIL: $1 (got '$2', want '$3')"; fi }

# A plain turn (UserPromptSubmit → Stop) opens a codex-kind start and closes it.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp","prompt":"do x","model":"gpt-5.6-terra","permission_mode":"auto"}'
check "start is kind codex" "$(field s1 start '.kind')" "codex"
check "prompt becomes the label" "$(field s1 start '.cmd')" "» do x"
fire '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp","last_assistant_message":"all done","model":"gpt-5.6-terra","permission_mode":"auto"}'
check "plain turn closes" "$(ends s1)" "1"
check "Stop blurb from last_assistant_message" "$(field s1 end '.msg')" "all done"
check "Stop exit is 0" "$(field s1 end '.exit')" "0"

# meta (model + mode) is emitted from the payload — no transcript parse.
check "meta model captured" "$(field s1 meta '.model')" "gpt-5.6-terra"
check "meta mode captured" "$(field s1 meta '.mode')" "auto"

# A duplicate Stop must not emit a second end.
fire '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp"}'
check "dup Stop: no double end" "$(ends s1)" "1"

# Stop with no open turn (e.g. after clear) emits nothing.
fire '{"hook_event_name":"Stop","session_id":"s2","cwd":"/tmp"}'
check "Stop on no turn: nothing" "$(lines s2)" "0"

# PermissionRequest → a waiting event; its description becomes the reason.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s3","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PermissionRequest","session_id":"s3","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"git push","description":"push to origin"}}'
check "permission → waiting" "$(field s3 waiting '.msg')" "push to origin"

# PostToolUse surfaces the tool just used as activity, and clears waiting.
fire '{"hook_event_name":"PostToolUse","session_id":"s3","cwd":"/tmp","tool_name":"Edit","tool_input":{"file_path":"/a/b/foo.swift"}}'
check "activity captured" "$(field s3 active '.act')" "Edit foo.swift"

# A Bash tool whose command is an argv array joins to one line.
fire '{"hook_event_name":"PostToolUse","session_id":"s3","cwd":"/tmp","tool_name":"shell","tool_input":{"command":["bash","-lc","npm test"]}}'
check "argv command joined" "$(field s3 active '.act')" "Bash: bash -lc npm test"

# SessionStart: startup emits nothing; clear/resume/compact emits a reset.
fire '{"hook_event_name":"SessionStart","session_id":"s4","cwd":"/tmp","source":"startup"}'
check "SessionStart startup: nothing" "$(lines s4)" "0"
fire '{"hook_event_name":"SessionStart","session_id":"s5","cwd":"/tmp","source":"clear"}'
check "SessionStart clear: reset" "$(field s5 reset '.ev')" "reset"
# ...and any source drops the sid-keyed surface cache (a resume in a new pane
# must not inherit the old pane's — dead — surface).
print -r -- "DEADBEEF-0000" > "$TMP/joystick/surface-s6"
fire '{"hook_event_name":"SessionStart","session_id":"s6","cwd":"/tmp","source":"resume"}'
check "SessionStart resume drops surface cache" "$([[ -e $TMP/joystick/surface-s6 ]] && echo yes || echo no)" "no"

print "pass=$pass fail=$fail"
exit $(( fail == 0 ? 0 : 1 ))
