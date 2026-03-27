import Foundation
import OpenAPIRuntime
import SpeechallAPITypes
import XCTest

@testable import SpeechallCLI

final class CommandAPISmokeTests: XCTestCase {
    func testModelsSubcommandDefaultAPICallSucceeds() async throws {
        let recorder = CommandRecorder()
        let client = TestAPIClient(
            listSpeechToTextModelsHandler: { input in
                recorder.listModelsInputs.append(input)
                return .ok(
                    .init(
                        body: .json([
                            Self.availableModel(),
                            Self.unavailableModel(),
                        ])
                    )
                )
            }
        )

        try await runModels(
            options: .init(),
            dependencies: Self.makeDependencies(recorder: recorder, client: client)
        )

        XCTAssertEqual(recorder.resolvedAPIKeyOptions, [nil])
        XCTAssertEqual(recorder.createdClientKeys, ["test-api-key"])
        XCTAssertEqual(recorder.listModelsInputs.count, 1)
        XCTAssertTrue(recorder.transcribeInputs.isEmpty)
        XCTAssertTrue(recorder.stderrMessages.isEmpty)

        let output = try XCTUnwrap(recorder.stdoutMessages.onlyElement)
        let models = try JSONDecoder().decode([Components.Schemas.SpeechToTextModel].self, from: Data(output.utf8))
        XCTAssertEqual(models.map(\.id), [.openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe])
    }

    func testTranscribeSubcommandDefaultAPICallSucceeds() async throws {
        let recorder = CommandRecorder()
        let client = TestAPIClient(
            transcribeHandler: { input in
                recorder.transcribeInputs.append(input)
                return .ok(
                    .init(
                        body: .plainText(Self.httpBody("transcribed text"))
                    )
                )
            }
        )

        let audioURL = try Self.makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try await runTranscribe(
            options: .init(file: audioURL.path),
            dependencies: Self.makeDependencies(recorder: recorder, client: client)
        )

        XCTAssertEqual(recorder.resolvedAPIKeyOptions, [nil])
        XCTAssertEqual(recorder.createdClientKeys, ["test-api-key"])
        XCTAssertEqual(recorder.listModelsInputs.count, 0)
        XCTAssertEqual(recorder.transcribeInputs.count, 1)
        XCTAssertTrue(recorder.stderrMessages.isEmpty)
        XCTAssertEqual(recorder.stdoutMessages, ["transcribed text"])

        let input = try XCTUnwrap(recorder.transcribeInputs.onlyElement)
        XCTAssertEqual(input.query.model, .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe)
        XCTAssertNil(input.query.language)
        XCTAssertNil(input.query.output_format)
        XCTAssertNil(input.query.ruleset_id)
        XCTAssertNil(input.query.punctuation)
        XCTAssertNil(input.query.diarization)
        XCTAssertNil(input.query.initial_prompt)
        XCTAssertNil(input.query.temperature)
        XCTAssertNil(input.query.speakers_expected)
        XCTAssertNil(input.query.custom_vocabulary)

        let bodyData = try await Self.data(from: input.body)
        XCTAssertEqual(bodyData, Data("fake-audio".utf8))
    }

    private static func makeDependencies(
        recorder: CommandRecorder,
        client: TestAPIClient
    ) -> CommandDependencies {
        CommandDependencies(
            resolveAPIKey: { option in
                recorder.resolvedAPIKeyOptions.append(option)
                return "test-api-key"
            },
            makeAPIClient: { apiKey in
                recorder.createdClientKeys.append(apiKey)
                return client
            },
            loadAudioBody: { url in
                let data = try Data(contentsOf: url)
                return HTTPBody(data, length: .known(Int64(data.count)))
            },
            writeStdout: { message in
                recorder.stdoutMessages.append(message)
            },
            writeStderr: { message in
                recorder.stderrMessages.append(message)
            }
        )
    }

    private static func availableModel() -> Components.Schemas.SpeechToTextModel {
        .init(
            id: .openai_period_gpt_hyphen_4o_hyphen_mini_hyphen_transcribe,
            display_name: "GPT-4o mini transcribe",
            provider: .openai,
            is_available: true,
            supports_srt: true,
            supports_vtt: true
        )
    }

    private static func unavailableModel() -> Components.Schemas.SpeechToTextModel {
        .init(
            id: .deepgram_period_nova_hyphen_2,
            display_name: "Nova-2",
            provider: .deepgram,
            is_available: false,
            supports_srt: true,
            supports_vtt: true
        )
    }

    private static func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("fake-audio".utf8).write(to: url)
        return url
    }

    private static func httpBody(_ string: String) -> HTTPBody {
        let data = Data(string.utf8)
        return HTTPBody(data, length: .known(Int64(data.count)))
    }

    private static func data(from body: Operations.transcribe.Input.Body) async throws -> Data {
        switch body {
        case .audio__ast_(let httpBody):
            let buffer = try await httpBody.collect(upTo: 1_000_000, using: .init())
            return Data(buffer.readableBytesView)
        }
    }
}

