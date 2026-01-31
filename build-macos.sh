#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUTPUT_DIR"

BINARY_ARM64="$OUTPUT_DIR/speechall-macos-arm64"
BINARY_AMD64="$OUTPUT_DIR/speechall-macos-amd64"
BINARY_UNIVERSAL="$OUTPUT_DIR/speechall-macos-universal"

echo "==> Building for arm64..."
swift build -c release --arch arm64
cp "$(swift build -c release --arch arm64 --show-bin-path)/speechall" "$BINARY_ARM64"

echo ""
echo "==> Building for x86_64..."
swift build -c release --arch x86_64
cp "$(swift build -c release --arch x86_64 --show-bin-path)/speechall" "$BINARY_AMD64"

echo ""
echo "==> Creating universal binary..."
lipo -create "$BINARY_ARM64" "$BINARY_AMD64" -output "$BINARY_UNIVERSAL"

echo ""
echo "==> Stripping debug symbols..."
strip "$BINARY_ARM64" "$BINARY_AMD64" "$BINARY_UNIVERSAL"

echo ""
echo "==> Verifying binaries..."
for bin in "$BINARY_ARM64" "$BINARY_AMD64" "$BINARY_UNIVERSAL"; do
    name="$(basename "$bin")"
    size="$(du -h "$bin" | cut -f1)"
    arch="$(lipo -archs "$bin")"
    echo "  $name: $size  [$arch]"
done

echo ""
echo "==> Testing arm64 binary..."
"$BINARY_ARM64" --help

echo ""
echo "==> Testing universal binary..."
"$BINARY_UNIVERSAL" --help

echo ""
echo "==> All builds and tests passed."
echo "  $BINARY_ARM64"
echo "  $BINARY_AMD64"
echo "  $BINARY_UNIVERSAL"
