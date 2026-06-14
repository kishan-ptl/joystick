#!/bin/zsh
# dmg.sh — package the notarized dist/Joystick.app into a signed + notarized +
# stapled .dmg: the shareable download. Run ./release.sh first (it produces the
# stapled dist/Joystick.app); then:
#
#   ./dmg.sh            →   dist/Joystick-<version>.dmg
#
# Same knobs as release.sh: SIGN_ID auto-detected from the keychain (override to
# pick a cert), NOTARY_PROFILE defaults to the stored `joystick-notary` profile.
# Uses only built-in hdiutil (no create-dmg dependency); the image carries the
# app + an /Applications symlink so users drag-to-install.
set -euo pipefail

DIR="${0:A:h}"
DIST="$DIR/dist"
APP="$DIST/Joystick.app"
[[ -d $APP ]] || { print -u2 "✗ $APP not found — run ./release.sh first."; exit 1; }

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[[ -n $SIGN_ID ]] || { print -u2 "✗ No 'Developer ID Application' certificate found."; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-joystick-notary}"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Joystick-Info.plist")
DMG="$DIST/Joystick-$VER.dmg"

print "▸ Staging disk image (app + /Applications drop target)"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Joystick.app"        # faithful copy — preserves signature + stapled ticket
ln -s /Applications "$STAGE/Applications"

print "▸ Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Joystick" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

print "▸ Signing the DMG: $SIGN_ID"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

print "▸ Notarizing the DMG (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

print "▸ Stapling the ticket onto the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

print "▸ Gatekeeper assessment (should say: accepted, source=Notarized Developer ID)"
spctl --assess --type open --context context:primary-signature -vvv "$DMG" || true

print "✓ $DMG — signed, notarized, stapled. This is the shareable download."
