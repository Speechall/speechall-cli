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

## Architecture

Single-file CLI (`Sources/speechall/speechall_cli.swift`) built on:

- **swift-argument-parser** — `AsyncParsableCommand` for CLI parsing
- **speechall-swift-sdk** (local path dependency) — provides the OpenAPI-generated `Client`, types (`Components.Schemas.*`, `Operations.transcribe.*`), `AuthenticationMiddleware`, and `prepareAudioBody(from:)` for streaming file uploads
- **swift-openapi-runtime** + **swift-openapi-async-http-client** — HTTP transport layer

The CLI wraps the SDK's raw `Client.transcribe()` endpoint. Every query parameter from `Operations.transcribe.Input.Query` maps 1:1 to a CLI option. The SDK enum types (`TranscriptionModelIdentifier`, `TranscriptLanguageCode`, `TranscriptOutputFormat`) are extended with `@retroactive ExpressibleByArgument` so ArgumentParser validates values at parse time and lists all valid values in `--help`.

The SDK is a local path dependency at `../speechall-swift-sdk/`. Its types are auto-generated from an OpenAPI spec via swift-openapi-generator. When making changes that need new SDK types or visibility changes, edit the SDK repo directly and run `swift package resolve` here.

## Key Patterns

- `prepareAudioBody(from:)` (from SpeechallAPI module) handles file streaming and video-to-audio extraction (macOS only via AVFoundation; Linux TODO).
- Error responses use overloaded `handleError(statusCode:body:)` and `extractErrorMessage(from:)` methods because the OpenAPI-generated response types don't share a common protocol.
- API key resolution: `--api-key` flag takes priority over `SPEECHALL_API_KEY` environment variable.
- Boolean API parameters use nil-signaling: `--diarization` sends `true`, `--no-punctuation` sends `false`, absence sends `nil` (API default).
