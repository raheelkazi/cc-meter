import Foundation

private struct CredentialsBlob: Decodable {
    let claudeAiOauth: OAuth?
    struct OAuth: Decodable { let accessToken: String? }
}

/// Extracts the OAuth access token from the Keychain credential blob.
public func parseToken(from data: Data) throws -> String {
    let blob = try? JSONDecoder().decode(CredentialsBlob.self, from: data)
    guard let token = blob?.claudeAiOauth?.accessToken, !token.isEmpty else {
        throw UsageError.noCredentials
    }
    return token
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
