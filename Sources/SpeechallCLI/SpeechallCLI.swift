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

struct CommandDependencies: Sendable {
    var resolveAPIKey: @Sendable (String?) throws -> String = { option in
        try resolveRuntimeAPIKey(from: option)
    }
    var makeAPIClient: @Sendable (String) -> any APIProtocol = { apiKey in
        makeLiveClient(apiKey: apiKey)
    }
    var loadAudioBody: @Sendable (URL) async throws -> HTTPBody = { url in
        try await prepareAudioBody(from: url)
    }
    var writeStdout: @Sendable (String) -> Void = { message in
        Swift.print(message)
    }
    var writeStderr: @Sendable (String) -> Void = writeStandardError

    static let live = Self()
}

enum CommandDependencyContext {
    @TaskLocal static var current = CommandDependencies.live
}

protocol DefaultAPISmokeTestableCommand: ParsableCommand {
    static func makeDefaultAPISmokePlan() throws -> DefaultAPISmokePlan
}

struct DefaultAPISmokePlan: Sendable {
    var run: @Sendable (CommandDependencies) async throws -> Void
    var expectation: DefaultAPISmokeExpectation
    var cleanup: @Sendable () -> Void = {}
}

enum DefaultAPISmokeExpectation: Sendable {
    case transcribe(TranscribeSmokeExpectation)
    case listModels(ListModelsSmokeExpectation)
}

struct TranscribeSmokeExpectation: Sendable {
    var stdout: String
    var bodyData: Data
    var query: Operations.transcribe.Input.Query
}

struct ListModelsSmokeExpectation: Sendable {
    var responseModels: [Components.Schemas.SpeechToTextModel]
    var expectedOutputModels: [Components.Schemas.SpeechToTextModel]
}

struct TranscribeRequestOptions: Sendable {
    var file: String
    var model: Components.Schemas.TranscriptionModelIdentifier = .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe
    var language: Components.Schemas.TranscriptLanguageCode?
    var outputFormat: Components.Schemas.TranscriptOutputFormat?
    var rulesetId: String?
    var diarization: Bool = false
    var speakersExpected: Int?
    var noPunctuation: Bool = false
    var temperature: Double?
    var initialPrompt: String?
    var customVocabulary: [String] = []
    var apiKey: String?
}

struct ModelsRequestOptions: Sendable {
    var provider: Components.Schemas.TranscriptionProvider?
    var language: String?
    var diarization: Bool = false
    var srt: Bool = false
    var vtt: Bool = false
    var punctuation: Bool = false
    var streamable: Bool = false
    var vocabulary: Bool = false
    var apiKey: String?
}

public struct Speechall: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "speechall",
        abstract: "Transcribe audio and video files using the Speechall API.",
        discussion: """
            Supported models include providers like openai, deepgram, assemblyai, \
            cloudflare, groq, elevenlabs, google, gemini, and more. \
            Use the format provider.model (e.g. deepgram.nova-2, openai.whisper-1).

            Set SPEECHALL_API_KEY environment variable or pass --api-key.
            """,
        version: "0.1.1",
        subcommands: [Transcribe.self, Models.self],
        defaultSubcommand: Transcribe.self
    )

    public init() {}
}

