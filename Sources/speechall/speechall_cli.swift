import ArgumentParser
import Foundation
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import SpeechallAPI
import SpeechallAPITypes

extension Components.Schemas.TranscriptionModelIdentifier: @retroactive ExpressibleByArgument {}
extension Components.Schemas.TranscriptLanguageCode: @retroactive ExpressibleByArgument {}
extension Components.Schemas.TranscriptOutputFormat: @retroactive ExpressibleByArgument {}
extension Components.Schemas.TranscriptionProvider: @retroactive ExpressibleByArgument {}

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
        version: "0.1.0",
        subcommands: [Transcribe.self, Models.self],
        defaultSubcommand: Transcribe.self
    )
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe audio and video files using the Speechall API."
    )

    @Argument(help: "Path to an audio or video file.", completion: .file())
    var file: String

    @Option(help: "STT model.")
    var model: Components.Schemas.TranscriptionModelIdentifier = .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe

    @Option(help: "Language code.")
    var language: Components.Schemas.TranscriptLanguageCode?

    @Option(help: "Output format.")
    var outputFormat: Components.Schemas.TranscriptOutputFormat?

    @Option(help: "Replacement ruleset UUID.")
    var rulesetId: String?

    @Flag(help: "Enable speaker diarization.")
    var diarization: Bool = false

    @Option(help: "Expected number of speakers (with --diarization).")
    var speakersExpected: Int?

    @Flag(name: .customLong("no-punctuation"), help: "Disable automatic punctuation.")
    var noPunctuation: Bool = false

    @Option(help: "Model temperature (0.0-1.0).")
    var temperature: Double?

    @Option(help: "Text prompt to guide model style.")
    var initialPrompt: String?

    @Option(parsing: .singleValue, help: "Terms to boost recognition (repeatable).")
    var customVocabulary: [String] = []

    @Option(help: "Speechall API key (env: SPEECHALL_API_KEY).")
    var apiKey: String?

    mutating func run() async throws {
        let fileUrl = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw ValidationError("File not found: \(fileUrl.path)")
        }

        let resolvedKey = try resolveAPIKey(from: apiKey)
        let body = try await prepareAudioBody(from: fileUrl)

        let query = Operations.transcribe.Input.Query(
            model: model,
            language: language,
            output_format: outputFormat,
            ruleset_id: rulesetId,
            punctuation: noPunctuation ? false : nil,
            diarization: diarization ? true : nil,
            initial_prompt: initialPrompt,
            temperature: temperature,
            speakers_expected: speakersExpected,
            custom_vocabulary: customVocabulary.isEmpty ? nil : customVocabulary
        )

        let client = createClient(apiKey: resolvedKey)
        let response = try await client.transcribe(.init(query: query, body: .audio__ast_(body)))

        switch response {
        case .ok(let ok):
            try await handleOkResponse(ok)
        case .badRequest(let error):
            try await exitWithError(statusCode: 400, body: error.body)
        case .unauthorized(let error):
            try await exitWithError(statusCode: 401, body: error.body)
        case .code402(let error):
            try await exitWithError(statusCode: 402, body: error.body)
        case .notFound(let error):
            try await exitWithError(statusCode: 404, body: error.body)
        case .tooManyRequests(let error):
            try await exitWithRateLimitError(body: error.body, retryAfter: error.headers.Retry_hyphen_After)
        case .internalServerError(let error):
            try await exitWithError(statusCode: 500, body: error.body)
        case .serviceUnavailable(let error):
            try await exitWithError(statusCode: 503, body: error.body)
        case .gatewayTimeout(let error):
            try await exitWithError(statusCode: 504, body: error.body)
        case .undocumented(let statusCode, let payload):
            let message = try await extractUndocumentedMessage(from: payload)
            writeError("HTTP \(statusCode): \(message)")
            throw ExitCode.failure
        }
    }

    private func handleOkResponse(_ ok: Components.Responses.DualFormatTranscriptionResponse) async throws {
        switch ok.body {
        case .plainText(let httpBody):
            let buffer = try await httpBody.collect(upTo: 100_000_000, using: .init())
            print(String(buffer: buffer))
        case .json(let transcription):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            switch transcription {
            case .TranscriptionDetailed(let detailed):
                print(String(data: try encoder.encode(detailed), encoding: .utf8) ?? "")
            case .TranscriptionOnlyText(let text):
                print(String(data: try encoder.encode(text), encoding: .utf8) ?? "")
            }
        }
    }
}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available speech-to-text models and their capabilities.",
        discussion: """
            Outputs JSON to stdout. All filters are combined with AND logic. \
            Unavailable models are always excluded.
            """
    )

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

    mutating func run() async throws {
        let resolvedKey = try resolveAPIKey(from: apiKey)
        let client = createClient(apiKey: resolvedKey)
        let response = try await client.listSpeechToTextModels(.init())

        switch response {
        case .ok(let ok):
            var models = try ok.body.json
            models = models.filter { $0.is_available }

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
            print(String(data: data, encoding: .utf8) ?? "")
        case .badRequest(let error):
            try await exitWithError(statusCode: 400, body: error.body)
        case .unauthorized(let error):
            try await exitWithError(statusCode: 401, body: error.body)
        case .code402(let error):
            try await exitWithError(statusCode: 402, body: error.body)
        case .notFound(let error):
            try await exitWithError(statusCode: 404, body: error.body)
        case .tooManyRequests(let error):
            try await exitWithRateLimitError(body: error.body, retryAfter: error.headers.Retry_hyphen_After)
        case .internalServerError(let error):
            try await exitWithError(statusCode: 500, body: error.body)
        case .serviceUnavailable(let error):
            try await exitWithError(statusCode: 503, body: error.body)
        case .gatewayTimeout(let error):
            try await exitWithError(statusCode: 504, body: error.body)
        case .undocumented(let statusCode, let payload):
            let message = try await extractUndocumentedMessage(from: payload)
            writeError("HTTP \(statusCode): \(message)")
            throw ExitCode.failure
        }
    }
}

