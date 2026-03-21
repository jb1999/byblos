#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Building byblos-core (Rust)..."
cd "$PROJECT_ROOT"
cargo build --release -p byblos-core

echo "==> Core library built at: target/release/libbyblos_core.a"

# Generate C header for Swift FFI (requires cbindgen).
if command -v cbindgen &> /dev/null; then
    echo "==> Generating C header..."
    mkdir -p core/include
    cbindgen --config core/cbindgen.toml --crate byblos-core --output core/include/byblos_core.h
    echo "==> Header generated at: core/include/byblos_core.h"
else
    echo "==> cbindgen not found, skipping header generation."
    echo "    Install with: cargo install cbindgen"
fi

# Build macOS app (requires xcodegen).
if command -v xcodegen &> /dev/null; then
    echo "==> Generating Xcode project..."
    cd "$PROJECT_ROOT/macos"
    xcodegen generate
    echo "==> Building macOS app..."
    xcodebuild -project Byblos.xcodeproj -scheme Byblos -configuration Release build
else
    echo "==> xcodegen not found, skipping Xcode build."
    echo "    Install with: brew install xcodegen"
fi

echo "==> Done."
