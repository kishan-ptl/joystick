#!/bin/zsh
# Focus a Ghostty terminal. $1 = surface id (or "-" if unknown), $2 = cwd.
# Matches the exact surface by id, falls back to any terminal at that cwd,
# and if the tab is gone entirely, reopens a new tab at that directory.
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
      focus item 1 of matches
    else if needle is not "" then
      try
        new tab in front window with configuration {initial working directory:needle}
      on error
        new window with configuration {initial working directory:needle}
      end try
    end if
  end tell
end run
EOF
