#!/bin/zsh
# release.sh — produce a signed + notarized + stapled Joystick.app for sharing.
#
# Dev builds use build-app.sh (ad-hoc signature, fast, for local iteration).
# THIS is the distribution path: Developer ID signing + hardened runtime +
# Apple notarization, so other people can open it with no Gatekeeper warning
# and the "control Ghostty" permission survives updates.
#
# One-time setup (see PACKAGING.md / the signing notes):
#   1. Paid Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   3. A stored notarization credential, once:
#        xcrun notarytool store-credentials joystick-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"   # from appleid.apple.com
#
# Then just:  ./release.sh
# Overrides:  SIGN_ID="Developer ID Application: Name (TEAMID)"  NOTARY_PROFILE=joystick-notary
set -euo pipefail

DIR="${0:A:h}"
DIST="$DIR/dist"
APP="$DIST/Joystick.app"
ENTITLEMENTS="$DIR/joystick.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-joystick-notary}"

# Auto-detect the Developer ID cert; override with $SIGN_ID.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -z $SIGN_ID ]]; then
  print -u2 "✗ No 'Developer ID Application' certificate found in your keychain."
  print -u2 "  Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + (needs a paid"
  print -u2 "  Developer Program membership), then re-run. Current identities:"
  security find-identity -v -p codesigning | sed 's/^/    /' >&2
  exit 1
fi

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Joystick-Info.plist" 2>/dev/null || echo '?')
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DIR/Joystick-Info.plist" 2>/dev/null || echo '?')
print "▸ Joystick $VER (build $BUILD) — bump CFBundleVersion in Joystick-Info.plist per release."

print "▸ Building bundle → $APP"
rm -rf "$DIST"; mkdir -p "$DIST"
JOYSTICK_SRC="$DIR" JOYSTICK_APP="$APP" "$DIR/build-app.sh" >/dev/null

# Re-sign (replacing build-app.sh's ad-hoc signature) with Developer ID +
# hardened runtime (--options runtime) + a secure timestamp + our entitlements.
# No --deep: the bundle has no nested code, only sealed resources/scripts.
print "▸ Signing: $SIGN_ID (hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

print "▸ Zipping for notarization"
ZIP="$DIST/Joystick.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

print "▸ Submitting to Apple notary service (a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

print "▸ Stapling the notarization ticket onto the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

print "▸ Gatekeeper assessment (should say: accepted, source=Notarized Developer ID)"
spctl --assess --type exec -vvv "$APP" || true

rm -f "$ZIP"
print "✓ $APP is signed, notarized, and stapled."
print "  Next (chunk 6): wrap it in a DMG (create-dmg) and/or a Homebrew cask."
