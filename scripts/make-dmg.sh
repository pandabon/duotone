#!/bin/zsh
# Builds build/Duotone-<version>.dmg: the app, an arrow, and an Applications shortcut.
# Usage: scripts/make-dmg.sh
#
# Resources/dmg-layout.DS_Store is the saved install window: its size, icon positions and
# background. Regenerate it if those change; Duotone.app, Applications and the volume name are
# referenced by name.
set -euo pipefail
cd "${0:A:h}/.."

# A DMG is for sharing, and a personal certificate would put its owner's name and email in it.
unset SIGN_IDENTITY
scripts/build.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DMG="build/Duotone-$VERSION.dmg"
ROOT="$(mktemp -d)"
RW="$ROOT/writable.dmg"
MOUNT="$ROOT/volume"
trap 'diskutil eject "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$ROOT"' EXIT

# Copied into a mounted volume, because creating an image from a folder drops .DS_Store.
diskutil image create blank "$RW" --size 64m --volumeName Duotone --fs APFS >/dev/null
diskutil image attach --nobrowse --mountPoint "$MOUNT" "$RW" >/dev/null
ditto build/Duotone.app "$MOUNT/Duotone.app"
ln -s /Applications "$MOUNT/Applications"
cp Resources/dmg-background.tiff "$MOUNT/.background.tiff"
cp Resources/dmg-layout.DS_Store "$MOUNT/.DS_Store"
diskutil eject "$MOUNT" >/dev/null

rm -f "$DMG"
diskutil image create from "$RW" "$DMG" --format ULMO >/dev/null
echo "Built $DMG ($(du -sh "$DMG" | cut -f1))"
