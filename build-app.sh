#!/bin/zsh
# Build Joystick.app from Joystick.swift into ~/Applications.
set -e
DIR="$HOME/.config/joystick"
APP="$HOME/Applications/Joystick.app"

mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Joystick-Info.plist" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library "$DIR/Joystick.swift" -o "$APP/Contents/MacOS/Joystick"
codesign -s - --force "$APP"
echo "Built $APP"
