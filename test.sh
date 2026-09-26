#!/bin/bash
# Compiles and runs the MacOverlay unit-test suite.
# Uses swiftc directly so we don't need Xcode / SPM boilerplate.
# Only includes source files that are pure logic (models, stores, managers)
# — UI / audio / networking layers that would pull in AppKit-heavy frameworks
# are not linked in.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/MacOverlay"
BUILD_DIR="$PROJECT_DIR/build/tests"
mkdir -p "$BUILD_DIR"

# Subset of the main sources that the tests need and that compile cleanly
# without the full SwiftUI/AppKit surface.
SOURCES=(
    "$SRC_DIR/SessionMode.swift"
    "$SRC_DIR/AudioSource.swift"
    "$SRC_DIR/TranscriptFilter.swift"
    "$SRC_DIR/UserProfile.swift"
    "$SRC_DIR/NotesManager.swift"
    "$SRC_DIR/AIManager.swift"
    "$SRC_DIR/Models/BrowserTab.swift"
    "$SRC_DIR/Models/ChatSession.swift"
    "$SRC_DIR/Models/PromptPreset.swift"
    "$SRC_DIR/Models/ResumePreset.swift"
    "$SRC_DIR/Models/ResumeScore.swift"
    "$SRC_DIR/Models/Workspace.swift"
    "$SRC_DIR/Stores/JSONStore.swift"
    "$SRC_DIR/AppChannel.swift"
    "$SRC_DIR/TranscriptionLanguage.swift"
    "$SRC_DIR/CallDetector.swift"
)

echo "🧪 Compiling test binary…"
swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -framework Foundation \
    -framework AppKit \
    -o "$BUILD_DIR/MacOverlayTests" \
    "${SOURCES[@]}" \
    "$PROJECT_DIR/Tests/Tests.swift"

echo "🧪 Running…"
echo
"$BUILD_DIR/MacOverlayTests"
status=$?

echo
if [[ $status -eq 0 ]]; then
    echo "✅ All tests passed"
else
    echo "❌ Tests failed (exit $status)"
fi
exit $status
