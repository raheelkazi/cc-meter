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
/// Runs `/usr/bin/security`. A seam, so the credential paths can be tested without touching
/// the real Keychain — and so every spawn goes through one place that enforces a timeout.
public protocol KeychainCommandRunning {
    func run(executable: String, arguments: [String], input: Data?) throws
        -> (status: Int32, output: Data)
}

public struct KeychainCommandProcess: KeychainCommandRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String], input: Data?) throws
        -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // suppress "item not found" noise

        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }

        try process.run()

        // Without this a wedged `security` blocks waitUntilExit() forever — and readBlob sits
        // on the fetch path, so it would hang the meter with no error and no recovery.
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return (process.terminationStatus, data)
    }
}

public struct KeychainReader {
    let service: String
    let account: String
    let runner: KeychainCommandRunning

    public init(service: String,
                account: String,
                runner: KeychainCommandRunning = KeychainCommandProcess()) {
        self.service = service
        self.account = account
        self.runner = runner
    }

    public func readBlob() throws -> Data {
        let result: (status: Int32, output: Data)
        do {
            result = try runner.run(executable: "/usr/bin/security",
                                    arguments: ["find-generic-password", "-w",
                                                "-s", service, "-a", account],
                                    input: nil)
        } catch {
            throw UsageError.noCredentials
        }

        // security prints the password (the JSON blob) with a trailing newline.
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8)?
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
    let runner: KeychainCommandRunning

    public init(service: String,
                account: String,
                runner: KeychainCommandRunning = KeychainCommandProcess()) {
        self.service = service
        self.account = account
        self.runner = runner
    }

    public func writeBlob(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.badResponse("credential blob is not valid UTF-8")
        }

        // `-w` with NO value makes security read the password from stdin. Passing it as
        // `-w <secret>` put the access AND refresh token on the command line, where any
        // process on the machine could read them out of `ps aux`.
        //
        // security prompts and then asks to *retype*, so it needs the secret twice — a single
        // copy fails with "passwords don't match" and silently stores nothing.
        let input = Data("\(text)\n\(text)\n".utf8)

        let result: (status: Int32, output: Data)
        do {
            result = try runner.run(executable: "/usr/bin/security",
                                    arguments: ["add-generic-password", "-U",
                                                "-s", service, "-a", account, "-w"],
                                    input: input)
        } catch {
            throw UsageError.badResponse("keychain write failed to launch: \(error.localizedDescription)")
        }

        guard result.status == 0 else {
            throw UsageError.badResponse("keychain write exited \(result.status)")
        }
    }
}

public enum CredentialWriteError: Error, Equatable {
    /// Another process — the `claude` CLI — rotated the refresh token while we were refreshing.
    /// Ours is already dead, and writing it would invalidate theirs and sign the user out.
    case concurrentRotation
}

/// Reads and writes the whole credential blob, preserving fields we do not own.
public protocol CredentialStoring {
    func read() throws -> (credentials: StoredCredentials, rawBlob: Data)
    /// - Parameter expectedCurrentRefreshToken: the refresh token this update was derived from.
    ///   The write is abandoned if the stored one no longer matches — see `concurrentRotation`.
    func write(accessToken: String,
               refreshToken: String?,
               expiresAt: Date?,
               expectedCurrentRefreshToken: String?) throws
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

    public func write(accessToken: String,
                      refreshToken: String?,
                      expiresAt: Date?,
                      expectedCurrentRefreshToken: String?) throws {
        let original = try reader.readBlob()

        // Compare-and-swap. We are editing the `claude` CLI's Keychain item, and the CLI
        // refreshes at the same moment we do — both notice expiry together. Anthropic rotates
        // the refresh token on use, so a blind read-modify-write clobbers whichever rotation
        // landed first, invalidating a live refresh token and signing the user out.
        let current = try? parseCredentials(from: original)
        guard current?.refreshToken == expectedCurrentRefreshToken else {
            throw CredentialWriteError.concurrentRotation
        }

        let updated = try updatedBlob(original: original,
                                      accessToken: accessToken,
                                      refreshToken: refreshToken,
                                      expiresAt: expiresAt)
        try writer.writeBlob(updated)
    }
}
