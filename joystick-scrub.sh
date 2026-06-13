#!/bin/zsh
# Retroactively apply the current redaction rules to the existing events log.
# Leaves an unredacted backup at events.jsonl.bak — verify, then delete it.
set -e
source "$HOME/joystick/joystick-redact.zsh"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/joystick/events.jsonl"
[[ -f $LOG ]] || { print "no log at $LOG"; exit 0 }

cp "$LOG" "$LOG.bak"
chmod 600 "$LOG.bak"
: > "$LOG.tmp"
while IFS= read -r line; do
  _joystick_redact "$line"
  print -r -- "$REPLY" >> "$LOG.tmp"
done < "$LOG"
mv "$LOG.tmp" "$LOG"
chmod 600 "$LOG"
print "scrubbed $(wc -l < "$LOG" | tr -d ' ') lines; unredacted backup at $LOG.bak — delete it once verified"
