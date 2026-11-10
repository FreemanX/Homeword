#!/bin/sh
# Build InputPredictor.app into app/build/. SIGN_IDENTITY: a code-signing identity (default: ad-hoc). With ad-hoc signing macOS
# treats every build as a new app, so the Accessibility permission has to be granted again after a rebuild.
set -e
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
APP=build/InputPredictor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/inputpredictor-modcache"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/InputPredictor"
sed "s#@REPO@#$REPO#" Info.plist.in > "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "built $APP"
