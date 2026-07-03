import Foundation
import Security

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
public struct KeychainReader {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func readBlob() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw UsageError.noCredentials
        }
        return data
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