private final class CommandRecorder: @unchecked Sendable {
    var resolvedAPIKeyOptions: [String?] = []
    var createdClientKeys: [String] = []
    var listModelsInputs: [Operations.listSpeechToTextModels.Input] = []
    var transcribeInputs: [Operations.transcribe.Input] = []
    var stdoutMessages: [String] = []
    var stderrMessages: [String] = []
}

private struct TestAPIClient: APIProtocol, Sendable {
    var transcribeHandler: @Sendable (Operations.transcribe.Input) async throws -> Operations.transcribe.Output
    var transcribeRemoteHandler: @Sendable (Operations.transcribeRemote.Input) async throws -> Operations.transcribeRemote.Output
    var openaiCompatibleCreateTranscriptionHandler: @Sendable (Operations.openaiCompatibleCreateTranscription.Input) async throws -> Operations.openaiCompatibleCreateTranscription.Output
    var openaiCompatibleCreateTranslationHandler: @Sendable (Operations.openaiCompatibleCreateTranslation.Input) async throws -> Operations.openaiCompatibleCreateTranslation.Output
    var createReplacementRulesetHandler: @Sendable (Operations.createReplacementRuleset.Input) async throws -> Operations.createReplacementRuleset.Output
    var listSpeechToTextModelsHandler: @Sendable (Operations.listSpeechToTextModels.Input) async throws -> Operations.listSpeechToTextModels.Output

    init(
        transcribeHandler: @escaping @Sendable (Operations.transcribe.Input) async throws -> Operations.transcribe.Output = { _ in
            throw TestAPIClientError.unhandled("transcribe")
        },
        transcribeRemoteHandler: @escaping @Sendable (Operations.transcribeRemote.Input) async throws -> Operations.transcribeRemote.Output = { _ in
            throw TestAPIClientError.unhandled("transcribeRemote")
        },
        openaiCompatibleCreateTranscriptionHandler: @escaping @Sendable (Operations.openaiCompatibleCreateTranscription.Input) async throws -> Operations.openaiCompatibleCreateTranscription.Output = { _ in
            throw TestAPIClientError.unhandled("openaiCompatibleCreateTranscription")
        },
        openaiCompatibleCreateTranslationHandler: @escaping @Sendable (Operations.openaiCompatibleCreateTranslation.Input) async throws -> Operations.openaiCompatibleCreateTranslation.Output = { _ in
            throw TestAPIClientError.unhandled("openaiCompatibleCreateTranslation")
        },
        createReplacementRulesetHandler: @escaping @Sendable (Operations.createReplacementRuleset.Input) async throws -> Operations.createReplacementRuleset.Output = { _ in
            throw TestAPIClientError.unhandled("createReplacementRuleset")
        },
        listSpeechToTextModelsHandler: @escaping @Sendable (Operations.listSpeechToTextModels.Input) async throws -> Operations.listSpeechToTextModels.Output = { _ in
            throw TestAPIClientError.unhandled("listSpeechToTextModels")
        }
    ) {
        self.transcribeHandler = transcribeHandler
        self.transcribeRemoteHandler = transcribeRemoteHandler
        self.openaiCompatibleCreateTranscriptionHandler = openaiCompatibleCreateTranscriptionHandler
        self.openaiCompatibleCreateTranslationHandler = openaiCompatibleCreateTranslationHandler
        self.createReplacementRulesetHandler = createReplacementRulesetHandler
        self.listSpeechToTextModelsHandler = listSpeechToTextModelsHandler
    }

    func transcribe(_ input: Operations.transcribe.Input) async throws -> Operations.transcribe.Output {
        try await transcribeHandler(input)
    }

    func transcribeRemote(_ input: Operations.transcribeRemote.Input) async throws -> Operations.transcribeRemote.Output {
        try await transcribeRemoteHandler(input)
    }

    func openaiCompatibleCreateTranscription(_ input: Operations.openaiCompatibleCreateTranscription.Input) async throws -> Operations.openaiCompatibleCreateTranscription.Output {
        try await openaiCompatibleCreateTranscriptionHandler(input)
    }

    func openaiCompatibleCreateTranslation(_ input: Operations.openaiCompatibleCreateTranslation.Input) async throws -> Operations.openaiCompatibleCreateTranslation.Output {
        try await openaiCompatibleCreateTranslationHandler(input)
    }

    func createReplacementRuleset(_ input: Operations.createReplacementRuleset.Input) async throws -> Operations.createReplacementRuleset.Output {
        try await createReplacementRulesetHandler(input)
    }

    func listSpeechToTextModels(_ input: Operations.listSpeechToTextModels.Input) async throws -> Operations.listSpeechToTextModels.Output {
        try await listSpeechToTextModelsHandler(input)
    }
}

private enum TestAPIClientError: Error {
    case unhandled(String)
}

private extension Array {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}
