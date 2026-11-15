import ArgumentParser
import Foundation
import SpeechallAPITypes

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Commands that manage credentials locally instead of resolving an API key and calling the
/// API with it. They are excluded from the generic API smoke test and covered by `AuthCommandTests`.
protocol CredentialManagementCommand: ParsableCommand {}

public struct Auth: AsyncParsableCommand, CredentialManagementCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Store, inspect, or remove the Speechall API key.",
        discussion: """
            The stored key lives in the macOS Keychain (service com.speechall.cli) or, on Linux, \
            in $XDG_CONFIG_HOME/speechall/credentials (default ~/.config/speechall/credentials, mode 0600).

            Key resolution order for API commands: --api-key, then SPEECHALL_API_KEY, then the stored key.
            """,
        subcommands: [Login.self, Status.self, Logout.self]
    )

    public init() {}

    public struct Login: AsyncParsableCommand, CredentialManagementCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Store your Speechall API key securely.",
            discussion: """
                The key is never accepted as an argument or flag, so it stays out of shell history \
                and process listings. In an interactive terminal you are prompted with input hidden. \
                Otherwise one line is read from stdin:

                  pbpaste | speechall auth login
                  speechall auth login < keyfile

                The key is verified against the Speechall API before it is saved; a rejected key is not saved.
                Create a key at https://speechall.com/console/api-keys
                """
        )

        public init() {}

        public mutating func run() async throws {
            try await runAuthLogin(dependencies: CommandDependencyContext.current)
        }
    }

    public struct Status: AsyncParsableCommand, CredentialManagementCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Show whether an API key is available and where it comes from.",
            discussion: """
                Prints the key source (--api-key flag, SPEECHALL_API_KEY, or stored key) and a masked \
                form of the key. The full key is never printed. Exits 0 when a key is available, 1 otherwise.
                """
        )

        @Option(help: "Check this key as if it were passed to another command (reported as the flag source).")
        public var apiKey: String?

        public init() {}

        public mutating func run() async throws {
            try runAuthStatus(apiKeyOption: apiKey, dependencies: CommandDependencyContext.current)
        }
    }

    public struct Logout: AsyncParsableCommand, CredentialManagementCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Delete the stored API key.",
            discussion: "Succeeds without output if no key is stored. Does not affect SPEECHALL_API_KEY."
        )

        public init() {}

        public mutating func run() async throws {
            try runAuthLogout(dependencies: CommandDependencyContext.current)
        }
    }
}

// MARK: - Command implementations

func runAuthLogin(dependencies: CommandDependencies) async throws {
    let input: String?
    do {
        input = try dependencies.readAPIKeyInput()
    } catch {
        dependencies.writeStderr("Could not read the API key: \(error)")
        throw ExitCode.failure
    }

    let key = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
        dependencies.writeStderr("No API key provided. Nothing was saved.")
        throw ExitCode.failure
    }
    guard !key.contains(where: \.isWhitespace) else {
        dependencies.writeStderr("The API key must be a single line without spaces. Nothing was saved.")
        throw ExitCode.failure
    }

    try await verifyAPIKey(key, dependencies: dependencies)

    do {
        try dependencies.credentialStore.saveAPIKey(key)
    } catch {
        dependencies.writeStderr("\(error)")
        throw ExitCode.failure
    }

    dependencies.writeStdout(
        "Saved API key \(maskAPIKey(key)) to \(dependencies.credentialStore.locationDescription)."
    )
    if let envKey = dependencies.environment[apiKeyEnvironmentVariable], !envKey.isEmpty {
        dependencies.writeStderr(
            "Note: \(apiKeyEnvironmentVariable) is set and takes priority over the stored key."
        )
    }
}

