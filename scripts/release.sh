#!/usr/bin/env bash
#
# release.sh — Build, sign, notarize, and package Byblos for distribution.
#
# Prerequisites:
#   - Apple Developer ID Application certificate installed in Keychain
#   - App-specific password stored in Keychain for notarization
#   - Rust toolchain, Xcode, xcodegen installed
#
# Setup notarization credentials (run once):
#   xcrun notarytool store-credentials "ByblosNotary" \
#     --apple-id "YOUR_APPLE_ID" \
#     --team-id "2JWVCUHX54" \
#     --password "APP_SPECIFIC_PASSWORD"
#
# Usage: ./scripts/release.sh [version]
#   Example: ./scripts/release.sh 0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-0.1.0}"
TEAM_ID="2JWVCUHX54"
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="ByblosNotary"

APP_NAME="Byblos"
BUNDLE_ID="im.byblos.app"

BUILD_DIR="$PROJECT_DIR/build"
RELEASE_DIR="$BUILD_DIR/release"
APP_PATH="$RELEASE_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
LLM_HELPER="$PROJECT_DIR/target/release/byblos-llm"

echo "=== Building Byblos $VERSION ==="
echo ""

# Clean build directory.
rm -rf "$BUILD_DIR"
mkdir -p "$RELEASE_DIR"

# Step 1: Build Rust core (release).
echo "==> Building Rust core..."
cd "$PROJECT_DIR"
source "$HOME/.cargo/env" 2>/dev/null || true
cargo build --release -p byblos-core -p byblos-llm-helper
echo "    Core library: target/release/libbyblos_core.a"
echo "    LLM helper:   target/release/byblos-llm"

# Step 2: Generate C header.
echo "==> Generating C header..."
cbindgen --config core/cbindgen.toml --crate byblos-core --output core/include/byblos_core.h

# Step 3: Build macOS app (Release config).
echo "==> Building macOS app..."
cd "$PROJECT_DIR/macos"
xcodegen generate
xcodebuild \
  -project Byblos.xcodeproj \
  -scheme Byblos \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  MARKETING_VERSION="$VERSION" \
  build

# Copy app bundle to release directory.
cp -R "$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP_PATH"

# Step 4: Copy LLM helper into app bundle.
echo "==> Bundling LLM helper..."
HELPERS_DIR="$APP_PATH/Contents/MacOS"
cp "$LLM_HELPER" "$HELPERS_DIR/byblos-llm"

# Step 5: Sign everything.
echo "==> Signing..."

# Sign the LLM helper binary.
codesign --force --options runtime \
  --sign "$SIGNING_IDENTITY" \
  --timestamp \
  "$HELPERS_DIR/byblos-llm"

# Sign the main app bundle (deep signs all nested code).
codesign --force --deep --options runtime \
  --sign "$SIGNING_IDENTITY" \
  --timestamp \
  --entitlements "$PROJECT_DIR/macos/Byblos/Byblos.entitlements" \
  "$APP_PATH"

# Verify signature.
codesign --verify --verbose=2 "$APP_PATH"
echo "    Signature verified."

# Step 6: Create DMG.
echo "==> Creating DMG..."
DMG_TEMP="$BUILD_DIR/dmg-temp"
mkdir -p "$DMG_TEMP"
cp -R "$APP_PATH" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_TEMP" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_TEMP"

# Sign the DMG.
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

# Step 7: Notarize.
echo "==> Notarizing (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# Staple the notarization ticket to the DMG.
echo "==> Stapling..."
xcrun stapler staple "$DMG_PATH"

# Done.
echo ""
echo "=== Release complete ==="
echo "  App:     $APP_PATH"
echo "  DMG:     $DMG_PATH"
echo "  Version: $VERSION"
echo ""
echo "Next steps:"
echo "  1. Test: open '$DMG_PATH'"
echo "  2. Upload to GitHub: gh release create v$VERSION '$DMG_PATH' --title 'Byblos $VERSION'"
