#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO="Speechall/speechall-cli"
SOURCE_FILE="Sources/SpeechallCLI/SpeechallCLI.swift"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage:
  ./release.sh <version>  Bump version, commit, tag vX.Y.Z, push (CI does the rest)

Local steps:
  1. Pre-flight checks (clean working tree, tag does not exist locally or on origin)
  2. Bump the version string in ${SOURCE_FILE}
  3. Commit the bump, create annotated tag vX.Y.Z, push commit + tag

After the tag is pushed, .github/workflows/release.yml automatically builds the
macOS (arm64/amd64) and Linux (arm64/amd64) binaries, creates the GitHub Release
with tar.gz assets, and pushes the Homebrew formula to Speechall/homebrew-tap.

Examples:
  ./release.sh 0.4.0
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
    usage
fi

VERSION="$1"
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be in X.Y.Z format (e.g. 0.4.0), got: $VERSION" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

current_version() {
    sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$SOURCE_FILE"
}

# ---------------------------------------------------------------------------
# Step 1: Pre-flight checks
# ---------------------------------------------------------------------------
info "Running pre-flight checks..."

if [[ ! -f "$SOURCE_FILE" ]]; then
    error "Source file not found: $SOURCE_FILE"
fi

if [[ -z "$(current_version)" ]]; then
    error "No version string found in ${SOURCE_FILE} (expected: version: \"X.Y.Z\")"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    error "Working tree is not clean. Commit or stash changes first."
fi

if [[ -n "$(git tag -l "$TAG")" ]]; then
    error "Tag $TAG already exists locally. Delete it first or use a different version."
fi

if [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]]; then
    error "Tag $TAG already exists on origin. Use a different version."
fi

info "All pre-flight checks passed."

# ---------------------------------------------------------------------------
# Step 2: Update version string
# ---------------------------------------------------------------------------
info "Updating version from $(current_version) to ${VERSION} in ${SOURCE_FILE}..."
# macOS sed requires '' after -i; GNU sed does not
sed -i '' 's/version: "[^"]*"/version: "'"$VERSION"'"/' "$SOURCE_FILE"

NEW_VERSION="$(current_version)"
if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    git checkout -- "$SOURCE_FILE"
    error "Version bump verification failed (expected ${VERSION}, found ${NEW_VERSION}). Source file restored."
fi

# ---------------------------------------------------------------------------
# Step 3: Commit, tag, push
# ---------------------------------------------------------------------------
info "Committing version bump..."
git add "$SOURCE_FILE"
git commit -m "bump version to ${VERSION}"

info "Creating tag ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"

info "Pushing commit and tag..."
git push origin HEAD "$TAG"

info "Release ${VERSION} handed off to CI."
echo ""
echo "CI (.github/workflows/release.yml) will now:"
echo "  1. Build macOS (arm64/amd64) and Linux (arm64/amd64) binaries"
echo "  2. Create the GitHub Release ${TAG} with tar.gz assets"
echo "  3. Push the Homebrew formula to Speechall/homebrew-tap"
echo ""
echo "Watch progress at:"
echo "  https://github.com/${REPO}/actions"
echo ""
echo "Once CI finishes, install with:"
echo "  brew install Speechall/tap/speechall"
echo ""
echo "Verify with:"
echo "  speechall --version"
