#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_DIR="$SCRIPT_DIR/output"
BINARY_AMD64="$OUTPUT_DIR/speechall-linux-amd64"
BINARY_ARM64="$OUTPUT_DIR/speechall-linux-arm64"

echo "==> Building static Linux binaries..."
DOCKER_BUILDKIT=1 docker build --output "type=local,dest=$OUTPUT_DIR" .

echo ""
echo "==> Verifying binaries exist..."
for bin in "$BINARY_AMD64" "$BINARY_ARM64"; do
    if [ ! -f "$bin" ]; then
        echo "ERROR: $bin not found"
        exit 1
    fi
    echo "  $(basename "$bin"): $(du -h "$bin" | cut -f1) bytes"
done

echo ""
echo "==> Testing arm64 binary in Fedora container..."
docker run --rm --platform linux/arm64 \
    -v "$BINARY_ARM64":/speechall \
    fedora /speechall --help

echo ""
echo "==> Testing amd64 binary in Fedora container..."
docker run --rm --platform linux/amd64 \
    -v "$BINARY_AMD64":/speechall \
    fedora /speechall --help

echo ""
echo "==> All builds and tests passed."
echo "  $BINARY_AMD64"
echo "  $BINARY_ARM64"
