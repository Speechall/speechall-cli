# Homebrew Distribution for Swift CLI Tools

This document describes how to distribute a Swift CLI tool via Homebrew on macOS and Linux using pre-built binaries.

## Overview

The approach uses a **Homebrew tap** (a third-party formula repository) that serves pre-built binaries from GitHub Releases. Users install with:

```bash
brew install YourOrg/tap/your-tool
```

This avoids requiring users to have Swift installed or to compile from source.

## Prerequisites

### One-Time Setup

1. **Create the tap repository** on GitHub named `YourOrg/homebrew-tap` (the `homebrew-` prefix is required):
   ```bash
   gh repo create YourOrg/homebrew-tap --public --description "Homebrew formulae"
   ```

2. **Create the CLI repository** on GitHub (if not already):
   ```bash
   gh repo create YourOrg/your-cli --public --source=. --push
   ```

3. **Add a LICENSE file** to your CLI repo. The formula declares a license field that must match.

4. **Add `--version` support** to your CLI. In your `@main` struct:
   ```swift
   static let configuration = CommandConfiguration(
       commandName: "your-tool",
       version: "0.1.0",  // release.sh updates this via sed
       abstract: "Description here.",
       // ...
   )
   ```

### Tools Required

- `gh` CLI authenticated with repo access
- Docker (for Linux cross-compilation)
- Xcode / Swift toolchain (for macOS builds)

## Build Scripts

You need scripts that produce stripped binaries for each platform/architecture.

### macOS (`build-macos.sh`)

Builds arm64 and x86_64 binaries:

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p output

for arch in arm64 x86_64; do
    swift build -c release --arch "$arch"
    bin_path="$(swift build -c release --arch "$arch" --show-bin-path)/your-tool"
    arch_name=$([[ "$arch" == "x86_64" ]] && echo "amd64" || echo "arm64")
    cp "$bin_path" "output/your-tool-macos-${arch_name}"
    strip "output/your-tool-macos-${arch_name}"
done
```

### Linux (`build-linux.sh`)

Uses Docker with the Swift Static Linux SDK for fully static, portable binaries:

```bash
#!/usr/bin/env bash
set -euo pipefail

docker build --output "type=local,dest=output" .
```

With a `Dockerfile` like:

```dockerfile
FROM swift:6.0 AS builder

# Install Static Linux SDK (adjust version/checksum as needed)
RUN swift sdk install \
    https://download.swift.org/swift-6.0-release/static-sdk/swift-6.0-RELEASE/swift-6.0-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \
    --checksum <checksum>

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY . .

# Build for both architectures
RUN swift build -c release --swift-sdk x86_64-swift-linux-musl
RUN swift build -c release --swift-sdk aarch64-swift-linux-musl

