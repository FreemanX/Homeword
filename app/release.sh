#!/bin/sh
# Package Homeword for a GitHub release: a self-contained Homeword.app (the engine inside: ghostd, predictd and their data; no
# repo, no Python) in a disk image, dist/Homeword-<version>.dmg, plus its SHA-256. Users drag the app to Applications.
#
# Without an Apple Developer ID the app is ad-hoc signed and not notarized: macOS blocks the first launch until the user allows it
# (System Settings > Privacy & Security > Open Anyway; README "Install"). The signature's designated requirement is the bundle ID,
# so the Accessibility permission survives updates.
#
# Needs macOS 27 with the Xcode command line tools. Usage: app/release.sh     ALLOW_DIRTY=1 app/release.sh  (uncommitted, to test)
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(cat VERSION)

if [ -n "$(git status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
  echo "uncommitted changes: commit first (a release should be a commit), or ALLOW_DIRTY=1 to test" >&2
  exit 1
fi

OUT="$ROOT/dist/build"
APP="$OUT/Homeword.app"
RES="$APP/Contents/Resources"
rm -rf "$ROOT/dist"

echo "== the engine and the app ($VERSION)"
./build.sh
NO_REPO=1 OUT="$OUT" app/build.sh

E="$RES/engine"                                          # the repo's layout: ghostd finds its data next to it
mkdir -p "$E/ghost" "$E/bench"
cp ghostd predictd predictd.json "$E/"
cp ghost/*.json "$E/ghost/"
cp bench/cases.json bench/styles.json "$E/bench/"        # the benchmark in the Prompts tab
cp LICENSE "$RES/"

echo "== sign (ad-hoc)"
codesign --force --sign - "$E/ghostd"
codesign --force --sign - "$E/predictd"
codesign --force --sign - -r='designated => identifier "dev.homeword.app"' "$APP"
codesign --verify --strict "$APP"

echo "== check the bundled engine"
"$E/predictd" --version
printf '%s\n' '{"fn": "suite"}' '{"fn": "profile", "args": {"style": "chat"}}' '{"fn": "proof_profile", "args": {"mode": "fix"}}' \
  | "$E/ghostd" --selftest | grep -c '"instructions"\|"category"' | grep -qx 3 || { echo "the bundled engine misses its data" >&2; exit 1; }
echo "engine data: ok"

echo "== disk image"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Homeword.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Homeword-$VERSION.dmg"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName Homeword "$STAGE" "$DMG" >/dev/null   # hdiutil create is deprecated
rm -rf "$STAGE"
(cd dist && shasum -a 256 "Homeword-$VERSION.dmg" > "Homeword-$VERSION.dmg.sha256")

echo
echo "app:  $(du -sh "$APP" | cut -f1)  $APP"
echo "dmg:  $(du -sh "$DMG" | cut -f1)  $DMG"
cat "dist/Homeword-$VERSION.dmg.sha256"
echo
echo "To publish (creates the tag and the release on GitHub):"
echo "  gh release create v$VERSION $DMG $DMG.sha256 --title \"Homeword $VERSION\" --notes-file <release notes>"
