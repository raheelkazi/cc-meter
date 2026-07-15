import XCTest
@testable import CCMeterCore

final class ClaudeUsageLogParserTests: XCTestCase {
    private func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    func testParsesAssistantUsageRecord() {
        let data = line("""
        {"type":"assistant","timestamp":"2026-07-03T16:16:46.300Z","cwd":"/Users/x/cc-meter",\
        "requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-8",\
        "usage":{"input_tokens":29224,"output_tokens":810,"cache_creation_input_tokens":2555,"cache_read_input_tokens":18258}}}
        """)
        let events = ClaudeUsageLogParser.parse(lines: data)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.provider, .claude)
        XCTAssertEqual(e.project, "cc-meter")
        XCTAssertEqual(e.model, "claude-opus-4-8")
        XCTAssertEqual(e.tokens, TokenCounts(input: 29224, output: 810, cacheCreation: 2555, cacheRead: 18258))
        XCTAssertEqual(e.dedupKey, "claude:req_1:msg_1")
        XCTAssertEqual(e.at, ISODate.parse("2026-07-03T16:16:46.300Z"))
    }

    func testSkipsSyntheticModel() {
        let data = line("""
        {"type":"assistant","timestamp":"2026-07-03T16:16:46.300Z","cwd":"/Users/x/cc-meter",\
        "requestId":"r","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}
        """)
        XCTAssertTrue(ClaudeUsageLogParser.parse(lines: data).isEmpty)
    }

    func testIgnoresNonAssistantAndUsagelessAndMalformedLines() {
        let data = line("{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}")
            + line("{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"model\":\"claude-opus-4-8\"}}")
            + line("{ not json")
        XCTAssertTrue(ClaudeUsageLogParser.parse(lines: data).isEmpty)
    }
}
