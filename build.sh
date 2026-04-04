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

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "📦 Compiling Swift sources..."
swiftc \
    -o "$MACOS_DIR/MacOverlay" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Speech \
    -framework ScreenCaptureKit \
    -framework EventKit \
    -framework UserNotifications \
    -framework WebKit \
    -target arm64-apple-macos13.0 \
    "$SRC_DIR/"*.swift

cp "$SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

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
