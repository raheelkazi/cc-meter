import Foundation

/// Parses `~/.claude/projects/**/**.jsonl` lines into usage events.
///
/// Only `assistant` records carrying `message.usage` count. Each is self-contained (cwd, model,
/// requestId, message.id all present), so a byte-range chunk of whole lines parses without any
/// carried state. `<synthetic>` model records are injected, not real usage, and are dropped.
public enum ClaudeUsageLogParser {
    public static func parse(lines: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for lineData in lines.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let messageId = message["id"] as? String,
                  let cwd = obj["cwd"] as? String,
                  let timestamp = obj["timestamp"] as? String,
                  let at = ISODate.parse(timestamp)
            else { continue }

            let requestId = obj["requestId"] as? String ?? messageId
            let tokens = TokenCounts(
                input: int(usage["input_tokens"]),
                output: int(usage["output_tokens"]),
                cacheCreation: int(usage["cache_creation_input_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]))

            events.append(UsageEvent(provider: .claude, at: at,
                                     project: ProjectName.from(cwd: cwd), model: model,
                                     tokens: tokens, dedupKey: "claude:\(requestId):\(messageId)"))
        }
        return events
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
