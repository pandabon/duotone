#!/bin/zsh
# Builds an Apple silicon Duotone.app into ./build and signs it. Usage: scripts/build.sh [--open]
#
# SIGN_IDENTITY picks the codesign identity and defaults to "-" (ad hoc). An ad-hoc build runs
# on the Mac that made it; to hand it to others, sign with a Developer ID identity.
set -euo pipefail
cd "${0:A:h}/.."

# actool ships with full Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Apple silicon only: Xcode deprecates x86_64 at this deployment target.
ARCHS=(--arch arm64)
# SwiftPM keeps debug info in release builds, and that records the builder's absolute paths.
NODEBUG=(-debug-info-format none)
swift build -c release $ARCHS $NODEBUG
BIN="$(swift build -c release $ARCHS $NODEBUG --show-bin-path)/Duotone"

APP=build/Duotone.app
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN" "$APP/Contents/MacOS/Duotone"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# An Icon Composer bundle: macOS 26 draws legacy icons with transparent margins on a grey plate.
xcrun actool Resources/AppIcon.icon --compile "$RES" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist build/assetcatalog-info.plist >/dev/null
plutil -replace CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"

# No hardened runtime and no entitlements: Duotone is not sandboxed and must write other apps' preferences.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
