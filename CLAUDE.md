# CLAUDE.md

## Build & Run

```bash
swift build                          # build
swift run speechall --help           # run with help
swift run speechall audio.wav        # transcribe a file
swift package resolve                # resolve dependencies after Package.swift changes
```

After any implementation change, run `swift build` and fix compiler errors before finishing.

No tests exist in this repo yet.

## Release Binaries

All build scripts output stripped binaries to `output/`.

### Linux (static, musl-based — runs on any distro)

Requires only Docker. Nothing else needs to be installed locally.

```bash
./build-linux.sh
```

- Uses `Dockerfile` to cross-compile inside a `swift:6.2.3` container with the Static Linux SDK (`x86_64-swift-linux-musl` and `aarch64-swift-linux-musl`).
- Produces `output/speechall-linux-amd64` and `output/speechall-linux-arm64`.
- Binaries are stripped with cross-architecture `binutils` (`x86_64-linux-gnu-strip`, `aarch64-linux-gnu-strip`) since `llvm-strip` is not in the Swift Docker image.
- Smoke-tested in a `fedora` container (glibc-based, no Swift installed) for each platform.
- Docker layer caching: `Package.swift` + `Package.resolved` are copied before source code so dependency resolution is cached across source-only changes.

### macOS

Requires Xcode / Swift toolchain on the host.

```bash
./build-macos.sh
```

- Builds with `swift build -c release --arch arm64` and `--arch x86_64`.
- Creates a universal (fat) binary via `lipo`.
- Produces `output/speechall-macos-arm64`, `output/speechall-macos-amd64`, and `output/speechall-macos-universal`.
- Stripped with the native `strip` command.

### Updating the Swift / SDK version

The Dockerfile pins `swift:6.2.3` and the matching Static Linux SDK. To bump:
1. Change the `FROM swift:<version>` line.
2. Update the `swift sdk install` URL and `--checksum` from https://www.swift.org/install/linux/ (Static Linux SDK section).
3. The Swift toolchain version must exactly match the SDK version.

## Architecture

Single-file CLI (`Sources/speechall/speechall_cli.swift`) built on:

- **swift-argument-parser** — `AsyncParsableCommand` for CLI parsing
- **speechall-swift-sdk** (remote GitHub dependency, `main` branch) — provides the OpenAPI-generated `Client`, types (`Components.Schemas.*`, `Operations.transcribe.*`), `AuthenticationMiddleware`, and `prepareAudioBody(from:)` for streaming file uploads
- **swift-openapi-runtime** + **swift-openapi-async-http-client** — HTTP transport layer

The CLI wraps the SDK's raw `Client.transcribe()` endpoint. Every query parameter from `Operations.transcribe.Input.Query` maps 1:1 to a CLI option. The SDK enum types (`TranscriptionModelIdentifier`, `TranscriptLanguageCode`, `TranscriptOutputFormat`) are extended with `@retroactive ExpressibleByArgument` so ArgumentParser validates values at parse time and lists all valid values in `--help`.

The SDK is a remote GitHub dependency (`https://github.com/Speechall/speechall-swift-sdk`, `main` branch). Its types are auto-generated from an OpenAPI spec via swift-openapi-generator.

## Key Patterns

- `prepareAudioBody(from:)` (from SpeechallAPI module) handles file streaming and video-to-audio extraction (macOS only via AVFoundation; Linux falls back to returning the URL as-is).
- Error responses use overloaded `handleError(statusCode:body:)` and `extractErrorMessage(from:)` methods because the OpenAPI-generated response types don't share a common protocol.
- API key resolution: `--api-key` flag takes priority over `SPEECHALL_API_KEY` environment variable.
- Boolean API parameters use nil-signaling: `--diarization` sends `true`, `--no-punctuation` sends `false`, absence sends `nil` (API default).