FROM scratch AS export
COPY --from=builder /build/.build/x86_64-swift-linux-musl/release/your-tool /your-tool-linux-amd64
COPY --from=builder /build/.build/aarch64-swift-linux-musl/release/your-tool /your-tool-linux-arm64
```

## Release Script

The `release.sh` script automates the full release process.

### Usage

```bash
./release.sh <version>              # full release
./release.sh --formula-only <version>  # retry formula push only
```

### Script Flow

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: ./release.sh [--formula-only] <version>}"
FORMULA_ONLY=false

if [[ "$VERSION" == "--formula-only" ]]; then
    FORMULA_ONLY=true
    VERSION="${2:?Usage: ./release.sh --formula-only <version>}"
fi

TAG="v${VERSION}"
REPO="YourOrg/your-cli"
TAP_REPO="YourOrg/homebrew-tap"
TAP_DIR="/tmp/homebrew-tap"
ARCHIVE_DIR="output/archives"
PLATFORMS="macos-arm64 macos-amd64 linux-arm64 linux-amd64"

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks (skip for --formula-only)
# ─────────────────────────────────────────────────────────────────
if [[ "$FORMULA_ONLY" == false ]]; then
    command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }
    command -v docker >/dev/null || { echo "Docker required"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Docker not running"; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Working tree dirty"; exit 1; }
    ! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "Tag $TAG exists"; exit 1; }
fi

# ─────────────────────────────────────────────────────────────────
# Full release path
# ─────────────────────────────────────────────────────────────────
if [[ "$FORMULA_ONLY" == false ]]; then
    # Update version in source (macOS sed syntax)
    sed -i '' 's/version: "[^"]*"/version: "'"$VERSION"'"/' \
        Sources/your-tool/main.swift

    # Clean and build
    rm -rf output/
    ./build-macos.sh
    ./build-linux.sh

    # Verify no non-system dynamic dependencies (macOS)
    if otool -L output/your-tool-macos-arm64 | grep -v '/usr/lib' | grep -v '/System' | grep -q .; then
        echo "Error: Non-system dynamic dependencies found"
        exit 1
    fi

    # Create archives
    rm -rf "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"
    for platform in $PLATFORMS; do
        tmpdir="$(mktemp -d)"
        cp "output/your-tool-${platform}" "$tmpdir/your-tool"
        tar -czf "$ARCHIVE_DIR/your-tool-${VERSION}-${platform}.tar.gz" -C "$tmpdir" your-tool
        rm -rf "$tmpdir"
    done

    # Commit, tag, push
    git add Sources/
    git commit -m "bump version to ${VERSION}"
    git tag -a "$TAG" -m "Release ${TAG}"
    git push origin main "$TAG"

    # Create GitHub release
    gh release create "$TAG" "$ARCHIVE_DIR"/*.tar.gz \
        --repo "$REPO" --title "$TAG" --generate-notes
fi

# ─────────────────────────────────────────────────────────────────
# Formula generation (both paths)
# ─────────────────────────────────────────────────────────────────

# For --formula-only, download archives from existing release
if [[ "$FORMULA_ONLY" == true ]]; then
    rm -rf "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"
    gh release download "$TAG" --repo "$REPO" --dir "$ARCHIVE_DIR"
fi

# Compute SHA256 checksums
SHA_MACOS_ARM64="$(shasum -a 256 "$ARCHIVE_DIR/your-tool-${VERSION}-macos-arm64.tar.gz" | awk '{print $1}')"
SHA_MACOS_AMD64="$(shasum -a 256 "$ARCHIVE_DIR/your-tool-${VERSION}-macos-amd64.tar.gz" | awk '{print $1}')"
SHA_LINUX_ARM64="$(shasum -a 256 "$ARCHIVE_DIR/your-tool-${VERSION}-linux-arm64.tar.gz" | awk '{print $1}')"
SHA_LINUX_AMD64="$(shasum -a 256 "$ARCHIVE_DIR/your-tool-${VERSION}-linux-amd64.tar.gz" | awk '{print $1}')"

# Clone or update tap repo
if [[ -d "$TAP_DIR" ]]; then
    git -C "$TAP_DIR" fetch origin
    git -C "$TAP_DIR" reset --hard origin/main
else
    gh repo clone "$TAP_REPO" "$TAP_DIR"
fi

mkdir -p "$TAP_DIR/Formula"

# Generate formula
cat > "$TAP_DIR/Formula/your-tool.rb" << EOF
class YourTool < Formula
  desc "Description of your tool"
  homepage "https://github.com/${REPO}"
  version "${VERSION}"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-macos-arm64.tar.gz"
      sha256 "${SHA_MACOS_ARM64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-macos-amd64.tar.gz"
      sha256 "${SHA_MACOS_AMD64}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-linux-arm64.tar.gz"
      sha256 "${SHA_LINUX_ARM64}"
    end
    on_intel do
      url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-linux-amd64.tar.gz"
      sha256 "${SHA_LINUX_AMD64}"
    end
  end

  def install
    bin.install "your-tool"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/your-tool --version")
  end
end
EOF

# Push formula
git -C "$TAP_DIR" add Formula/your-tool.rb
git -C "$TAP_DIR" commit -m "your-tool ${VERSION}"
git -C "$TAP_DIR" push origin main

echo "Release complete: brew install ${TAP_REPO#*/}/your-tool"
```

## Formula Structure

The formula uses Homebrew's platform DSL to serve architecture-specific binaries:

- `on_macos` / `on_linux` -- operating system blocks
- `on_arm` / `on_intel` -- architecture blocks (nestable)
- Each block specifies its own `url` and `sha256`

Key points:

- **No `bottle` directive** -- `bottle :unneeded` is deprecated; just omit it
- **No `depends_on`** -- verify with `otool -L` that macOS binaries only link system libs
- **Test block** validates the installed version matches the formula version

## GitHub Actions (Optional)

