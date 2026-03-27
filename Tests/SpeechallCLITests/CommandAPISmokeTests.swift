import ArgumentParser
import Foundation
import OpenAPIRuntime
import SpeechallAPITypes
import XCTest

@testable import SpeechallCLI

final class CommandAPISmokeTests: XCTestCase {
    func testEveryConfiguredSubcommandDefaultAPICallSucceeds() async throws {
        let configuredSubcommands = Self.collectConfiguredSubcommands(from: Speechall.self)
        XCTAssertFalse(configuredSubcommands.isEmpty)

        for commandType in configuredSubcommands {
            guard let smokeTestableType = commandType as? any DefaultAPISmokeTestableCommand.Type else {
                XCTFail("Configured subcommand \(commandType) must conform to DefaultAPISmokeTestableCommand")
                continue
            }

            let plan = try smokeTestableType.makeDefaultAPISmokePlan()
            let recorder = CommandRecorder()
            let client = Self.makeClient(for: plan.expectation, recorder: recorder)
            defer { plan.cleanup() }

            try await plan.run(Self.makeDependencies(recorder: recorder, client: client))

            XCTAssertEqual(recorder.resolvedAPIKeyOptions, [nil])
            XCTAssertEqual(recorder.createdClientKeys, ["test-api-key"])
            XCTAssertTrue(recorder.stderrMessages.isEmpty)

            try await Self.verify(plan.expectation, recorder: recorder)
        }
    }

    private static func collectConfiguredSubcommands(from commandType: ParsableCommand.Type) -> [ParsableCommand.Type] {
        commandType.configuration.subcommands.flatMap { subcommand in
            [subcommand] + collectConfiguredSubcommands(from: subcommand)
        }
    }

    private static func makeClient(
        for expectation: DefaultAPISmokeExpectation,
        recorder: CommandRecorder
    ) -> TestAPIClient {
        switch expectation {
        case .transcribe(let transcribeExpectation):
            return TestAPIClient(
                transcribeHandler: { input in
                    recorder.transcribeInputs.append(input)
                    return .ok(
                        .init(
                            body: .plainText(httpBody(transcribeExpectation.stdout))
                        )
                    )
                }
            )
        case .listModels(let listModelsExpectation):
            return TestAPIClient(
                listSpeechToTextModelsHandler: { input in
                    recorder.listModelsInputs.append(input)
                    return .ok(
                        .init(
                            body: .json(listModelsExpectation.responseModels)
                        )
                    )
                }
            )
        }
    }

    private static func verify(
        _ expectation: DefaultAPISmokeExpectation,
        recorder: CommandRecorder
    ) async throws {
        switch expectation {
        case .transcribe(let transcribeExpectation):
            XCTAssertEqual(recorder.listModelsInputs.count, 0)
            XCTAssertEqual(recorder.transcribeInputs.count, 1)
            XCTAssertEqual(recorder.stdoutMessages, [transcribeExpectation.stdout])

            let input = try XCTUnwrap(recorder.transcribeInputs.onlyElement)
            XCTAssertEqual(input.query.model, transcribeExpectation.query.model)
            XCTAssertEqual(input.query.language, transcribeExpectation.query.language)
            XCTAssertEqual(input.query.output_format, transcribeExpectation.query.output_format)
            XCTAssertEqual(input.query.ruleset_id, transcribeExpectation.query.ruleset_id)
            XCTAssertEqual(input.query.punctuation, transcribeExpectation.query.punctuation)
            XCTAssertEqual(input.query.diarization, transcribeExpectation.query.diarization)
            XCTAssertEqual(input.query.initial_prompt, transcribeExpectation.query.initial_prompt)
            XCTAssertEqual(input.query.temperature, transcribeExpectation.query.temperature)
            XCTAssertEqual(input.query.speakers_expected, transcribeExpectation.query.speakers_expected)
            XCTAssertEqual(input.query.custom_vocabulary, transcribeExpectation.query.custom_vocabulary)

            let bodyData = try await data(from: input.body)
            XCTAssertEqual(bodyData, transcribeExpectation.bodyData)

        case .listModels(let listModelsExpectation):
            XCTAssertEqual(recorder.listModelsInputs.count, 1)
            XCTAssertTrue(recorder.transcribeInputs.isEmpty)

            let output = try XCTUnwrap(recorder.stdoutMessages.onlyElement)
            let models = try JSONDecoder().decode([Components.Schemas.SpeechToTextModel].self, from: Data(output.utf8))
            XCTAssertEqual(models, listModelsExpectation.expectedOutputModels)
        }
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
