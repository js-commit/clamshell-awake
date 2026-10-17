#!/bin/zsh
# Release build: the universal app signed with Developer ID, notarized and
# stapled, inside a DMG that is itself signed, notarized and stapled.
# Output: dist/clamshell-awake-macos.dmg (fixed name, so the
# releases/latest/download/ link never changes) and its SHA-256.
#
# Needs a "Developer ID Application" identity in the login keychain and the
# env vars NOTARY_TOOL_APPLE_ID, NOTARY_TOOL_PASSWORD (app-specific password)
# and NOTARY_TOOL_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")"
: "${NOTARY_TOOL_APPLE_ID:?}" "${NOTARY_TOOL_PASSWORD:?}" "${NOTARY_TOOL_TEAM_ID:?}"

APP=build/ClamshellAwake.app
STAGE=build/dmg
DMG=dist/clamshell-awake-macos.dmg
SIGN="Developer ID Application"

notarize() {
  local out
  out="$(xcrun notarytool submit "$1" --apple-id "$NOTARY_TOOL_APPLE_ID" \
    --password "$NOTARY_TOOL_PASSWORD" --team-id "$NOTARY_TOOL_TEAM_ID" --wait 2>&1)"
  print -r -- "$out" | grep -E '^ *(id|status):'
  # notarytool can exit 0 on an Invalid result; trust only the status line.
  print -r -- "$out" | grep -q 'status: Accepted' || { print -u2 "notarization failed: $1"; exit 1; }
}

./build.sh --no-install

codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" build/ClamshellAwake.zip
notarize build/ClamshellAwake.zip
xcrun stapler staple "$APP"

rm -rf "$STAGE" && mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/ClamshellAwake.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname ClamshellAwake -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl -a -vvv -t install "$DMG"
spctl -a -vvv "$APP"
shasum -a 256 "$DMG"