public struct Transcribe: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Transcribe audio and video files using the Speechall API."
    )

    @Argument(help: "Path to an audio or video file.", completion: .file())
    public var file: String

    @Option(help: "STT model.")
    public var model: Components.Schemas.TranscriptionModelIdentifier = .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe

    @Option(help: "Language code.")
    public var language: Components.Schemas.TranscriptLanguageCode?

    @Option(help: "Output format.")
    public var outputFormat: Components.Schemas.TranscriptOutputFormat?

    @Option(help: "Replacement ruleset UUID.")
    public var rulesetId: String?

    @Flag(help: "Enable speaker diarization.")
    public var diarization: Bool = false

    @Option(help: "Expected number of speakers (with --diarization).")
    public var speakersExpected: Int?

    @Flag(name: .customLong("no-punctuation"), help: "Disable automatic punctuation.")
    public var noPunctuation: Bool = false

    @Option(help: "Model temperature (0.0-1.0).")
    public var temperature: Double?

    @Option(help: "Text prompt to guide model style.")
    public var initialPrompt: String?

    @Option(parsing: .singleValue, help: "Terms to boost recognition (repeatable).")
    public var customVocabulary: [String] = []

    @Option(help: "Speechall API key (env: SPEECHALL_API_KEY).")
    public var apiKey: String?

    public init() {}

    public mutating func run() async throws {
        try await runTranscribe(
            options: .init(
                file: file,
                model: model,
                language: language,
                outputFormat: outputFormat,
                rulesetId: rulesetId,
                diarization: diarization,
                speakersExpected: speakersExpected,
                noPunctuation: noPunctuation,
                temperature: temperature,
                initialPrompt: initialPrompt,
                customVocabulary: customVocabulary,
                apiKey: apiKey
            ),
            dependencies: CommandDependencyContext.current
        )
    }
}

extension Transcribe: DefaultAPISmokeTestableCommand {
    static func makeDefaultAPISmokePlan() throws -> DefaultAPISmokePlan {
        let bodyData = Data("fake-audio".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try bodyData.write(to: fileURL)

        let options = TranscribeRequestOptions(file: fileURL.path)
        let query = Operations.transcribe.Input.Query(
            model: options.model,
            language: options.language,
            output_format: options.outputFormat,
            ruleset_id: options.rulesetId,
            punctuation: options.noPunctuation ? false : nil,
            diarization: options.diarization ? true : nil,
            initial_prompt: options.initialPrompt,
            temperature: options.temperature,
            speakers_expected: options.speakersExpected,
            custom_vocabulary: options.customVocabulary.isEmpty ? nil : options.customVocabulary
        )

        return DefaultAPISmokePlan(
            run: { dependencies in
                try await runTranscribe(options: options, dependencies: dependencies)
            },
            expectation: .transcribe(
                .init(
                    stdout: "transcribed text",
                    bodyData: bodyData,
                    query: query
                )
            ),
            cleanup: {
                try? FileManager.default.removeItem(at: fileURL)
            }
        )
    }
}

public struct Models: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "List available speech-to-text models and their capabilities.",
        discussion: """
            Outputs JSON to stdout. All filters are combined with AND logic. \
            Unavailable models are always excluded.
            """
    )

    @Option(help: "Filter by provider.")
    public var provider: Components.Schemas.TranscriptionProvider?

    @Option(help: """
        Filter by supported language. Matches primary language tag: \
        --language tr matches tr, tr-TR, tr-CY. Exact BCP 47 codes also work (en-US).
        """)
    public var language: String?

    @Flag(help: "Only models that support speaker diarization.")
    public var diarization: Bool = false

    @Flag(help: "Only models that support SRT subtitle output.")
    public var srt: Bool = false

    @Flag(help: "Only models that support VTT subtitle output.")
    public var vtt: Bool = false

    @Flag(help: "Only models that support automatic punctuation.")
    public var punctuation: Bool = false

    @Flag(help: "Only models that support real-time streaming.")
    public var streamable: Bool = false

    @Flag(help: "Only models that support custom vocabulary.")
    public var vocabulary: Bool = false

    @Option(help: "Speechall API key (env: SPEECHALL_API_KEY).")
    public var apiKey: String?

    public init() {}

    public mutating func run() async throws {
        try await runModels(
            options: .init(
                provider: provider,
                language: language,
                diarization: diarization,
                srt: srt,
                vtt: vtt,
                punctuation: punctuation,
                streamable: streamable,
                vocabulary: vocabulary,
                apiKey: apiKey
            ),
            dependencies: CommandDependencyContext.current
        )
    }
}

