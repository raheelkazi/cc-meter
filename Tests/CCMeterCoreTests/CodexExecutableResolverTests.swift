import XCTest
@testable import CCMeterCore

private struct StubLoginShellPath: LoginShellPathProviding {
    let path: String?
    func loginShellPath() -> String? { path }
}

private final class SpyLoginShellPath: LoginShellPathProviding {
    private(set) var callCount = 0
    private let path: String?

    init(path: String?) { self.path = path }

    func loginShellPath() -> String? {
        callCount += 1
        return path
    }
}

final class CodexExecutableResolverTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-resolver-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeExecutable(_ name: String,
                                in parent: URL? = nil,
                                contents: String = "") throws -> URL {
        let url = (parent ?? directory).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    private func missingCandidate() -> URL {
        directory.appendingPathComponent("absent/codex")
    }

    func testStaticCandidateResolvesWithoutSpawningLoginShell() throws {
        let codex = try makeExecutable("codex")
        let spy = SpyLoginShellPath(path: "/should/not/be/consulted")

        let resolved = CodexExecutableResolver(candidates: [missingCandidate(), codex],
                                               loginShellPath: spy).resolve()

        XCTAssertEqual(resolved?.url, codex)
        XCTAssertEqual(spy.callCount, 0, "the static fast path must not pay for a shell spawn")
    }

    func testDefaultCandidatesIncludeSystemAndUserChatGPTBundles() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidates = CodexExecutableResolver.defaultCandidates(home: home)

        XCTAssertTrue(candidates.contains(
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ))
        XCTAssertTrue(candidates.contains(
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
        ))
    }

    /// The exec half of the bug: npm ships codex as a `#!/usr/bin/env node` script, so the
    /// child needs `node` on its PATH. node sits beside codex, so the executable's own
    /// directory must always be on the search path we hand to the transport.
    func testSearchPathContainsExecutableDirectory() throws {
        let codex = try makeExecutable("codex")

        let resolved = CodexExecutableResolver(candidates: [codex],
                                               loginShellPath: StubLoginShellPath(path: nil)).resolve()

        let searchPath = try XCTUnwrap(resolved?.searchPath)
        XCTAssertTrue(searchPath.split(separator: ":").contains(Substring(directory.path)),
                      "search path \(searchPath) must contain \(directory.path)")
    }

    /// The discovery half: nvm / fnm / volta / asdf / custom npm prefixes appear in none of
    /// the static candidates, so the user's real login-shell PATH is the only way to find them.
    func testFallsBackToLoginShellPathWhenNoStaticCandidateMatches() throws {
        let codex = try makeExecutable("codex")
        let login = StubLoginShellPath(path: "/nonexistent:\(directory.path)")

        let resolved = CodexExecutableResolver(candidates: [missingCandidate()],
                                               loginShellPath: login).resolve()

        XCTAssertEqual(resolved?.url.resolvingSymlinksInPath(), codex)
        XCTAssertEqual(resolved?.searchPath, "/nonexistent:\(directory.path)")
    }

    func testReturnsNilWhenCodexIsAbsentFromLoginShellPathToo() {
        let login = StubLoginShellPath(path: "/nonexistent")

        XCTAssertNil(CodexExecutableResolver(candidates: [missingCandidate()],
                                             loginShellPath: login).resolve())
    }

    func testReturnsNilWhenLoginShellPathIsUnavailable() {
        XCTAssertNil(CodexExecutableResolver(candidates: [missingCandidate()],
                                             loginShellPath: StubLoginShellPath(path: nil)).resolve())
    }

    func testIgnoresNonExecutableCodexOnLoginShellPath() throws {
        let url = directory.appendingPathComponent("codex")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: url.path)

        XCTAssertNil(CodexExecutableResolver(candidates: [missingCandidate()],
                                             loginShellPath: StubLoginShellPath(path: directory.path))
            .resolve())
    }

    func testSkipsEmptySegmentsInLoginShellPath() throws {
        let codex = try makeExecutable("codex")
        let login = StubLoginShellPath(path: "::\(directory.path):")

        let resolved = CodexExecutableResolver(candidates: [missingCandidate()],
                                               loginShellPath: login).resolve()

        XCTAssertEqual(resolved?.url.resolvingSymlinksInPath(), codex)
    }
}

final class LoginShellPathTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-loginshell-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeShell(_ name: String, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    func testReadsPathFromRealLoginShell() throws {
        let path = try XCTUnwrap(LoginShellPath(shell: "/bin/zsh", timeout: 10).loginShellPath())

        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.contains("/usr/bin"), "expected a real PATH, got \(path)")
    }

    func testReturnsNilWhenShellCannotLaunch() {
        XCTAssertNil(LoginShellPath(shell: "/nonexistent/shell", timeout: 5).loginShellPath())
    }

    /// A hanging rc file must not wedge the menu bar's refresh.
    func testTimesOutOnHangingShell() throws {
        let shell = try makeShell("hangs", body: "sleep 30")
        let started = Date()

        let path = LoginShellPath(shell: shell.path, timeout: 1).loginShellPath()

        XCTAssertNil(path)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "a hanging shell must be abandoned, not waited on")
    }

    /// cc-meter polls on a timer; a shell spawn per refresh would be wasteful.
    func testCachesResultAcrossCalls() throws {
        let counter = directory.appendingPathComponent("invocations")
        // Emulates a real shell: records the invocation, then evaluates the `-c` command.
        let shell = try makeShell("counts", body: """
        echo x >> \(counter.path)
        PATH=/usr/bin:/bin
        for arg in "$@"; do command="$arg"; done
        eval "$command"
        """)

        let provider = LoginShellPath(shell: shell.path, timeout: 10)
        let first = provider.loginShellPath()
        let second = provider.loginShellPath()

        XCTAssertEqual(first, "/usr/bin:/bin")
        XCTAssertEqual(second, first)
        let invocations = try String(contentsOf: counter, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(invocations, 1, "login shell must be spawned once and cached")
    }

    func testReturnsNilWhenShellPrintsNothing() throws {
        let shell = try makeShell("silent", body: "exit 0")

        XCTAssertNil(LoginShellPath(shell: shell.path, timeout: 10).loginShellPath())
    }
}
