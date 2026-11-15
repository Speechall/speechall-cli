import ArgumentParser
import Foundation
import OpenAPIRuntime
import SpeechallAPITypes
import XCTest

@testable import SpeechallCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class AuthCommandTests: XCTestCase {
    private let longKey = "sk-test-1234567890abcd" // gitleaks:allow (fake fixture, not a real key)

    // MARK: Resolution order

    func testFlagTakesPriorityOverEnvironmentAndStore() throws {
        let store = InMemoryCredentialStore(key: "stored-key-000000")
        let resolved = try resolveAPIKeyWithSource(
            from: "flag-key",
            environment: ["SPEECHALL_API_KEY": "env-key"],
            store: store
        )
        XCTAssertEqual(resolved, ResolvedAPIKey(key: "flag-key", source: .flag))
        XCTAssertEqual(store.readCount, 0, "store must not be read when a flag is given")
    }

    func testEnvironmentTakesPriorityOverStore() throws {
        let store = InMemoryCredentialStore(key: "stored-key-000000")
        let resolved = try resolveAPIKeyWithSource(
            from: nil,
            environment: ["SPEECHALL_API_KEY": "env-key"],
            store: store
        )
        XCTAssertEqual(resolved, ResolvedAPIKey(key: "env-key", source: .environment))
        XCTAssertEqual(store.readCount, 0)
    }

    func testStoredKeyUsedWhenNoFlagOrEnvironment() throws {
        let store = InMemoryCredentialStore(key: "stored-key-000000")
        let resolved = try resolveAPIKeyWithSource(from: nil, environment: [:], store: store)
        XCTAssertEqual(resolved, ResolvedAPIKey(key: "stored-key-000000", source: .stored(location: "memory")))
    }

    func testEmptyFlagAndEnvironmentFallThrough() throws {
        let store = InMemoryCredentialStore(key: "stored-key-000000")
        let resolved = try resolveAPIKeyWithSource(
            from: "",
            environment: ["SPEECHALL_API_KEY": ""],
            store: store
        )
        XCTAssertEqual(resolved?.source, .stored(location: "memory"))
    }

    func testMissingKeyErrorMentionsAuthLogin() {
        XCTAssertThrowsError(
            try resolveRuntimeAPIKey(from: nil, environment: [:], store: InMemoryCredentialStore())
        ) { error in
            XCTAssertTrue("\(error)".contains("speechall auth login"), "\(error)")
        }
    }

    func testCommandsUseStoredKeyThroughDependencies() async throws {
        let store = InMemoryCredentialStore(key: longKey)
        let recorder = AuthRecorder()
        var dependencies = makeDependencies(store: store, recorder: recorder, environment: [:])
        dependencies.makeAPIClient = { key in
            recorder.clientKeys.append(key)
            return AuthTestAPIClient(status: .ok)
        }
        try await runModels(options: .init(), dependencies: dependencies)
        XCTAssertEqual(recorder.clientKeys, [longKey])
    }

    // MARK: Masking

    func testMaskShowsOnlyLastFourCharacters() {
        XCTAssertEqual(maskAPIKey(longKey), "****abcd")
        XCTAssertFalse(maskAPIKey(longKey).contains("1234"))
    }

    func testMaskHidesShortKeysCompletely() {
        XCTAssertEqual(maskAPIKey("abc"), "****")
        XCTAssertEqual(maskAPIKey("12345678901"), "****")
    }

    // MARK: login

    func testLoginVerifiesAndSavesKey() async throws {
        let store = InMemoryCredentialStore()
        let recorder = AuthRecorder()
        var dependencies = makeDependencies(store: store, recorder: recorder, input: "  \(longKey)\n")
        dependencies.makeAPIClient = { key in
            recorder.clientKeys.append(key)
            return AuthTestAPIClient(status: .ok)
        }

        try await runAuthLogin(dependencies: dependencies)

        XCTAssertEqual(store.key, longKey)
        XCTAssertEqual(recorder.clientKeys, [longKey])
        XCTAssertEqual(recorder.stdout, ["Saved API key ****abcd to memory."])
        XCTAssertFalse((recorder.stdout + recorder.stderr).joined().contains(longKey))
    }

    func testLoginRejectsKeyRefusedByAPI() async {
        let store = InMemoryCredentialStore()
        let recorder = AuthRecorder()
        var dependencies = makeDependencies(store: store, recorder: recorder, input: longKey)
        dependencies.makeAPIClient = { _ in AuthTestAPIClient(status: .unauthorized) }

        await assertExitFailure { try await runAuthLogin(dependencies: dependencies) }
        XCTAssertNil(store.key)
        XCTAssertTrue(recorder.stderr.joined().contains("rejected"), "\(recorder.stderr)")
    }

    func testLoginDoesNotSaveWhenVerificationIsInconclusive() async {
        let store = InMemoryCredentialStore()
        let recorder = AuthRecorder()
        var dependencies = makeDependencies(store: store, recorder: recorder, input: longKey)
        dependencies.makeAPIClient = { _ in AuthTestAPIClient(status: .serverError) }

        await assertExitFailure { try await runAuthLogin(dependencies: dependencies) }
        XCTAssertNil(store.key)
    }

    func testLoginRejectsEmptyInput() async {
        for input in [nil, "", "   \n"] as [String?] {
            let store = InMemoryCredentialStore()
            let recorder = AuthRecorder()
            let dependencies = makeDependencies(store: store, recorder: recorder, input: input)

            await assertExitFailure { try await runAuthLogin(dependencies: dependencies) }
            XCTAssertNil(store.key)
            XCTAssertTrue(recorder.clientKeys.isEmpty, "API must not be called for empty input")
        }
    }

    func testLoginTakesNoArgumentsOrOptions() {
        XCTAssertThrowsError(try Speechall.parseAsRoot(["auth", "login", longKey]))
        XCTAssertThrowsError(try Speechall.parseAsRoot(["auth", "login", "--api-key", longKey]))
    }

    // MARK: status

    func testStatusReportsSourceWithMaskedKey() throws {
        let cases: [(String?, [String: String], String)] = [
            (longKey, [:], "--api-key flag"),
            (nil, ["SPEECHALL_API_KEY": longKey], "SPEECHALL_API_KEY environment variable"),
            (nil, [:], "stored key (memory)"),
        ]
        for (option, environment, expectedSource) in cases {
            let recorder = AuthRecorder()
            let dependencies = makeDependencies(
                store: InMemoryCredentialStore(key: longKey),
                recorder: recorder,
                environment: environment
            )
            try runAuthStatus(apiKeyOption: option, dependencies: dependencies)
            XCTAssertEqual(recorder.stdout, ["API key available: ****abcd (source: \(expectedSource))"])
            XCTAssertFalse(recorder.stdout.joined().contains(longKey))
        }
    }

    func testStatusFailsWhenNoKeyAvailable() {
        let recorder = AuthRecorder()
        let dependencies = makeDependencies(store: InMemoryCredentialStore(), recorder: recorder, environment: [:])
        XCTAssertThrowsError(try runAuthStatus(apiKeyOption: nil, dependencies: dependencies)) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
        XCTAssertTrue(recorder.stdout.isEmpty)
        XCTAssertTrue(recorder.stderr.joined().contains("speechall auth login"))
    }

    // MARK: logout

    func testLogoutDeletesStoredKey() throws {
        let store = InMemoryCredentialStore(key: longKey)
        let recorder = AuthRecorder()
        try runAuthLogout(dependencies: makeDependencies(store: store, recorder: recorder, environment: [:]))
        XCTAssertNil(store.key)
        XCTAssertEqual(recorder.stdout.count, 1)
    }

    func testLogoutIsQuietWhenNothingStored() throws {
        let recorder = AuthRecorder()
        try runAuthLogout(dependencies: makeDependencies(store: InMemoryCredentialStore(), recorder: recorder, environment: [:]))
        XCTAssertTrue(recorder.stdout.isEmpty)
        XCTAssertTrue(recorder.stderr.isEmpty)
    }

    // MARK: File store (used on Linux)

    func testFileStoreRoundTripWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = FileCredentialStore.defaultFileURL(environment: ["XDG_CONFIG_HOME": root.path])
        XCTAssertEqual(fileURL.path, root.appendingPathComponent("speechall/credentials").path)

        let store = FileCredentialStore(fileURL: fileURL)
        XCTAssertNil(try store.readAPIKey())

        try store.saveAPIKey(longKey)
        XCTAssertEqual(try store.readAPIKey(), longKey)
        XCTAssertEqual(try permissions(of: fileURL.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(try permissions(of: fileURL.path), 0o600)

        try store.saveAPIKey("second-key-abcdefgh")
        XCTAssertEqual(try store.readAPIKey(), "second-key-abcdefgh")
        XCTAssertEqual(try permissions(of: fileURL.path), 0o600)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["credentials"], "temporary files must not be left behind")

        XCTAssertTrue(try store.deleteAPIKey())
        XCTAssertFalse(try store.deleteAPIKey())
        XCTAssertNil(try store.readAPIKey())
    }

    func testFileStoreDefaultPathFallsBackToHomeConfig() {
        let url = FileCredentialStore.defaultFileURL(environment: ["HOME": "/home/tester"])
        XCTAssertEqual(url.path, "/home/tester/.config/speechall/credentials")

        let relativeXDG = FileCredentialStore.defaultFileURL(environment: ["HOME": "/home/tester", "XDG_CONFIG_HOME": "relative"])
        XCTAssertEqual(relativeXDG.path, "/home/tester/.config/speechall/credentials")
    }

    // MARK: Helpers

    private func permissions(of path: String) throws -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw CredentialStoreError(description: "stat failed for \(path)")
        }
        return Int(info.st_mode) & 0o777
    }

    private func makeDependencies(
        store: InMemoryCredentialStore,
        recorder: AuthRecorder,
        environment: [String: String] = [:],
        input: String? = nil
    ) -> CommandDependencies {
        CommandDependencies(
            environment: environment,
            credentialStore: store,
            readAPIKeyInput: { input },
            makeAPIClient: { key in
                recorder.clientKeys.append(key)
                return AuthTestAPIClient(status: .ok)
            },
            writeStdout: { recorder.stdout.append($0) },
            writeStderr: { recorder.stderr.append($0) }
        )
    }

    private func assertExitFailure(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected ExitCode.failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ExitCode, .failure, file: file, line: line)
        }
    }
}

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    var key: String?
    var readCount = 0

    init(key: String? = nil) {
        self.key = key
    }

    var locationDescription: String { "memory" }

    func readAPIKey() throws -> String? {
        readCount += 1
        return key
    }

    func saveAPIKey(_ apiKey: String) throws {
        key = apiKey
    }

    func deleteAPIKey() throws -> Bool {
        defer { key = nil }
        return key != nil
    }
}