extension Models: DefaultAPISmokeTestableCommand {
    static func makeDefaultAPISmokePlan() throws -> DefaultAPISmokePlan {
        let availableModel = Components.Schemas.SpeechToTextModel(
            id: .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe,
            display_name: "GPT-4o mini transcribe",
            provider: .openai,
            is_available: true,
            supports_srt: true,
            supports_vtt: true
        )
        let unavailableModel = Components.Schemas.SpeechToTextModel(
            id: .deepgram_period_nova_hyphen_2,
            display_name: "Nova-2",
            provider: .deepgram,
            is_available: false,
            supports_srt: true,
            supports_vtt: true
        )

        return DefaultAPISmokePlan(
            run: { dependencies in
                try await runModels(options: .init(), dependencies: dependencies)
            },
            expectation: .listModels(
                .init(
                    responseModels: [availableModel, unavailableModel],
                    expectedOutputModels: [availableModel]
                )
            )
        )
    }
}

func runTranscribe(
    options: TranscribeRequestOptions,
    dependencies: CommandDependencies
) async throws {
    let fileUrl = URL(fileURLWithPath: options.file)
    guard FileManager.default.fileExists(atPath: fileUrl.path) else {
        throw ValidationError("File not found: \(fileUrl.path)")
    }

    let resolvedKey = try dependencies.resolveAPIKey(options.apiKey)
    let body = try await dependencies.loadAudioBody(fileUrl)

    let query = Operations.transcribe.Input.Query(
            model: options.model,
            language: options.language,
            output_format: options.outputFormat,
            ruleset_id: options.rulesetId,
            punctuation: options.noPunctuation ? false : nil,
            diarization: options.diarization ? true : nil,
            initial_prompt: options.initialPrompt,
            temperature: options.temperature,
            speakers_expected: options.speakersExpected,
            custom_vocabulary: options.customVocabulary.isEmpty ? nil : options.customVocabulary
        )

    let client = dependencies.makeAPIClient(resolvedKey)
    let response = try await client.transcribe(.init(query: query, body: .audio__ast_(body)))

    switch response {
    case .ok(let ok):
        try await handleTranscribeOkResponse(ok, dependencies: dependencies)
    case .badRequest(let error):
        try await exitWithError(statusCode: 400, body: error.body, emitError: dependencies.writeStderr)
    case .unauthorized(let error):
        try await exitWithError(statusCode: 401, body: error.body, emitError: dependencies.writeStderr)
    case .code402(let error):
        try await exitWithError(statusCode: 402, body: error.body, emitError: dependencies.writeStderr)
    case .notFound(let error):
        try await exitWithError(statusCode: 404, body: error.body, emitError: dependencies.writeStderr)
    case .tooManyRequests(let error):
        try await exitWithRateLimitError(
            body: error.body,
            retryAfter: error.headers.Retry_hyphen_After,
            emitError: dependencies.writeStderr
        )
    case .internalServerError(let error):
        try await exitWithError(statusCode: 500, body: error.body, emitError: dependencies.writeStderr)
    case .serviceUnavailable(let error):
        try await exitWithError(statusCode: 503, body: error.body, emitError: dependencies.writeStderr)
    case .gatewayTimeout(let error):
        try await exitWithError(statusCode: 504, body: error.body, emitError: dependencies.writeStderr)
    case .undocumented(let statusCode, let payload):
        let message = try await extractUndocumentedMessage(from: payload)
        dependencies.writeStderr("HTTP \(statusCode): \(message)")
        throw ExitCode.failure
    }
}

