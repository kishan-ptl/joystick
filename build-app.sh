#!/bin/zsh
# Build Joystick.app from Joystick.swift into ~/Applications.
# DIR defaults to this script's own directory (so a worktree builds itself);
# APP is overridable so a worktree can build to a throwaway path instead of
# clobbering the live app:  JOYSTICK_APP=/tmp/Joystick.app ./build-app.sh
set -e
DIR="${JOYSTICK_SRC:-${0:A:h}}"
APP="${JOYSTICK_APP:-$HOME/Applications/Joystick.app}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Joystick-Info.plist" "$APP/Contents/Info.plist"
# Ship the emitter scripts + installer inside the bundle. First-run onboarding
# ("Copy setup prompt" → Claude Code) runs Resources/install.sh, which copies
# these out to $JOYSTICK_HOME and wires up the shell + Claude hooks.
cp "$DIR"/install.sh "$DIR"/joystick.zsh "$DIR"/claude-hook.sh \
   "$DIR"/joystick-redact.zsh "$DIR"/joystick-focus.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
swiftc -O -swift-version 5 -parse-as-library "$DIR/EventLog.swift" "$DIR/Joystick.swift" -o "$APP/Contents/MacOS/Joystick"
codesign -s - --force "$APP"
echo "Built $APP"
