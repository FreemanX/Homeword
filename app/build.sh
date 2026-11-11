#!/bin/sh
# Build Homeword.app into app/build/: a development build that runs the engine from this repo. SIGN_IDENTITY: a code-signing
# identity (default: ad-hoc). An ad-hoc signature gets a designated requirement on the bundle ID instead of the binary's hash, so
# the Accessibility permission survives rebuilds (any program signed with this bundle ID would match it).
# NO_REPO=1 leaves the repo path out: release.sh puts the engine inside the app instead.
set -e
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
VERSION=$(cat ../VERSION)
BUILD=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 1)
[ -n "$NO_REPO" ] && REPO=""
APP="${OUT:-build}/Homeword.app"          # OUT: another output directory (release.sh)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/homeword-modcache"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Homeword"
sed -e "s#@REPO@#$REPO#" -e "s#@VERSION@#$VERSION#" -e "s#@BUILD@#$BUILD#" Info.plist.in > "$APP/Contents/Info.plist"
# icons from the SVGs in Icon/: AppIcon.icns, and the menu bar template image at 1x and 2x
TOOLS="${TMPDIR:-/tmp}/homeword-tools"
mkdir -p "$TOOLS"
[ "$TOOLS/svg2png" -nt Icon/svg2png.swift ] || swiftc -O Icon/svg2png.swift -o "$TOOLS/svg2png"
SET="$TOOLS/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  "$TOOLS/svg2png" Icon/icon.svg $s "$SET/icon_${s}x${s}.png"
  "$TOOLS/svg2png" Icon/icon.svg $((s * 2)) "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
"$TOOLS/svg2png" Icon/menubar.svg 18 "$APP/Contents/Resources/MenuBarIcon.png"
"$TOOLS/svg2png" Icon/menubar.svg 36 "$APP/Contents/Resources/MenuBarIcon@2x.png"
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - -r='designated => identifier "dev.homeword.app"' "$APP"
fi
echo "built $APP"