For automated releases on tag push, create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  build-macos:
    runs-on: macos-15
    strategy:
      matrix:
        arch: [arm64, x86_64]
    steps:
      - uses: actions/checkout@v4
      - uses: swift-actions/setup-swift@v2
        with:
          swift-version: '6.0'
      - name: Build
        run: |
          swift build -c release --arch ${{ matrix.arch }}
          mkdir -p output
          arch_name=${{ matrix.arch == 'x86_64' && 'amd64' || 'arm64' }}
          cp "$(swift build -c release --arch ${{ matrix.arch }} --show-bin-path)/your-tool" output/your-tool
          strip output/your-tool
          tar -czf "output/your-tool-${GITHUB_REF_NAME#v}-macos-${arch_name}.tar.gz" -C output your-tool
      - uses: actions/upload-artifact@v4
        with:
          name: macos-${{ matrix.arch }}
          path: output/*.tar.gz

  build-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/setup-qemu-action@v3
      - name: Build
        run: |
          docker build --output "type=local,dest=output" .
          mkdir -p archives
          for arch in amd64 arm64; do
            tmpdir=$(mktemp -d)
            cp "output/your-tool-linux-${arch}" "$tmpdir/your-tool"
            tar -czf "archives/your-tool-${GITHUB_REF_NAME#v}-linux-${arch}.tar.gz" -C "$tmpdir" your-tool
          done
      - uses: actions/upload-artifact@v4
        with:
          name: linux
          path: archives/*.tar.gz

  release:
    needs: [build-macos, build-linux]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
          merge-multiple: true

      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" artifacts/*.tar.gz \
            --repo "$GITHUB_REPOSITORY" --title "$GITHUB_REF_NAME" --generate-notes

      - name: Update formula
        env:
          TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          TAG="$GITHUB_REF_NAME"
          REPO="$GITHUB_REPOSITORY"

          SHA_MACOS_ARM64=$(shasum -a 256 artifacts/your-tool-${VERSION}-macos-arm64.tar.gz | awk '{print $1}')
          SHA_MACOS_AMD64=$(shasum -a 256 artifacts/your-tool-${VERSION}-macos-amd64.tar.gz | awk '{print $1}')
          SHA_LINUX_ARM64=$(shasum -a 256 artifacts/your-tool-${VERSION}-linux-arm64.tar.gz | awk '{print $1}')
          SHA_LINUX_AMD64=$(shasum -a 256 artifacts/your-tool-${VERSION}-linux-amd64.tar.gz | awk '{print $1}')

          git clone "https://x-access-token:${TAP_TOKEN}@github.com/YourOrg/homebrew-tap.git" /tmp/tap
          mkdir -p /tmp/tap/Formula

          cat > /tmp/tap/Formula/your-tool.rb << FORMULA
          class YourTool < Formula
            desc "Description"
            homepage "https://github.com/${REPO}"
            version "${VERSION}"
            license "MIT"

            on_macos do
              on_arm do
                url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-macos-arm64.tar.gz"
                sha256 "${SHA_MACOS_ARM64}"
              end
              on_intel do
                url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-macos-amd64.tar.gz"
                sha256 "${SHA_MACOS_AMD64}"
              end
            end

            on_linux do
              on_arm do
                url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-linux-arm64.tar.gz"
                sha256 "${SHA_LINUX_ARM64}"
              end
              on_intel do
                url "https://github.com/${REPO}/releases/download/${TAG}/your-tool-${VERSION}-linux-amd64.tar.gz"
                sha256 "${SHA_LINUX_AMD64}"
              end
            end

            def install
              bin.install "your-tool"
            end

            test do
              assert_match version.to_s, shell_output("#{bin}/your-tool --version")
            end
          end
          FORMULA

          cd /tmp/tap
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Formula/your-tool.rb
          git commit -m "your-tool ${VERSION}"
          git push
```

### Required Secret

Create a fine-grained Personal Access Token at https://github.com/settings/tokens?type=beta with:
- Repository access: `YourOrg/homebrew-tap`
- Permissions: Contents (Read and write)

Add it as `HOMEBREW_TAP_TOKEN` in your CLI repo's secrets.

## Verification

After release:

```bash
brew install YourOrg/tap/your-tool
your-tool --version  # should match released version
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `tag already exists` | Use `--formula-only` to retry just the formula push |
| Formula push auth failure | Verify `HOMEBREW_TAP_TOKEN` has write access to the tap repo |
| `otool` shows non-system deps | Ensure all dependencies are statically linked or system frameworks |
| Linux binary not portable | Use Static Linux SDK with musl target for fully static binaries |
| `sed -i` fails on Linux CI | macOS uses `sed -i ''`, GNU sed uses `sed -i` (no empty string) |

## References

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
- [bottle :unneeded deprecation](https://github.com/orgs/Homebrew/discussions/2311)
