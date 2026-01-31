#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO="Speechall/speechall-cli"
TAP_REPO="Speechall/homebrew-tap"
SOURCE_FILE="Sources/speechall/speechall_cli.swift"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage:
  ./release.sh <version>                 Full release (build, tag, publish, formula)
  ./release.sh --formula-only <version>  Regenerate and push formula only

Examples:
  ./release.sh 0.1.0
  ./release.sh --formula-only 0.1.0
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
FORMULA_ONLY=false

if [[ $# -lt 1 ]]; then
    usage
fi

if [[ "$1" == "--formula-only" ]]; then
    FORMULA_ONLY=true
    shift
fi

if [[ $# -lt 1 ]]; then
    usage
fi

VERSION="$1"
TAG="v$VERSION"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

generate_formula() {
    local sha_macos_arm64="$1"
    local sha_macos_amd64="$2"
    local sha_linux_arm64="$3"
    local sha_linux_amd64="$4"
    local formula_dir="$5"

    mkdir -p "$formula_dir"
    cat > "$formula_dir/speechall.rb" <<RUBY
class Speechall < Formula
  desc "CLI for speech-to-text transcription via the Speechall API"
  homepage "https://github.com/${REPO}"
  version "${VERSION}"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/${REPO}/releases/download/${TAG}/speechall-${VERSION}-macos-arm64.tar.gz"
      sha256 "${sha_macos_arm64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/${TAG}/speechall-${VERSION}-macos-amd64.tar.gz"
      sha256 "${sha_macos_amd64}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/${REPO}/releases/download/${TAG}/speechall-${VERSION}-linux-arm64.tar.gz"
      sha256 "${sha_linux_arm64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/${TAG}/speechall-${VERSION}-linux-amd64.tar.gz"
      sha256 "${sha_linux_amd64}"
    end
  end

  def install
    bin.install "speechall"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/speechall --version")
  end
end
RUBY
}

push_formula() {
    local tap_dir="/tmp/homebrew-tap"

    if [[ -d "$tap_dir/.git" ]]; then
        info "Pulling latest homebrew-tap..."
        git -C "$tap_dir" pull --ff-only
    else
        info "Cloning homebrew-tap..."
        rm -rf "$tap_dir"
        gh repo clone "$TAP_REPO" "$tap_dir"
    fi

    mkdir -p "$tap_dir/Formula"
    cp "$1" "$tap_dir/Formula/speechall.rb"
    git -C "$tap_dir" add Formula/speechall.rb
    git -C "$tap_dir" diff --quiet --cached Formula/ || git -C "$tap_dir" commit -m "speechall ${VERSION}"
    git -C "$tap_dir" push
}

# ---------------------------------------------------------------------------
# --formula-only mode: download existing release, compute checksums, push
# ---------------------------------------------------------------------------
if [[ "$FORMULA_ONLY" == true ]]; then
    info "Formula-only mode: downloading archives from release ${TAG}..."

    DOWNLOAD_DIR=$(mktemp -d)
    FORMULA_TMP=$(mktemp -d)
    trap 'rm -rf "$DOWNLOAD_DIR" "$FORMULA_TMP"' EXIT

    gh release download "$TAG" --repo "$REPO" --dir "$DOWNLOAD_DIR" \
        --pattern "speechall-${VERSION}-*.tar.gz"

    info "Computing SHA256 checksums..."
    SHA_MACOS_ARM64=$(shasum -a 256 "$DOWNLOAD_DIR/speechall-${VERSION}-macos-arm64.tar.gz" | awk '{print $1}')
    SHA_MACOS_AMD64=$(shasum -a 256 "$DOWNLOAD_DIR/speechall-${VERSION}-macos-amd64.tar.gz" | awk '{print $1}')
    SHA_LINUX_ARM64=$(shasum -a 256 "$DOWNLOAD_DIR/speechall-${VERSION}-linux-arm64.tar.gz" | awk '{print $1}')
    SHA_LINUX_AMD64=$(shasum -a 256 "$DOWNLOAD_DIR/speechall-${VERSION}-linux-amd64.tar.gz" | awk '{print $1}')

    echo "  macos-arm64: $SHA_MACOS_ARM64"
    echo "  macos-amd64: $SHA_MACOS_AMD64"
    echo "  linux-arm64: $SHA_LINUX_ARM64"
    echo "  linux-amd64: $SHA_LINUX_AMD64"
    generate_formula "$SHA_MACOS_ARM64" "$SHA_MACOS_AMD64" "$SHA_LINUX_ARM64" "$SHA_LINUX_AMD64" "$FORMULA_TMP"

    info "Generated formula:"
    cat "$FORMULA_TMP/speechall.rb"
    echo ""

    push_formula "$FORMULA_TMP/speechall.rb"

    info "Formula pushed. Install with: brew install ${TAP_REPO#Speechall/homebrew-}/speechall"
    # Alternate: brew install Speechall/tap/speechall
    exit 0
fi

# ---------------------------------------------------------------------------
# Full release mode
# ---------------------------------------------------------------------------

# Step 1: Pre-flight checks
info "Running pre-flight checks..."

command -v gh >/dev/null 2>&1    || error "gh CLI not installed. Install from https://cli.github.com"
gh auth status >/dev/null 2>&1   || error "gh CLI not authenticated. Run: gh auth login"
command -v docker >/dev/null 2>&1 || error "Docker not installed."
docker info >/dev/null 2>&1      || error "Docker is not running. Start Docker Desktop."

if [[ -n "$(git status --porcelain)" ]]; then
    error "Working tree is not clean. Commit or stash changes first."
fi

if git tag -l "$TAG" | grep -q "^${TAG}$"; then
    error "Tag $TAG already exists. Delete it first or use a different version."
fi

gh repo view "$REPO" >/dev/null 2>&1 || error "Remote repo $REPO not reachable."

info "All pre-flight checks passed."

# Step 2: Update version string
info "Updating version to ${VERSION} in ${SOURCE_FILE}..."
# macOS sed requires '' after -i; GNU sed does not
sed -i '' 's/version: "[^"]*"/version: "'"$VERSION"'"/' "$SOURCE_FILE"

# Step 3: Clean and build
info "Cleaning output directory..."
rm -rf output/

info "Building macOS binaries..."
./build-macos.sh

info "Building Linux binaries..."
./build-linux.sh

# Step 4: Verify macOS dynamic linking
info "Checking macOS arm64 binary for non-system dynamic dependencies..."
NON_SYSTEM=$(otool -L output/speechall-macos-arm64 \
    | tail -n +2 \
    | grep -v '/usr/lib/' \
    | grep -v '/System/' \
    || true)

if [[ -n "$NON_SYSTEM" ]]; then
    echo "$NON_SYSTEM"
    error "Non-system dynamic dependencies found. The binary must be self-contained."
fi
info "No non-system dependencies found."

# Step 5: Create tar.gz archives
info "Creating archives..."
ARCHIVE_DIR="output/archives"
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"

for platform_arch in macos-arm64 macos-amd64 linux-arm64 linux-amd64; do
    src="output/speechall-${platform_arch}"
    archive="$ARCHIVE_DIR/speechall-${VERSION}-${platform_arch}.tar.gz"

    # Create a temp dir with the binary renamed to just "speechall"
    staging=$(mktemp -d)
    cp "$src" "$staging/speechall"
    tar -czf "$archive" -C "$staging" speechall
    rm -rf "$staging"

    echo "  $(basename "$archive"): $(du -h "$archive" | cut -f1)"
done

# Step 6: Commit, tag, push
info "Committing version bump..."
git add "$SOURCE_FILE"
git commit -m "bump version to ${VERSION}"

info "Creating tag ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"

info "Pushing commit and tag..."
git push origin HEAD "$TAG"

# Step 7: Create GitHub Release
info "Creating GitHub Release ${TAG}..."
gh release create "$TAG" output/archives/*.tar.gz \
    --repo "$REPO" --title "$TAG" --generate-notes

# Step 8: Compute SHA256 checksums
info "Computing SHA256 checksums..."
SHA_MACOS_ARM64=$(shasum -a 256 "$ARCHIVE_DIR/speechall-${VERSION}-macos-arm64.tar.gz" | awk '{print $1}')
SHA_MACOS_AMD64=$(shasum -a 256 "$ARCHIVE_DIR/speechall-${VERSION}-macos-amd64.tar.gz" | awk '{print $1}')
SHA_LINUX_ARM64=$(shasum -a 256 "$ARCHIVE_DIR/speechall-${VERSION}-linux-arm64.tar.gz" | awk '{print $1}')
SHA_LINUX_AMD64=$(shasum -a 256 "$ARCHIVE_DIR/speechall-${VERSION}-linux-amd64.tar.gz" | awk '{print $1}')

echo "  macos-arm64: $SHA_MACOS_ARM64"
echo "  macos-amd64: $SHA_MACOS_AMD64"
echo "  linux-arm64: $SHA_LINUX_ARM64"
echo "  linux-amd64: $SHA_LINUX_AMD64"

# Step 9: Generate formula
info "Generating Homebrew formula..."
FORMULA_TMP=$(mktemp -d)
generate_formula "$SHA_MACOS_ARM64" "$SHA_MACOS_AMD64" "$SHA_LINUX_ARM64" "$SHA_LINUX_AMD64" "$FORMULA_TMP"

info "Generated formula:"
cat "$FORMULA_TMP/speechall.rb"
echo ""

# Step 10: Push formula to homebrew-tap
push_formula "$FORMULA_TMP/speechall.rb"

info "Release ${VERSION} complete!"
echo ""
echo "Install with:"
echo "  brew install Speechall/tap/speechall"
echo ""
echo "Verify with:"
echo "  speechall --version"