/// Validates the key with an authenticated, read-only call (listing models).
private func verifyAPIKey(_ key: String, dependencies: CommandDependencies) async throws {
    let client = dependencies.makeAPIClient(key)
    let response: Operations.listSpeechToTextModels.Output
    do {
        response = try await client.listSpeechToTextModels(.init())
    } catch {
        dependencies.writeStderr("Could not reach the Speechall API to verify the key: \(error). Nothing was saved.")
        throw ExitCode.failure
    }

    switch response {
    case .ok:
        return
    case .unauthorized(let error):
        let message = (try? await extractErrorMessage(from: error.body)) ?? "Unauthorized"
        dependencies.writeStderr("The Speechall API rejected this key (HTTP 401: \(message)). Nothing was saved.")
        throw ExitCode.failure
    case .code402:
        verificationFailed(402, dependencies: dependencies)
    case .badRequest:
        verificationFailed(400, dependencies: dependencies)
    case .notFound:
        verificationFailed(404, dependencies: dependencies)
    case .tooManyRequests:
        verificationFailed(429, dependencies: dependencies)
    case .internalServerError:
        verificationFailed(500, dependencies: dependencies)
    case .serviceUnavailable:
        verificationFailed(503, dependencies: dependencies)
    case .gatewayTimeout:
        verificationFailed(504, dependencies: dependencies)
    case .undocumented(let statusCode, _):
        verificationFailed(statusCode, dependencies: dependencies)
    }
    throw ExitCode.failure
}

private func verificationFailed(_ statusCode: Int, dependencies: CommandDependencies) {
    dependencies.writeStderr(
        "Could not verify the API key (HTTP \(statusCode) from the Speechall API). Nothing was saved. Try again later."
    )
}

func runAuthStatus(apiKeyOption: String?, dependencies: CommandDependencies) throws {
    let resolved: ResolvedAPIKey?
    do {
        resolved = try resolveAPIKeyWithSource(
            from: apiKeyOption,
            environment: dependencies.environment,
            store: dependencies.credentialStore
        )
    } catch {
        dependencies.writeStderr("\(error)")
        throw ExitCode.failure
    }

    guard let resolved else {
        dependencies.writeStderr(
            "No API key found. Run `speechall auth login` in your terminal to store one."
        )
        throw ExitCode.failure
    }

    dependencies.writeStdout("API key available: \(maskAPIKey(resolved.key)) (source: \(resolved.source.description))")
}

func runAuthLogout(dependencies: CommandDependencies) throws {
    let removed: Bool
    do {
        removed = try dependencies.credentialStore.deleteAPIKey()
    } catch {
        dependencies.writeStderr("\(error)")
        throw ExitCode.failure
    }
    if removed {
        dependencies.writeStdout("Removed stored API key from \(dependencies.credentialStore.locationDescription).")
    }
    if let envKey = dependencies.environment[apiKeyEnvironmentVariable], !envKey.isEmpty {
        dependencies.writeStderr("Note: \(apiKeyEnvironmentVariable) is still set in this environment.")
    }
}

// MARK: - Reading the key from the terminal or stdin

/// Terminal settings saved while echo is disabled, so a signal handler can restore them.
nonisolated(unsafe) private var savedTerminalAttributes: termios?

/// Reads the API key without it ever appearing in argv: a hidden prompt when stdin is a TTY,
/// otherwise a single line from stdin.
@Sendable
func readAPIKeyFromStandardInput() throws -> String? {
    guard isatty(STDIN_FILENO) == 1 else {
        return readLine(strippingNewline: true)
    }

    writeStandardErrorRaw("Paste your Speechall API key (input hidden), then press Enter: ")

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw CredentialStoreError(description: "Could not read terminal settings.")
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    savedTerminalAttributes = original

    let restoreAndExit: @convention(c) (Int32) -> Void = { signalNumber in
        if var attributes = savedTerminalAttributes {
            tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        }
        _exit(128 + signalNumber)
    }
    let previousInt = signal(SIGINT, restoreAndExit)
    let previousTerm = signal(SIGTERM, restoreAndExit)

    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
        signal(SIGINT, previousInt)
        signal(SIGTERM, previousTerm)
        throw CredentialStoreError(description: "Could not disable terminal echo.")
    }

    let line = readLine(strippingNewline: true)

    tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    savedTerminalAttributes = nil
    signal(SIGINT, previousInt)
    signal(SIGTERM, previousTerm)
    writeStandardErrorRaw("\n")
    return line
}

private func writeStandardErrorRaw(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