func runModels(
    options: ModelsRequestOptions,
    dependencies: CommandDependencies
) async throws {
    let resolvedKey = try dependencies.resolveAPIKey(options.apiKey)
    let client = dependencies.makeAPIClient(resolvedKey)
    let response = try await client.listSpeechToTextModels(.init())

    switch response {
    case .ok(let ok):
        var models = try ok.body.json
        models = models.filter { $0.is_available }

        if let provider = options.provider {
            models = models.filter { $0.provider == provider }
        }
        if let language = options.language {
            models = models.filter { modelSupportsLanguage($0, language: language) }
        }
        if options.diarization {
            models = models.filter { $0.diarization == true }
        }
        if options.srt {
            models = models.filter { $0.supports_srt }
        }
        if options.vtt {
            models = models.filter { $0.supports_vtt }
        }
        if options.punctuation {
            models = models.filter { $0.punctuation == true }
        }
        if options.streamable {
            models = models.filter { $0.streamable == true }
        }
        if options.vocabulary {
            models = models.filter { $0.custom_vocabulary_support == true }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(models)
        dependencies.writeStdout(String(data: data, encoding: .utf8) ?? "")
    case .badRequest(let error):
        try await exitWithError(statusCode: 400, body: error.body, emitError: dependencies.writeStderr)
    case .unauthorized(let error):
        try await exitWithError(statusCode: 401, body: error.body, emitError: dependencies.writeStderr)
    case .code402(let error):
        try await exitWithError(statusCode: 402, body: error.body, emitError: dependencies.writeStderr)
    case .notFound(let error):
        try await exitWithError(statusCode: 404, body: error.body, emitError: dependencies.writeStderr)
    case .tooManyRequests(let error):
        try await exitWithRateLimitError(
            body: error.body,
            retryAfter: error.headers.Retry_hyphen_After,
            emitError: dependencies.writeStderr
        )
    case .internalServerError(let error):
        try await exitWithError(statusCode: 500, body: error.body, emitError: dependencies.writeStderr)
    case .serviceUnavailable(let error):
        try await exitWithError(statusCode: 503, body: error.body, emitError: dependencies.writeStderr)
    case .gatewayTimeout(let error):
        try await exitWithError(statusCode: 504, body: error.body, emitError: dependencies.writeStderr)
    case .undocumented(let statusCode, let payload):
        let message = try await extractUndocumentedMessage(from: payload)
        dependencies.writeStderr("HTTP \(statusCode): \(message)")
        throw ExitCode.failure
    }
}

private func handleTranscribeOkResponse(
    _ ok: Components.Responses.DualFormatTranscriptionResponse,
    dependencies: CommandDependencies
) async throws {
    switch ok.body {
    case .plainText(let httpBody):
        let buffer = try await httpBody.collect(upTo: 100_000_000, using: .init())
        dependencies.writeStdout(String(buffer: buffer))
    case .json(let transcription):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch transcription {
        case .TranscriptionDetailed(let detailed):
            dependencies.writeStdout(String(data: try encoder.encode(detailed), encoding: .utf8) ?? "")
        case .TranscriptionOnlyText(let text):
            dependencies.writeStdout(String(data: try encoder.encode(text), encoding: .utf8) ?? "")
        }
    }
}

func resolveRuntimeAPIKey(from option: String?) throws -> String {
    let resolved = option ?? ProcessInfo.processInfo.environment["SPEECHALL_API_KEY"]
    guard let key = resolved, !key.isEmpty else {
        throw ValidationError("API key required. Use --api-key or set SPEECHALL_API_KEY.")
    }
    return key
}

func makeLiveClient(apiKey: String) -> any APIProtocol {
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

func exitWithError(
    statusCode: Int,
    body: Components.Responses.BadRequest.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.Unauthorized.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.PaymentRequired.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.NotFound.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.InternalServerError.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.ServiceUnavailable.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithError(
    statusCode: Int,
    body: Components.Responses.GatewayTimeout.Body,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    emitError("HTTP \(statusCode): \(message)")
    throw ExitCode.failure
}

func exitWithRateLimitError(
    body: Components.Responses.TooManyRequests.Body,
    retryAfter: Int?,
    emitError: @Sendable (String) -> Void
) async throws -> Never {
    let message = try await extractErrorMessage(from: body)
    let suffix = retryAfter.map { " (retry after \($0)s)" } ?? ""
    emitError("HTTP 429: \(message)\(suffix)")
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

func writeStandardError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
