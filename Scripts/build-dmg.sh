#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/Scripts/stapler-retry.sh"
OUTPUT_DIR="${MACPILOT_OUTPUT_DIR:-$ROOT}"
VERSION="${MACPILOT_VERSION:-$("$ROOT/Scripts/version.sh")}"
APP="$OUTPUT_DIR/MacPilot.app"
codesign --verify --deep --strict "$APP"
macpilot_stapler validate "$APP"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/MacPilot.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUTPUT_DIR/MacPilot-$VERSION.dmg"
hdiutil create -volname MacPilot -srcfolder "$STAGING" -format UDZO -ov "$DMG"
codesign --force --sign "${MACPILOT_DEVELOPER_ID:?}" --timestamp "$DMG"
if [[ -n "${MACPILOT_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$MACPILOT_NOTARY_PROFILE" --wait
else
    xcrun notarytool submit "$DMG" --apple-id "${MACPILOT_APPLE_ID:?}" \
        --password "${MACPILOT_APPLE_PASSWORD:?}" --team-id "${MACPILOT_TEAM_ID:?}" --wait
fi
macpilot_stapler staple "$DMG"
macpilot_stapler validate "$DMG"
echo "Built $DMG"
