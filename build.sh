#!/bin/bash
set -e

echo "🔨 Building MacOverlay..."

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/MacOverlay"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/MacOverlay.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Only create the bundle structure if it doesn't exist yet.
# Avoid rm -rf so macOS keeps the app's TCC (privacy permission) record across builds.
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "📦 Compiling Swift sources..."
SWIFT_SOURCES=()
while IFS= read -r -d '' f; do SWIFT_SOURCES+=("$f"); done < <(find "$SRC_DIR" -type f -name "*.swift" -print0)

swiftc \
    -O \
    -o "$MACOS_DIR/MacOverlay" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Speech \
    -framework ScreenCaptureKit \
    -framework EventKit \
    -framework UserNotifications \
    -framework WebKit \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework Network \
    -framework CryptoKit \
    -target arm64-apple-macos14.0 \
    "${SWIFT_SOURCES[@]}"

cp "$SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

# Sign the bundle. We attach the entitlements file so the
# `com.apple.developer.applesignin` capability is encoded into the bundle
# signature — required for the SignInWithAppleButton to even render.
#
# Ad-hoc signing (the `-` identity) is fine for local development, but
# Sign in with Apple will not actually return a credential against an
# ad-hoc-signed bundle. To ship to real customers, rebuild with a
# Developer ID Application identity that's been provisioned for the
# `com.overlay.MacOverlay` bundle ID with the Sign in with Apple
# capability enabled in Apple Developer's Identifiers panel.
ENTITLEMENTS="$SRC_DIR/MacOverlay.entitlements"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "🔏 Signing (identity=$SIGN_IDENTITY)..."
# Hardened Runtime (`--options runtime`) is intentionally NOT enabled. It's
# only required for notarization, and turning it on with ad-hoc signing
# trips launchd (POSIX 163) because the app uses microphone, screen
# recording, calendar, etc. without the matching hardened-runtime
# entitlements declared. Add it back alongside a Developer ID identity +
# the full entitlement set when you're ready to notarize for distribution.
codesign -f -s "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR" 2>/dev/null || true

echo ""
echo "✅ Build complete!"
echo "📍 App location: $APP_DIR"

if [[ "$1" == "--run" || "$1" == "-r" ]]; then
    echo "🔄 Relaunching..."
    pkill MacOverlay 2>/dev/null; sleep 0.3
    open "$APP_DIR"
    echo "✅ Running!"
else
    echo ""
    echo "To run:          open $APP_DIR"
    echo "To rebuild+run:  ./build.sh --run"
fi
