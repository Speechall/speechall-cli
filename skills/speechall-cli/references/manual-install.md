# Manual Install

Download the pre-built binary from GitHub releases. Available for macOS (arm64, amd64) and Linux (arm64, amd64).

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$OS" == "darwin" ]] && OS="macos"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

VERSION="0.1.0"  # check https://github.com/Speechall/speechall-cli/releases for latest
curl -fsSL "https://github.com/Speechall/speechall-cli/releases/download/v${VERSION}/speechall-${VERSION}-${OS}-${ARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin
chmod +x /usr/local/bin/speechall
```

Verify: `speechall --version`

Release archive naming convention: `speechall-<version>-<os>-<arch>.tar.gz`
- OS: `macos`, `linux`
- Arch: `arm64`, `amd64`
