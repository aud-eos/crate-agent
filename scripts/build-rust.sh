#!/bin/bash
# Build the Rust core as a universal (arm64 + x86_64) static library and
# generate the Swift FFI bindings for consumption by the Xcode project.
#
# Outputs:
#   build-output/libcrate_agent_core.a       universal static library
#   CrateAgent/Generated/crate_agent_core.swift   Swift bindings
#   CrateAgent/Generated/crate_agent_coreFFI.h    C header for bridging
#
# Run from the repository root.

set -euo pipefail

# Ensure cargo is on PATH even when this script is invoked from a
# context that doesn't source the user's shell init (e.g., `make`,
# CI runners). The cargo env file is created by rustup-init.
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust-core"
OUTPUT_DIR="$REPO_ROOT/build-output"
SWIFT_GENERATED_DIR="$REPO_ROOT/CrateAgent/Generated"

CRATE_NAME="crate_agent_core"
LIB_NAME="lib${CRATE_NAME}.a"

PROFILE="release"
CARGO_FLAGS="--release"

echo "==> Ensuring Rust toolchain targets are installed"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null

echo "==> Building Rust core for aarch64-apple-darwin"
(cd "$RUST_DIR" && cargo build $CARGO_FLAGS --target aarch64-apple-darwin)

echo "==> Building Rust core for x86_64-apple-darwin"
(cd "$RUST_DIR" && cargo build $CARGO_FLAGS --target x86_64-apple-darwin)

echo "==> Combining into universal static library"
mkdir -p "$OUTPUT_DIR"
lipo -create \
    "$RUST_DIR/target/aarch64-apple-darwin/$PROFILE/$LIB_NAME" \
    "$RUST_DIR/target/x86_64-apple-darwin/$PROFILE/$LIB_NAME" \
    -output "$OUTPUT_DIR/$LIB_NAME"

echo "==> Generating Swift FFI bindings"
mkdir -p "$SWIFT_GENERATED_DIR"
(cd "$RUST_DIR" && cargo run $CARGO_FLAGS --bin uniffi-bindgen -- \
    generate src/crate-agent-core.udl \
    --language swift \
    --out-dir "$SWIFT_GENERATED_DIR")

# uniffi emits a .modulemap that Xcode prefers as a header search path.
# Move the C header up into build-output/ so project.yml's
# HEADER_SEARCH_PATHS finds it.
if [ -f "$SWIFT_GENERATED_DIR/${CRATE_NAME}FFI.h" ]; then
    cp "$SWIFT_GENERATED_DIR/${CRATE_NAME}FFI.h" "$OUTPUT_DIR/"
fi
if [ -f "$SWIFT_GENERATED_DIR/${CRATE_NAME}FFI.modulemap" ]; then
    cp "$SWIFT_GENERATED_DIR/${CRATE_NAME}FFI.modulemap" "$OUTPUT_DIR/module.modulemap"
fi

echo "==> Done."
echo "    Static library: $OUTPUT_DIR/$LIB_NAME"
echo "    Swift bindings: $SWIFT_GENERATED_DIR/"
