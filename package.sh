#!/bin/bash
set -e

# Usage: ./package.sh --channel beta|prod
#
# Builds the app for a release channel and packages it as a drag-to-install
# DMG in build/. Production must produce TheCloser.dmg: the website's
# Download buttons point at releases/latest/download/TheCloser.dmg.
#
# Signed and notarized release (see README → Signing and notarizing):
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=thecloser-notary ./package.sh --channel prod
# Without them the DMG is ad-hoc signed, and macOS warns on first open.
CHANNEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --channel=*)  CHANNEL="${1#*=}"; shift ;;
        *) echo "Usage: ./package.sh --channel beta|prod" >&2; exit 1 ;;
    esac
done

case "$CHANNEL" in
    beta) APP_NAME="TheCloser Beta"; DMG_NAME="TheCloser-Beta.dmg"; VOLUME="TheCloser Beta" ;;
    prod) APP_NAME="TheCloser";      DMG_NAME="TheCloser.dmg";      VOLUME="TheCloser" ;;
    *) echo "Usage: ./package.sh --channel beta|prod" >&2; exit 1 ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

"$PROJECT_DIR/build.sh" --channel "$CHANNEL"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$BUILD_DIR/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "💿 Packaging $DMG_NAME..."
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign -f -s "$CODESIGN_IDENTITY" --timestamp "$BUILD_DIR/$DMG_NAME"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        # Apple scans the DMG and the app inside, usually in a few minutes.
        # Stapling attaches the ticket, so Gatekeeper can check it offline.
        echo "📨 Notarizing (this waits for Apple)..."
        xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
        spctl --assess --type open --context context:primary-signature --verbose "$BUILD_DIR/$DMG_NAME"
    else
        echo "⚠️  Signed but not notarized: set NOTARY_PROFILE to notarize."
    fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist")"
echo ""
echo "✅ $BUILD_DIR/$DMG_NAME  (version $VERSION, channel $CHANNEL)"
