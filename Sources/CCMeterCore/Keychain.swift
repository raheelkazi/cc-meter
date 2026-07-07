import Foundation

private struct CredentialsBlob: Decodable {
    let claudeAiOauth: OAuth?
    struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?   // epoch milliseconds
    }
}

/// The OAuth material we care about from the Keychain credential blob.
public struct StoredCredentials: Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Extracts the OAuth access token from the Keychain credential blob.
public func parseToken(from data: Data) throws -> String {
    try parseCredentials(from: data).accessToken
}

/// Extracts access token, refresh token, and expiry from the credential blob.
public func parseCredentials(from data: Data) throws -> StoredCredentials {
    let blob = try? JSONDecoder().decode(CredentialsBlob.self, from: data)
    guard let oauth = blob?.claudeAiOauth,
          let token = oauth.accessToken, !token.isEmpty else {
        throw UsageError.noCredentials
    }
    let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    return StoredCredentials(accessToken: token, refreshToken: oauth.refreshToken, expiresAt: expiresAt)
}

/// Returns a copy of the credential blob with the OAuth tokens replaced, leaving
/// every other field the `claude` CLI stores untouched. Preserving unknown keys
/// means writing a refreshed token back never corrupts the CLI's own state.
public func updatedBlob(original: Data,
                        accessToken: String,
                        refreshToken: String?,
                        expiresAt: Date?) throws -> Data {
    var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] ?? [:]
    var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
    oauth["accessToken"] = accessToken
    if let refreshToken { oauth["refreshToken"] = refreshToken }
    if let expiresAt { oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000) }
    root["claudeAiOauth"] = oauth
    return try JSONSerialization.data(withJSONObject: root)
}

public protocol TokenProviding {
    func currentToken() throws -> String
}

/// Reads a generic-password Keychain item as raw Data.
///
/// This shells out to the Apple-signed `/usr/bin/security` tool rather than
/// calling `SecItemCopyMatching` directly. The credential item is owned by
/// Claude Code, so any other reader triggers a Keychain access prompt. Because
/// our own binary is only ad-hoc signed (no stable code identity), "Always
/// Allow" cannot durably whitelist it and macOS re-prompts on every read. The
/// `security` tool has a stable Apple identity, so a single "Always Allow"
/// persists across our rebuilds and every poll.
public struct KeychainReader {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func readBlob() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // suppress "item not found" noise

        do {
            try process.run()
        } catch {
            throw UsageError.noCredentials
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // security prints the password (the JSON blob) with a trailing newline.
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let blob = text.data(using: .utf8) else {
            throw UsageError.noCredentials
        }
        return blob
    }
}

public struct KeychainTokenProvider: TokenProviding {
    let reader: KeychainReader
    public init(reader: KeychainReader) { self.reader = reader }
    public func currentToken() throws -> String {
        let data = try reader.readBlob()
        return try parseToken(from: data)
    }
}

/// Writes a generic-password Keychain item, replacing any existing value.
///
/// Uses the Apple-signed `/usr/bin/security` tool for the same code-identity
/// reasons as `KeychainReader`: a single "Always Allow" persists across our
/// rebuilds. `-U` updates the item in place if it already exists.
public struct KeychainWriter {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func writeBlob(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.badResponse("credential blob is not valid UTF-8")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", text]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw UsageError.badResponse("keychain write failed to launch: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError.badResponse("keychain write exited \(process.terminationStatus)")
        }
    }
}

/// Reads and writes the whole credential blob, preserving fields we do not own.
public protocol CredentialStoring {
    func read() throws -> (credentials: StoredCredentials, rawBlob: Data)
    func write(accessToken: String, refreshToken: String?, expiresAt: Date?) throws
}

public struct KeychainCredentialStore: CredentialStoring {
    let reader: KeychainReader
    let writer: KeychainWriter

    public init(reader: KeychainReader, writer: KeychainWriter) {
        self.reader = reader
        self.writer = writer
    }

    public func read() throws -> (credentials: StoredCredentials, rawBlob: Data) {
        let blob = try reader.readBlob()
        return (try parseCredentials(from: blob), blob)
    }

    public func write(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        let original = try reader.readBlob()
        let updated = try updatedBlob(original: original,
                                      accessToken: accessToken,
                                      refreshToken: refreshToken,
                                      expiresAt: expiresAt)
        try writer.writeBlob(updated)
    }
}
