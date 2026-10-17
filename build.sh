#!/bin/zsh
# Build ClamshellAwake.app into ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/ClamshellAwake.app"
BUILD=build

mkdir -p "$BUILD" "$HOME/Applications"

if [[ ! -f Resources/AppIcon.icns || Tools/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift Tools/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o Resources/AppIcon.icns
fi

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  Sources/main.swift -o "$BUILD/ClamshellAwake"

pkill -x ClamshellAwake 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ClamshellAwake" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
[[ "${1:-}" == "--no-launch" ]] || open "$APP"
