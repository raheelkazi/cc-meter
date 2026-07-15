import XCTest
@testable import CCMeterCore

final class CodexUsageLogParserTests: XCTestCase {
    private func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    func testParsesTokenCountUsingLastDeltaWithModelFromTurnContext() {
        let data =
            line("""
            {"type":"session_meta","payload":{"id":"sess_1","cwd":"/Users/x/cc-meter","timestamp":"2026-07-15T01:11:09.000Z"}}
            """) +
            line("""
            {"type":"turn_context","payload":{"model":"gpt-5.6-sol","cwd":"/Users/x/cc-meter"}}
            """) +
            line("""
            {"timestamp":"2026-07-15T01:11:10.074Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":99999,"cached_input_tokens":8,"output_tokens":9,"reasoning_output_tokens":9,"total_tokens":99999},\
            "last_token_usage":{"input_tokens":21256,"cached_input_tokens":9984,"output_tokens":512,"reasoning_output_tokens":105,"total_tokens":21768}}}}
            """)
        let (events, state) = CodexUsageLogParser.parse(lines: data, state: CodexParseState())
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.provider, .codex)
        XCTAssertEqual(e.project, "cc-meter")
        XCTAssertEqual(e.model, "gpt-5.6-sol")
        // input is the non-cached remainder; cacheRead is cached_input_tokens.
        XCTAssertEqual(e.tokens, TokenCounts(input: 21256 - 9984, output: 512, cacheRead: 9984, reasoning: 105))
        XCTAssertEqual(e.dedupKey, "codex:sess_1:2026-07-15T01:11:10.074Z")
        XCTAssertEqual(state.model, "gpt-5.6-sol")
        XCTAssertEqual(state.cwd, "/Users/x/cc-meter")
        XCTAssertEqual(state.sessionId, "sess_1")
    }

    func testResumesFromSeededStateWhenChunkHasNoMetaOrTurnContext() {
        // Real token_count records carry NO session_id; model, cwd, and session id all come from
        // earlier records (session_meta/turn_context) and are seeded from the cursor's carried state.
        let seeded = CodexParseState(model: "gpt-5.6-sol", cwd: "/Users/x/web", sessionId: "sess_2")
        let data = line("""
        {"timestamp":"2026-07-15T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """)
        let (events, _) = CodexUsageLogParser.parse(lines: data, state: seeded)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-5.6-sol")
        XCTAssertEqual(events[0].project, "web")
        XCTAssertEqual(events[0].dedupKey, "codex:sess_2:2026-07-15T02:00:00.000Z")
        XCTAssertEqual(events[0].tokens, TokenCounts(input: 10, output: 5, cacheRead: 0, reasoning: 0))
    }

    func testSkipsTokenCountWithNoKnownModel() {
        let data = line("""
        {"timestamp":"2026-07-15T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}
        """)
        let (events, _) = CodexUsageLogParser.parse(lines: data, state: CodexParseState())
        XCTAssertTrue(events.isEmpty, "no model context yet -> cannot attribute, so skip")
    }
}
