import Foundation
@testable import CCMeterCore

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

    /// Usage response that also carries a `spend` object (provisional shape).
    static let usageWithSpendJSON = """
    {
      "limits": [
        { "kind": "session", "percent": 20, "resets_at": "2026-07-03T21:09:59+00:00", "is_active": true }
      ],
      "spend": { "used_cents": 1234, "limit_cents": 5000, "currency": "USD" }
    }
    """.data(using: .utf8)!

    static let codexMultiLimitJSON = """
    {
      "id": 2,
      "result": {
        "rateLimits": {
          "limitId": "codex",
          "limitName": null,
          "primary": { "usedPercent": 99, "windowDurationMins": 300, "resetsAt": 1783900000 },
          "secondary": null
        },
        "rateLimitsByLimitId": {
          "codex": {
            "limitId": "codex",
            "limitName": null,
            "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1783900000 },
            "secondary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1784400000 }
          },
          "codex_spark": {
            "limitId": "codex_spark",
            "limitName": "GPT-5.3-Codex-Spark",
            "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1784400100 },
            "secondary": null
          }
        }
      }
    }
    """.data(using: .utf8)!
}

/// Records every command it was handed and replays canned results. One spy for every call site,
/// so the fakes cannot drift apart the way the four real runners did.
final class SpyCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [Command] = []
    private var _results: [CommandResult]
    var launchError: Error?

    /// Commands passed to `run`, in order.
    var commands: [Command] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    init(results: [CommandResult] = []) {
        self._results = results
    }

    /// Convenience for the common "it worked and printed this" case.
    static func succeeding(_ outputs: [Data] = [Data()]) -> SpyCommandRunner {
        SpyCommandRunner(results: outputs.map {
            CommandResult(status: 0, standardOutput: $0, standardError: Data(), timedOut: false)
        })
    }

    func run(_ command: Command) throws -> CommandResult {
        lock.lock()
        _commands.append(command)
        let error = launchError
        let next = _results.isEmpty ? nil : _results.removeFirst()
        lock.unlock()

        if let error { throw error }
        return next ?? CommandResult(status: 0, standardOutput: Data(),
                                     standardError: Data(), timedOut: false)
    }

    func launch(_ command: Command) throws {
        lock.lock()
        _commands.append(command)
        let error = launchError
        lock.unlock()
        if let error { throw error }
    }
}
