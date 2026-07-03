import Foundation

enum Fixtures {
    /// Trimmed real response captured 2026-07-03. Contains only usage numbers.
    static let usageJSON = """
    {
      "five_hour": { "utilization": 3, "resets_at": "2026-07-03T21:09:59.903723+00:00" },
      "seven_day": { "utilization": 37, "resets_at": "2026-07-05T13:59:59.903744+00:00" },
      "limits": [
        { "kind": "session", "group": "session", "percent": 3, "severity": "normal",
          "resets_at": "2026-07-03T21:09:59.903723+00:00", "scope": null, "is_active": false },
        { "kind": "weekly_all", "group": "weekly", "percent": 37, "severity": "normal",
          "resets_at": "2026-07-05T13:59:59.903744+00:00", "scope": null, "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 54, "severity": "normal",
          "resets_at": "2026-07-05T13:59:59.904012+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
          "is_active": true }
      ]
    }
    """.data(using: .utf8)!

    /// Synthetic Keychain blob shape (NOT a real token).
    static let credentialBlob = """
    {"claudeAiOauth":{"accessToken":"sk-test-abc123","refreshToken":"rt-test","expiresAt":1783113000000,"scopes":["user:inference"],"subscriptionType":"max"},"mcpOAuth":{}}
    """.data(using: .utf8)!
}
