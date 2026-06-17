#!/bin/zsh
# joystick claude-hook regression tests — run after editing claude-hook.sh.
# Uses a throwaway $XDG_STATE_HOME so it never touches the real event log.
set -u
H=${0:A:h}/../claude-hook.sh      # the hook beside this test (worktree-aware)
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

# StopFailure closes the turn with exit 1 (honest failure vs the old always-0).
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s5","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"StopFailure","session_id":"s5","cwd":"/tmp"}'
check "StopFailure -> exit 1" "$(grep '"id":"claude-s5"' "$LOG" | grep '"ev":"end"' | jq -r '.exit' | tail -1)" "1"

# PostToolUseFailure surfaces a tool error as the activity.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s6","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PostToolUseFailure","session_id":"s6","cwd":"/tmp","tool_name":"Bash"}'
check "tool failure -> activity" "$(grep '"id":"claude-s6"' "$LOG" | grep '"ev":"active"' | jq -r '.act' | tail -1)" "⚠ Bash failed"

# Subagents (Task/Agent) run in the BACKGROUND: their tool call returns at
# dispatch, so PostToolUse fires immediately. It must NOT mark the subagent done
# (that bug made the live line vanish the instant it appeared) — the PreToolUse
# START line has to survive until the turn ends.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s8","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PreToolUse","session_id":"s8","cwd":"/tmp","tool_name":"Task","tool_use_id":"tu1","tool_input":{"description":"Audit X"}}'
fire '{"hook_event_name":"PostToolUse","session_id":"s8","cwd":"/tmp","tool_name":"Task","tool_use_id":"tu1","tool_input":{"description":"Audit X"}}'
check "subagent start line emitted" "$(grep '"id":"claude-s8"' "$LOG" | grep '"sub":"tu1"' | grep -c '"act":"Task: Audit X"')" "1"
check "no subdone at dispatch" "$(grep '"id":"claude-s8"' "$LOG" | grep -c '"subdone":true')" "0"

# A background subagent finishing wakes the session via an injected
# <task-notification>: the row is labelled from its <summary>, never the raw XML.
NOTIF='<task-notification><tool-use-id>tu1</tool-use-id><status>completed</status><summary>Agent "Audit X" completed</summary></task-notification>'
fire "$(jq -cn --arg p "$NOTIF" '{hook_event_name:"UserPromptSubmit",session_id:"s9",cwd:"/tmp",prompt:$p}')"
check "task-notification labelled from summary" "$(grep '"id":"claude-s9"' "$LOG" | grep '"ev":"start"' | jq -r '.cmd' | tail -1)" '» Agent "Audit X" completed'
check "raw notification XML not in row" "$(grep '"id":"claude-s9"' "$LOG" | grep -c 'task-notification')" "0"

# Crash-safe drop path: a subagent's completion <task-notification> in the SAME
# session must emit its subdone EXACTLY once and remove the marker. drop_agent
# writes the clear BEFORE unlinking the marker, so an interrupt retries on the
# next drain instead of stranding the line forever. (The drop grep needs a real
# toolu_-prefixed id, unlike the labelling test above.)
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s11","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PreToolUse","session_id":"s11","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_t1","tool_input":{"description":"Audit X"}}'
check "subagent marker created on dispatch" "$([[ -e $TMP/joystick/jagent-s11-toolu_t1 ]] && echo yes || echo no)" "yes"
NOTIF2='<task-notification><tool-use-id>toolu_t1</tool-use-id><status>completed</status><summary>done</summary></task-notification>'
fire "$(jq -cn --arg p "$NOTIF2" '{hook_event_name:"UserPromptSubmit",session_id:"s11",cwd:"/tmp",prompt:$p}')"
check "completion emits subdone once" "$(grep '"id":"claude-s11"' "$LOG" | grep '"sub":"toolu_t1"' | grep -c '"subdone":true')" "1"
check "marker cleared after drop" "$([[ -e $TMP/joystick/jagent-s11-toolu_t1 ]] && echo yes || echo no)" "no"

