# Plan: `speechall models` subcommand

## Goal

Add a `models` subcommand so users (primarily AI coding agents) can browse available STT models and pick one based on attributes (provider, cost, features, languages) — without leaving the terminal or consulting external docs.

An AI agent should be able to answer questions like:
- "Which models support diarization?" → `speechall models --diarization`
- "Which models support Turkish?" → `speechall models --language tr`
- "Cheapest Deepgram model with SRT support?" → `speechall models --provider deepgram --srt | jq 'sort_by(.cost_per_second_usd) | .[0].id'`

## CLI Interface

### Command hierarchy change

Currently `Speechall` is a flat `AsyncParsableCommand` that transcribes directly. Restructure into subcommands with `transcribe` as the default:

```
speechall <file> [options]           # still works (default subcommand)
speechall transcribe <file> [opts]   # explicit form
speechall models [opts]              # new: list models
```

### `models` subcommand usage

```
OVERVIEW: List available speech-to-text models and their capabilities.

  Outputs JSON to stdout. All filters are combined with AND logic.
  Unavailable models are always excluded.

USAGE: speechall models [--provider <provider>] [--language <code>]
         [--diarization] [--srt] [--vtt] [--punctuation] [--streamable]
         [--vocabulary] [--api-key <key>]

OPTIONS:
  --provider <provider>    Filter by provider.
                           (values: amazon, assemblyai, azure, cloudflare,
                           deepgram, elevenlabs, falai, fireworksai, gemini,
                           gladia, google, groq, ibm, mistral, openai,
                           revai, speechmatics)
  --language <code>        Filter by supported language. Matches primary
                           language tag: --language tr matches tr, tr-TR,
                           tr-CY. Exact BCP 47 codes also work (en-US).
  --diarization            Only models that support speaker diarization.
  --srt                    Only models that support SRT subtitle output.
  --vtt                    Only models that support VTT subtitle output.
  --punctuation            Only models that support automatic punctuation.
  --streamable             Only models that support real-time streaming.
  --vocabulary             Only models that support custom vocabulary.
  --api-key <key>          Speechall API key (env: SPEECHALL_API_KEY).
  -h, --help               Show help information.
```

### Output (JSON)

The output is JSON — optimized for AI coding agents who parse structured data. The `[SpeechToTextModel]` array is re-encoded as pretty-printed JSON with all fields. Unavailable models (`is_available == false`) are excluded from the output entirely.

### Example workflows

```bash
# All available models
speechall models

# Models from a specific provider
speechall models --provider deepgram

# Models that support Turkish (matches tr, tr-TR, etc.)
speechall models --language tr

# Models with diarization and SRT
speechall models --diarization --srt

# Cheapest model supporting Turkish with diarization
speechall models --language tr --diarization | jq 'sort_by(.cost_per_second_usd) | .[0]'

# All streamable models from OpenAI or Deepgram
speechall models --provider openai --streamable
speechall models --provider deepgram --streamable
```

All filters are AND — every flag/option narrows the result set further.

## Implementation

### Step 0: Extract shared helpers

Before adding the new subcommand, extract reusable logic from the current `Speechall` struct into free functions. This avoids duplicating ~120 lines of API key resolution, client creation, and error handling across `Transcribe` and `Models`.

```swift
// --- Shared helpers (free functions at file scope) ---

/// Resolves API key from explicit option or SPEECHALL_API_KEY environment variable.
func resolveAPIKey(from option: String?) throws -> String {
    let resolved = option ?? ProcessInfo.processInfo.environment["SPEECHALL_API_KEY"]
    guard let key = resolved, !key.isEmpty else {
        throw ValidationError("API key required. Use --api-key or set SPEECHALL_API_KEY.")
    }
    return key
}

/// Creates an authenticated OpenAPI client.
func createClient(apiKey: String) -> Client {
    Client(
        serverURL: URL(string: "https://api.speechall.com/v1")!,
        transport: AsyncHTTPClientTransport(),
        middlewares: [AuthenticationMiddleware(apiKey: apiKey)]
    )
}

/// Writes an error message to stderr.
func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Extracts error message from various response body types and exits.
/// Each overload handles a specific generated response type.
func exitWithError(statusCode: Int, body: Components.Responses.BadRequest.Body) async throws -> Never { ... }
func exitWithError(statusCode: Int, body: Components.Responses.Unauthorized.Body) async throws -> Never { ... }
// ... one per response type, same as current but as free functions

/// Handles 429 with Retry-After header, consistent across all subcommands.
/// Mirrors the current logic at speechall_cli.swift:107-112.
func exitWithRateLimitError(
    body: Components.Responses.TooManyRequests.Body,
    retryAfter: Int?
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    let suffix = retryAfter.map { " (retry after \($0)s)" } ?? ""
    writeError("HTTP 429: \(message)\(suffix)")
    throw ExitCode.failure
}
```

