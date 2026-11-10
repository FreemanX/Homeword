#!/bin/sh
# Build Homeword.app into app/build/. SIGN_IDENTITY: a code-signing identity (default: ad-hoc). An ad-hoc signature gets a
# designated requirement on the bundle ID instead of the binary's hash, so the Accessibility permission survives rebuilds (fine for
# a local prototype: any program signed with this bundle ID would match it).
set -e
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
APP=build/Homeword.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/inputpredictor-modcache"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Homeword"
sed "s#@REPO@#$REPO#" Info.plist.in > "$APP/Contents/Info.plist"
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - -r='designated => identifier "dev.homeword.app"' "$APP"
fi
echo "built $APP"
