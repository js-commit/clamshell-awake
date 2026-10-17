#!/bin/zsh
# Build a universal (Apple silicon + Intel) ClamshellAwake.app into build/,
# then install it to ~/Applications and (re)launch it.
#   ./build.sh               build, install, launch
#   ./build.sh --no-launch   build and install only
#   ./build.sh --no-install  build only (release.sh uses this)
set -euo pipefail
cd "$(dirname "$0")"
BUILD=build
BUILT="$BUILD/ClamshellAwake.app"
APP="$HOME/Applications/ClamshellAwake.app"

mkdir -p "$BUILD"

if [[ ! -f Resources/AppIcon.icns || Tools/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift Tools/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o Resources/AppIcon.icns
fi

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    Sources/main.swift -o "$BUILD/ClamshellAwake-$arch"
done
lipo -create -output "$BUILD/ClamshellAwake" "$BUILD"/ClamshellAwake-{arm64,x86_64}

rm -rf "$BUILT"
mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
cp "$BUILD/ClamshellAwake" "$BUILT/Contents/MacOS/"
cp Info.plist "$BUILT/Contents/"
cp Resources/AppIcon.icns "$BUILT/Contents/Resources/"
codesign --force --sign - "$BUILT" >/dev/null
echo "built $BUILT"
[[ "${1:-}" == "--no-install" ]] && exit 0

pkill -x ClamshellAwake 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$BUILT" "$APP"
echo "installed $APP"
[[ "${1:-}" == "--no-launch" ]] || open "$APP"