This replaces the private methods currently on `Speechall`. Both `Transcribe` and `Models` call the same functions. The 429 case is a dedicated helper because it has special `Retry-After` header handling that the other error cases don't need.

### Step 1: Restructure command hierarchy

Move current `Speechall` transcription logic into a new `Transcribe` subcommand. The root `Speechall` becomes a container:

```swift
@main
struct Speechall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speechall",
        abstract: "Transcribe audio and video files using the Speechall API.",
        discussion: """
            Supported models include providers like openai, deepgram, assemblyai, \
            cloudflare, groq, elevenlabs, google, gemini, and more. \
            Use the format provider.model (e.g. deepgram.nova-2, openai.whisper-1).

            Set SPEECHALL_API_KEY environment variable or pass --api-key.
            """,
        subcommands: [Transcribe.self, Models.self],
        defaultSubcommand: Transcribe.self
    )
}
```

`Transcribe` gets the current `Speechall` body — all options and `run()`. Its `run()` calls the shared helpers instead of private methods.

### Step 2: Add `Models` subcommand

```swift
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available speech-to-text models and their capabilities.",
        discussion: """
            Outputs JSON to stdout. All filters are combined with AND logic. \
            Unavailable models are always excluded.
            """
    )

    // --- Filters ---
    @Option(help: "Filter by provider.")
    var provider: Components.Schemas.TranscriptionProvider?

    @Option(help: """
        Filter by supported language. Matches primary language tag: \
        --language tr matches tr, tr-TR, tr-CY. Exact BCP 47 codes also work (en-US).
        """)
    var language: String?

    @Flag(help: "Only models that support speaker diarization.")
    var diarization: Bool = false

    @Flag(help: "Only models that support SRT subtitle output.")
    var srt: Bool = false

    @Flag(help: "Only models that support VTT subtitle output.")
    var vtt: Bool = false

    @Flag(help: "Only models that support automatic punctuation.")
    var punctuation: Bool = false

    @Flag(help: "Only models that support real-time streaming.")
    var streamable: Bool = false

    @Flag(help: "Only models that support custom vocabulary.")
    var vocabulary: Bool = false

    @Option(help: "Speechall API key (env: SPEECHALL_API_KEY).")
    var apiKey: String?
}
```

Need one more retroactive conformance:
```swift
extension Components.Schemas.TranscriptionProvider: @retroactive ExpressibleByArgument {}
```

### Step 3: Language prefix matching

The schema's `supported_languages` field contains BCP 47 codes like `"en-US"`, `"tr-TR"`, `"es"`, or `"auto"`. A user typing `--language tr` expects to find models supporting Turkish regardless of whether the API lists `"tr"` or `"tr-TR"`.

Matching logic:

```swift
/// Returns true if the model supports the given language.
/// Uses primary language tag matching: "tr" matches "tr", "tr-TR", "tr-CY".
/// Exact codes like "en-US" match only "en-US".
func modelSupportsLanguage(
    _ model: Components.Schemas.SpeechToTextModel,
    language: String
) -> Bool {
    guard let supported = model.supported_languages else { return false }
    let query = language.lowercased()
    return supported.contains { code in
        let lower = code.lowercased()
        // Exact match: "en-US" == "en-us"
        if lower == query { return true }
        // Primary tag match: "tr" matches "tr-TR" (query is prefix before hyphen)
        if !query.contains("-"), lower.hasPrefix(query + "-") { return true }
        return false
    }
}
```

