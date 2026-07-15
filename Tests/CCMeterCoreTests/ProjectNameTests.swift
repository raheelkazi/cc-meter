import XCTest
@testable import CCMeterCore

final class ProjectNameTests: XCTestCase {
    func testPlainCwdUsesLeafDirectory() {
        XCTAssertEqual(ProjectName.from(cwd: "/Users/x/Desktop/Speechify/cc-meter"), "cc-meter")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(ProjectName.from(cwd: "/Users/x/web/"), "web")
    }

    func testClaudeWorktreeMapsToParentProject() {
        // Real Claude worktree layout is "<project>/.claude/worktrees/<branch>".
        XCTAssertEqual(
            ProjectName.from(cwd: "/Users/x/MacApp/mac-speechify-ai-assistant/.claude/worktrees/dictation-privacy-mode"),
            "mac-speechify-ai-assistant")
    }

    func testCodexWorktreeLeafIsProject() {
        XCTAssertEqual(
            ProjectName.from(cwd: "/Users/x/.codex/worktrees/79e6/mac-speechify-ai-assistant"),
            "mac-speechify-ai-assistant")
    }

    func testEmptyFallsBackToWholeString() {
        XCTAssertEqual(ProjectName.from(cwd: ""), "")
    }
}