# Drain-at-prompt backstop: a child whose completion <task-notification> landed in
# the TRANSCRIPT (mid-turn, not delivered as its own prompt) is reconciled at the
# NEXT prompt — clears the line without a timer, and only because the completion
# actually landed.
FIX2=$TMP/fix2.jsonl
print -r -- '{"type":"queue-operation","content":"<task-notification><tool-use-id>toolu_t2</tool-use-id><status>completed</status></task-notification>"}' > "$FIX2"
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s12","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PreToolUse","session_id":"s12","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_t2","tool_input":{"description":"Bg agent"}}'
fire "$(jq -cn --arg t "$FIX2" '{hook_event_name:"UserPromptSubmit",session_id:"s12",cwd:"/tmp",prompt:"next thing",transcript_path:$t}')"
check "drain-at-prompt clears completed child" "$(grep '"id":"claude-s12"' "$LOG" | grep '"sub":"toolu_t2"' | grep -c '"subdone":true')" "1"
check "drain-at-prompt cleared the marker" "$([[ -e $TMP/joystick/jagent-s12-toolu_t2 ]] && echo yes || echo no)" "no"

# Feature-preserving property: a still-RUNNING child (no completion notification in
# the transcript yet) must NOT be cleared at the next prompt — this is what makes
# drain-at-prompt correct where a blind "clear on next prompt" would be wrong.
EMPTY=$TMP/empty.jsonl; print -r -- '{"type":"user"}' > "$EMPTY"
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s13","cwd":"/tmp","prompt":"go"}'
fire '{"hook_event_name":"PreToolUse","session_id":"s13","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_t3","tool_input":{"description":"Long agent"}}'
fire "$(jq -cn --arg t "$EMPTY" '{hook_event_name:"UserPromptSubmit",session_id:"s13",cwd:"/tmp",prompt:"keep going",transcript_path:$t}')"
check "running child NOT cleared at next prompt" "$(grep '"id":"claude-s13"' "$LOG" | grep '"sub":"toolu_t3"' | grep -c '"subdone":true')" "0"
check "running child marker survives" "$([[ -e $TMP/joystick/jagent-s13-toolu_t3 ]] && echo yes || echo no)" "yes"

# meta event: title / mode / model / ctx extracted from the transcript.
FIX=$TMP/fix.jsonl
print -r -- '{"type":"ai-title","aiTitle":"My Topic","sessionId":"s7"}' >> "$FIX"
print -r -- '{"type":"custom-title","customTitle":"My Rename","sessionId":"s7"}' >> "$FIX"
print -r -- '{"type":"permission-mode","permissionMode":"auto","sessionId":"s7"}' >> "$FIX"
print -r -- '{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0,"output_tokens":500}}}' >> "$FIX"
fire "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s7\",\"cwd\":\"/tmp\",\"prompt\":\"go\"}"
fire "{\"hook_event_name\":\"Stop\",\"session_id\":\"s7\",\"cwd\":\"/tmp\",\"transcript_path\":\"$FIX\"}"
check "meta title" "$(grep '"id":"claude-s7"' "$LOG" | grep '"ev":"meta"' | jq -r '.title' | tail -1)" "My Topic"
check "meta name (rename)" "$(grep '"id":"claude-s7"' "$LOG" | grep '"ev":"meta"' | jq -r '.name' | tail -1)" "My Rename"
check "meta ctx sum" "$(grep '"id":"claude-s7"' "$LOG" | grep '"ev":"meta"' | jq -r '.ctx' | tail -1)" "51000"
check "meta mode" "$(grep '"id":"claude-s7"' "$LOG" | grep '"ev":"meta"' | jq -r '.mode' | tail -1)" "auto"

# A permission Notification can embed a secret-bearing tool call; the emitted
# waiting msg must be redacted, not logged (or notified) raw.
fire '{"hook_event_name":"UserPromptSubmit","session_id":"s10","cwd":"/tmp","prompt":"go"}'
fire "$(jq -cn --arg m "Claude needs your permission to use Bash(curl -H 'Authorization: Bearer sk-verysecrettoken12345')" '{hook_event_name:"Notification",session_id:"s10",cwd:"/tmp",message:$m}')"
check "notification secret not logged" "$(grep '"id":"claude-s10"' "$LOG" | grep '"ev":"waiting"' | grep -c 'verysecrettoken')" "0"
check "notification msg masked"        "$(grep '"id":"claude-s10"' "$LOG" | grep '"ev":"waiting"' | jq -r '.msg' | grep -c '•••')" "1"

# Every emitted event carries the schema version.
check "events are v:1" "$(grep -c '"v":1' "$LOG")" "$(grep -c '"ev":' "$LOG")"

rm -rf "$TMP"
print "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