This means:
- `--language tr` → matches `"tr"`, `"tr-TR"`, `"tr-CY"`
- `--language en` → matches `"en"`, `"en-US"`, `"en-GB"`, `"en-AU"`
- `--language en-US` → matches only `"en-US"` (exact)
- `--language auto` → matches `"auto"` (models with auto-detection)

### Step 4: Filtering and response handling

All filters are client-side on the fetched array. Applied sequentially with AND logic:

```swift
case .ok(let ok):
    var models = try ok.body.json

    // Always exclude unavailable models
    models = models.filter { $0.is_available }

    // Apply filters — each flag/option narrows the set
    if let provider {
        models = models.filter { $0.provider == provider }
    }
    if let language {
        models = models.filter { modelSupportsLanguage($0, language: language) }
    }
    if diarization {
        models = models.filter { $0.diarization == true }
    }
    if srt {
        models = models.filter { $0.supports_srt }
    }
    if vtt {
        models = models.filter { $0.supports_vtt }
    }
    if punctuation {
        models = models.filter { $0.punctuation == true }
    }
    if streamable {
        models = models.filter { $0.streamable == true }
    }
    if vocabulary {
        models = models.filter { $0.custom_vocabulary_support == true }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(models)
    print(String(data: data, encoding: .utf8)!)
```

### Step 5: Error handling

Uses the shared free functions from Step 0. The `listSpeechToTextModels` endpoint returns the same error response types as `transcribe` (400, 401, 402, 404, 429, 500, 503, 504, undocumented), so the same overloads apply without any new code.

### Enum values in `--help` (self-documentation)

ArgumentParser automatically lists all values for types conforming to both `CaseIterable` and `ExpressibleByArgument`. The mechanism:

1. `ExpressibleByArgument.swift:72-78` — conditional extension `where Self: CaseIterable, Self: RawRepresentable, RawValue: ExpressibleByArgument` provides `allValueStrings` returning raw value strings.
2. `HelpGenerator.swift:233` — renders them as `(values: val1, val2, ...; default: defaultVal)`.

All SDK enum types used as `@Option` types are `String`-backed `RawRepresentable` + `CaseIterable`:
- `TranscriptionModelIdentifier` (75 values) — already conforms via line 8 of current code
- `TranscriptLanguageCode` (~100 values) — already conforms via line 9
- `TranscriptOutputFormat` (5 values) — already conforms via line 10
- `TranscriptionProvider` (17 values) — new conformance in this plan

The retroactive `ExpressibleByArgument` conformance picks up the conditional default implementations because the types already satisfy the `CaseIterable + RawRepresentable<String>` constraints. **No custom `allValueStrings` override is needed.**

Verification step: after building, run `speechall models --help` and `speechall transcribe --help` and confirm all enum options show `(values: ...)` inline.

## Files to modify

| File | Action |
|------|--------|
| `Sources/speechall/speechall_cli.swift` | **Refactor**: extract shared helpers to free functions, split `Speechall` into root + `Transcribe` subcommand, add `Models` subcommand with filters, add `TranscriptionProvider` conformance |

Single file stays single file.

## Verification

1. `swift build`
2. `speechall --help` — shows subcommands: `transcribe (default)`, `models`
3. `speechall transcribe --help` — shows `(values: ...)` inline for `--model`, `--language`, `--output-format`
4. `speechall models --help` — shows `(values: ...)` inline for `--provider`, plus all filter flags
5. `speechall audio.wav` — still works (default subcommand)
6. `SPEECHALL_API_KEY=... speechall models` — JSON output, no unavailable models
7. `SPEECHALL_API_KEY=... speechall models --provider openai` — filtered by provider
8. `SPEECHALL_API_KEY=... speechall models --diarization` — only diarization-capable models
9. `SPEECHALL_API_KEY=... speechall models --language tr` — matches tr, tr-TR, etc.
10. `SPEECHALL_API_KEY=... speechall models --language en-US` — exact match only
11. `SPEECHALL_API_KEY=... speechall models --diarization --srt --provider deepgram` — combined AND filters
12. Verify no model in output has `"is_available": false`
13. Verify `speechall models --language auto` returns models with auto-detection
