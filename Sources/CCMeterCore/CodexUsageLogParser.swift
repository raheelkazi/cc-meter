import Foundation

/// Model + cwd carried across incremental chunks of one Codex rollout file.
///
/// A `token_count` event carries neither: model comes from the most recent `turn_context`,
/// cwd from `session_meta`. Both usually precede the cursor once a session is underway, so the
/// indexer persists this state per file and seeds the next chunk with it.
public struct CodexParseState: Equatable {
    public var model: String?
    public var cwd: String?
    public var sessionId: String?
    public init(model: String? = nil, cwd: String? = nil, sessionId: String? = nil) {
        self.model = model; self.cwd = cwd; self.sessionId = sessionId
    }
}

/// Parses `~/.codex/sessions/**/rollout-*.jsonl` lines into usage events.
///
/// Sums `last_token_usage` (per-turn delta); `total_token_usage` is cumulative and must not be
/// summed. `cached_input_tokens` is folded into `cacheRead`, and `input` is the non-cached
/// remainder so `tokens.total` matches the reported `total_tokens`.
public enum CodexUsageLogParser {
    public static func parse(lines: Data, state: CodexParseState) -> (events: [UsageEvent], state: CodexParseState) {
        var state = state
        var events: [UsageEvent] = []

        for lineData in lines.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                if let p = payload {
                    if let cwd = p["cwd"] as? String { state.cwd = cwd }
                    if let id = p["id"] as? String { state.sessionId = id }
                    if let id = p["session_id"] as? String { state.sessionId = id }
                }
            case "turn_context":
                if let p = payload {
                    if let model = p["model"] as? String { state.model = model }
                    if let cwd = p["cwd"] as? String { state.cwd = cwd }
                }
            case "event_msg":
                guard let p = payload, p["type"] as? String == "token_count",
                      let info = p["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let model = state.model,
                      let timestamp = obj["timestamp"] as? String,
                      let at = ISODate.parse(timestamp)
                else { continue }

                let sid = state.sessionId ?? "unknown"
                let cached = int(last["cached_input_tokens"])
                let tokens = TokenCounts(
                    input: max(0, int(last["input_tokens"]) - cached),
                    output: int(last["output_tokens"]),
                    cacheRead: cached,
                    reasoning: int(last["reasoning_output_tokens"]))

                events.append(UsageEvent(provider: .codex, at: at,
                                         project: ProjectName.from(cwd: state.cwd ?? ""),
                                         model: model, tokens: tokens,
                                         dedupKey: "codex:\(sid):\(timestamp)"))
            default:
                continue
            }
        }
        return (events, state)
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
