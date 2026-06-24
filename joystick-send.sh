#!/bin/zsh
# Send a queued prompt into a Ghostty terminal — the "apply to the tab" half of
# the prompt queue. Focuses the exact surface (by id; cwd fallback), then pastes
# the text in via Ghostty's OWN bracketed paste (`perform action
# "paste_from_clipboard" on <terminal>`), so:
#   - it needs only the Automation perms we already hold for focus — NOT the
#     Accessibility/keystroke hack a System-Events keystroke would require;
#   - multi-line prompts land literally and NOTHING is auto-submitted (bracketed
#     paste defers the trailing newline) — you review and press Enter yourself.
# The text rides in on the clipboard (set here, atomically, just before paste) so
# the prompt never has to be escaped into the AppleScript body.
# $1 = surface id (or "-"), $2 = cwd, $3 = the prompt text.
printf '%s' "$3" | pbcopy
exec osascript - "${1:--}" "${2:-}" <<'EOF'
on run argv
  set surfaceId to item 1 of argv
  set needle to item 2 of argv
  tell application "Ghostty"
    activate
    set matches to {}
    if surfaceId is not "-" and surfaceId is not "" then
      set matches to every terminal whose id is surfaceId
    end if
    if (count of matches) = 0 and needle is not "" then
      set matches to every terminal whose working directory contains needle
    end if
    if (count of matches) > 0 then
      set t to item 1 of matches
      focus t
      perform action "paste_from_clipboard" on t
    end if
    -- No match = the surface is gone, so the session is gone too. Do NOT reopen
    -- a tab and paste into a fresh shell (joystick-focus.sh reopens; this must
    -- not) — silently no-op rather than fire the prompt into the wrong place.
  end tell
end run
EOF