func resolveAPIKey(from option: String?) throws -> String {
    let resolved = option ?? ProcessInfo.processInfo.environment["SPEECHALL_API_KEY"]
    guard let key = resolved, !key.isEmpty else {
        throw ValidationError("API key required. Use --api-key or set SPEECHALL_API_KEY.")
    }
    return key
}

func createClient(apiKey: String) -> Client {
    Client(
        serverURL: URL(string: "https://api.speechall.com/v1")!,
        transport: AsyncHTTPClientTransport(),
        middlewares: [AuthenticationMiddleware(apiKey: apiKey)]
    )
}

func modelSupportsLanguage(
    _ model: Components.Schemas.SpeechToTextModel,
    language: String
) -> Bool {
    guard let supported = model.supported_languages else { return false }
    let query = language.lowercased()
    return supported.contains { code in
        let lower = code.lowercased()
        if lower == query { return true }
        if !query.contains("-"), lower.hasPrefix(query + "-") { return true }
        return false
    }
}

func exitWithError(statusCode: Int, body: Components.Responses.BadRequest.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.Unauthorized.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.PaymentRequired.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.NotFound.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.InternalServerError.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.ServiceUnavailable.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(statusCode: Int, body: Components.Responses.GatewayTimeout.Body) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    writeError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithRateLimitError(
    body: Components.Responses.TooManyRequests.Body,
    retryAfter: Int?
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    let suffix = retryAfter.map { " (retry after \($0)s)" } ?? ""
    writeError("HTTP 429: \(message)\(suffix)")
    throw ExitCode.failure
}

func extractErrorMessage(from body: Components.Responses.BadRequest.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.Unauthorized.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.PaymentRequired.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.NotFound.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.ServiceUnavailable.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.TooManyRequests.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.GatewayTimeout.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    }
}

func extractErrorMessage(from body: Components.Responses.InternalServerError.Body) async throws -> String {
    switch body {
    case .json(let error):
        return error.message
    case .plainText(let httpBody):
        let buffer = try await httpBody.collect(upTo: 100_000_000, using: .init())
        return String(buffer: buffer)
    }
}

func extractUndocumentedMessage(from payload: UndocumentedPayload) async throws -> String {
    guard let body = payload.body else {
        return "Undocumented response"
    }
    let buffer = try await body.collect(upTo: 100_000_000, using: .init())
    let text = String(buffer: buffer)
    return text.isEmpty ? "Undocumented response" : text
}

func writeError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
