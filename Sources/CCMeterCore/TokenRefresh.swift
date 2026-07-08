import Foundation

/// Refreshes an expired OAuth access token using the stored refresh token.
public protocol TokenRefreshing {
    /// Attempts a refresh. Returns the new access token on success, or nil when
    /// refresh is unavailable (no refresh token / non-success response). Throws
    /// only on transport failures so the caller can distinguish "try later" from
    /// "cannot refresh, ask the user to re-auth".
    func refresh() async throws -> String?
}

private struct RefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?   // seconds

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Performs the Claude Code OAuth refresh-token grant and writes the rotated
/// tokens back to the Keychain.
///
/// The exact endpoint and client id are the values the `claude` CLI uses; they
/// are injectable so they can be corrected without touching call sites if
/// Anthropic changes them (the design doc flags these as a known unknown, with
/// the graceful fallback being the existing re-authenticate error state).
public struct OAuthTokenRefresher: TokenRefreshing {
    public static let defaultEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    let store: CredentialStoring
    let transport: Transport
    let endpoint: URL
    let clientID: String
    let now: () -> Date

    public init(store: CredentialStoring,
                transport: Transport,
                endpoint: URL = OAuthTokenRefresher.defaultEndpoint,
                clientID: String = OAuthTokenRefresher.defaultClientID,
                now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.endpoint = endpoint
        self.clientID = clientID
        self.now = now
    }

    public func refresh() async throws -> String? {
        guard let refreshToken = try store.read().credentials.refreshToken, !refreshToken.isEmpty else {
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await transport.send(request)
        guard response.status == 200,
              let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: response.data),
              let newAccess = decoded.accessToken, !newAccess.isEmpty else {
            return nil
        }

        let newExpiry = decoded.expiresIn.map { now().addingTimeInterval($0) }
        try store.write(accessToken: newAccess,
                        refreshToken: decoded.refreshToken ?? refreshToken,
                        expiresAt: newExpiry)
        return newAccess
    }
}