private final class AuthRecorder: @unchecked Sendable {
    var clientKeys: [String] = []
    var stdout: [String] = []
    var stderr: [String] = []
}

private struct AuthTestAPIClient: APIProtocol {
    enum Status: Sendable {
        case ok
        case unauthorized
        case serverError
    }

    var status: Status

    func listSpeechToTextModels(_ input: Operations.listSpeechToTextModels.Input) async throws -> Operations.listSpeechToTextModels.Output {
        switch status {
        case .ok:
            return .ok(.init(body: .json([])))
        case .unauthorized:
            return .unauthorized(.init(body: .json(.init(message: "Invalid API key"))))
        case .serverError:
            return .undocumented(statusCode: 500, .init())
        }
    }

    func transcribe(_ input: Operations.transcribe.Input) async throws -> Operations.transcribe.Output {
        throw CredentialStoreError(description: "unexpected transcribe call")
    }

    func transcribeRemote(_ input: Operations.transcribeRemote.Input) async throws -> Operations.transcribeRemote.Output {
        throw CredentialStoreError(description: "unexpected call")
    }

    func openaiCompatibleCreateTranscription(_ input: Operations.openaiCompatibleCreateTranscription.Input) async throws -> Operations.openaiCompatibleCreateTranscription.Output {
        throw CredentialStoreError(description: "unexpected call")
    }

    func openaiCompatibleCreateTranslation(_ input: Operations.openaiCompatibleCreateTranslation.Input) async throws -> Operations.openaiCompatibleCreateTranslation.Output {
        throw CredentialStoreError(description: "unexpected call")
    }

    func createReplacementRuleset(_ input: Operations.createReplacementRuleset.Input) async throws -> Operations.createReplacementRuleset.Output {
        throw CredentialStoreError(description: "unexpected call")
    }
}
