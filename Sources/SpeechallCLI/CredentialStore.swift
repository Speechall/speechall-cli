import Foundation

#if canImport(Security)
import Security
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Persistent storage for the user's Speechall API key.
///
/// macOS uses the login Keychain; Linux uses a 0600 file under the XDG config directory.
/// Tests use an in-memory implementation so they never touch real storage.
protocol CredentialStore: Sendable {
    /// Human-readable location, e.g. "macOS Keychain (service com.speechall.cli)".
    var locationDescription: String { get }
    func readAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    /// Deletes the stored key. Returns `true` if a key was removed, `false` if none was stored.
    @discardableResult
    func deleteAPIKey() throws -> Bool
}

struct CredentialStoreError: Error, CustomStringConvertible {
    var description: String
}

func makeDefaultCredentialStore(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> any CredentialStore {
    #if canImport(Security)
    return KeychainCredentialStore()
    #else
    return FileCredentialStore(fileURL: FileCredentialStore.defaultFileURL(environment: environment))
    #endif
}

// MARK: - Keychain (macOS)

#if canImport(Security)
struct KeychainCredentialStore: CredentialStore {
    static let defaultService = "com.speechall.cli"
    static let defaultAccount = "api-key"

    var service: String = Self.defaultService
    var account: String = Self.defaultAccount

    var locationDescription: String {
        "macOS Keychain (service \(service))"
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError(description: "Stored API key in the Keychain is not valid UTF-8.")
            }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status, action: "read the API key from")
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData] = data
            attributes[kSecAttrLabel] = "Speechall CLI API key"
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw Self.error(addStatus, action: "save the API key to")
            }
        default:
            throw Self.error(updateStatus, action: "save the API key to")
        }
    }

    @discardableResult
    func deleteAPIKey() throws -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw Self.error(status, action: "delete the API key from")
        }
    }

    private static func error(_ status: OSStatus, action: String) -> CredentialStoreError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return CredentialStoreError(description: "Could not \(action) the Keychain: \(message)")
    }
}
#endif

// MARK: - File (Linux, and anywhere without Security.framework)

/// Stores the key in a single-line file. The directory is created with mode 0700 and the
/// file is created with mode 0600 (never chmod-ed after the fact), then atomically renamed
/// into place.
struct FileCredentialStore: CredentialStore {
    var fileURL: URL

    var locationDescription: String {
        fileURL.path
    }

    /// `$XDG_CONFIG_HOME/speechall/credentials`, falling back to `~/.config/speechall/credentials`.
    static func defaultFileURL(environment: [String: String]) -> URL {
        let configHome: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            configHome = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            configHome = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        }
        return configHome
            .appendingPathComponent("speechall", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: false)
    }

    func readAPIKey() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CredentialStoreError(description: "Could not read \(fileURL.path): \(error.localizedDescription)")
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError(description: "\(fileURL.path) is not valid UTF-8.")
        }
        let key = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func saveAPIKey(_ apiKey: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try Self.createPrivateDirectory(at: directory)

        let tempPath = directory
            .appendingPathComponent(".credentials.\(UUID().uuidString).tmp", isDirectory: false)
            .path
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else {
            throw Self.posixError("create \(tempPath)")
        }

        var succeeded = false
        defer {
            if !succeeded {
                unlink(tempPath)
            }
        }

        let bytes = Array((apiKey + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                let error = Self.posixError("write \(tempPath)")
                close(fd)
                throw error
            }
            offset += written
        }
        if fsync(fd) != 0 {
            let error = Self.posixError("sync \(tempPath)")
            close(fd)
            throw error
        }
        close(fd)

        guard rename(tempPath, fileURL.path) == 0 else {
            throw Self.posixError("move credentials into \(fileURL.path)")
        }
        succeeded = true
    }

    @discardableResult
    func deleteAPIKey() throws -> Bool {
        if unlink(fileURL.path) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw Self.posixError("delete \(fileURL.path)")
    }

    /// Creates parent directories normally, and the final `speechall` directory with mode 0700.
    private static func createPrivateDirectory(at directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw CredentialStoreError(description: "Could not create \(parent.path): \(error.localizedDescription)")
            }
        }
        if mkdir(directory.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw posixError("create directory \(directory.path)")
        }
    }

    private static func posixError(_ action: String) -> CredentialStoreError {
        let code = errno
        return CredentialStoreError(description: "Could not \(action): \(String(cString: strerror(code)))")
    }
}
