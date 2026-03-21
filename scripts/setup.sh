#!/usr/bin/env bash
set -euo pipefail

echo "==> Setting up Byblos development environment..."

# Check Rust.
if ! command -v cargo &> /dev/null; then
    echo "ERROR: Rust is not installed. Install from https://rustup.rs"
    exit 1
fi
echo "    Rust: $(rustc --version)"

# Check Xcode CLI tools.
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode command line tools not found."
    echo "    Run: xcode-select --install"
    exit 1
fi
echo "    Xcode: $(xcodebuild -version | head -1)"

# Install optional tools.
if ! command -v cbindgen &> /dev/null; then
    echo "==> Installing cbindgen (Rust → C header generator)..."
    cargo install cbindgen
fi

if ! command -v xcodegen &> /dev/null; then
    echo "==> Installing xcodegen..."
    brew install xcodegen
fi

# Create models directory.
MODELS_DIR="${HOME}/Library/Application Support/Byblos/models"
mkdir -p "$MODELS_DIR"
echo "    Models directory: $MODELS_DIR"

echo ""
echo "==> Setup complete. Run ./scripts/build.sh to build."
