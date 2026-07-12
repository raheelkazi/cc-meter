import XCTest
@testable import CCMeterCore

final class HomebrewUpdaterTests: XCTestCase {
    func testEligibleOutdatedInstallRunsOnlyTargetedCommands() async {
        let runner = StubUpdateCommandRunner(results: [
            .success(UpdateCommandResult(status: 0, output: "")),
            .success(UpdateCommandResult(status: 0, output: "cc-meter\n")),
            .success(UpdateCommandResult(status: 0, output: "installed\n"))
        ])
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        let outcome = await updater.installIfAvailable()
        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["update-if-needed"],
            ["outdated", "--quiet", "--formula", "raheelkazi/tap/cc-meter"],
            ["upgrade", "--formula", "raheelkazi/tap/cc-meter"]
        ])
        XCTAssertEqual(runner.invocations.map(\.executable.path), ["/test/brew", "/test/brew", "/test/brew"])
        XCTAssertEqual(runner.invocations.map(\.timeout), [120, 120, 900])
        XCTAssertEqual(runner.invocations.map(\.maxOutputBytes), [64 * 1024, 64 * 1024, 64 * 1024])
    }

    func testTapQualifiedOutdatedOutputRunsUpgrade() async {
        let runner = StubUpdateCommandRunner(results: [
            .success(UpdateCommandResult(status: 0, output: "")),
            .success(UpdateCommandResult(status: 0, output: " raheelkazi/tap/cc-meter \n")),
            .success(UpdateCommandResult(status: 0, output: ""))
        ])
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        let outcome = await updater.installIfAvailable()
        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(runner.invocations.count, 3)
    }

    func testNonExactOutdatedOutputDoesNotBecomeACommand() async {
        let runner = StubUpdateCommandRunner(results: [
            .success(UpdateCommandResult(status: 0, output: "")),
            .success(UpdateCommandResult(status: 0, output: "cc-meter; touch /tmp/nope\n"))
        ])
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        let outcome = await updater.installIfAvailable()
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testManualRunIsUnsupportedAndRunsNothing() async {
        let runner = StubUpdateCommandRunner(results: [])
        let updater = makeUpdater(runner: runner, serviceName: nil)

        XCTAssertFalse(updater.isSupported)
        let outcome = await updater.installIfAvailable()
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testMissingExecutableIsUnsupportedAndRunsNothing() async {
        let runner = StubUpdateCommandRunner(results: [])
        let updater = HomebrewUpdater(
            resolver: StubBrewResolver(url: nil),
            runner: runner,
            environment: ["XPC_SERVICE_NAME": "homebrew.mxcl.cc-meter"]
        )

        XCTAssertFalse(updater.isSupported)
        let outcome = await updater.installIfAvailable()
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testNonzeroMetadataStatusFailsAtMetadata() async {
        await assertNonzeroFailure(
            results: [.success(UpdateCommandResult(status: 1, output: "metadata failed"))],
            stage: .metadata,
            invocationCount: 1
        )
    }

    func testNonzeroOutdatedStatusFailsAtOutdated() async {
        await assertNonzeroFailure(
            results: [
                .success(UpdateCommandResult(status: 0, output: "")),
                .success(UpdateCommandResult(status: 2, output: "outdated failed"))
            ],
            stage: .outdated,
            invocationCount: 2
        )
    }

    func testNonzeroUpgradeStatusFailsAtUpgrade() async {
        await assertNonzeroFailure(
            results: [
                .success(UpdateCommandResult(status: 0, output: "")),
                .success(UpdateCommandResult(status: 0, output: "cc-meter\n")),
                .success(UpdateCommandResult(status: 3, output: "upgrade failed"))
            ],
            stage: .upgrade,
            invocationCount: 3
        )
    }

    func testLaunchErrorMapsToCurrentStage() async {
        let runner = StubUpdateCommandRunner(results: [
            .success(UpdateCommandResult(status: 0, output: "")),
            .failure(.launch("permission denied"))
        ])
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        let outcome = await updater.installIfAvailable()
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected failed outcome")
        }
        XCTAssertEqual(failure.stage, .outdated)
        XCTAssertTrue(failure.detail.contains("launch"))
        XCTAssertTrue(failure.detail.contains("permission denied"))
    }

    func testTimeoutMapsToCurrentStage() async {
        let runner = StubUpdateCommandRunner(results: [
            .success(UpdateCommandResult(status: 0, output: "")),
            .success(UpdateCommandResult(status: 0, output: "cc-meter\n")),
            .failure(.timeout("partial output"))
        ])
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        let outcome = await updater.installIfAvailable()
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected failed outcome")
        }
        XCTAssertEqual(failure.stage, .upgrade)
        XCTAssertTrue(failure.detail.contains("timeout"))
        XCTAssertTrue(failure.detail.contains("partial output"))
    }

    func testResolverSelectsFirstExecutableCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-brew-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nonExecutable = directory.appendingPathComponent("not-executable")
        let firstExecutable = directory.appendingPathComponent("first-brew")
        let secondExecutable = directory.appendingPathComponent("second-brew")
        try Data().write(to: nonExecutable)
        try Data().write(to: firstExecutable)
        try Data().write(to: secondExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstExecutable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondExecutable.path)

        let resolver = HomebrewExecutableResolver(
            candidates: [nonExecutable, firstExecutable, secondExecutable],
            fileManager: .default
        )

        XCTAssertEqual(resolver.resolve(), firstExecutable)
    }

    private func assertNonzeroFailure(
        results: [Result<UpdateCommandResult, UpdateCommandError>],
        stage: HomebrewUpdateStage,
        invocationCount: Int
    ) async {
        let runner = StubUpdateCommandRunner(results: results)
        let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

        guard case .failed(let failure) = await updater.installIfAvailable() else {
            return XCTFail("expected failed outcome")
        }
        XCTAssertEqual(failure.stage, stage)
        XCTAssertTrue(failure.detail.contains("status"))
        XCTAssertEqual(runner.invocations.count, invocationCount)
    }
}

private struct StubBrewResolver: HomebrewExecutableResolving {
    let url: URL?
    func resolve() -> URL? { url }
}

private final class StubUpdateCommandRunner: UpdateCommandRunning {
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
        let maxOutputBytes: Int
    }

    var results: [Result<UpdateCommandResult, UpdateCommandError>]
    private(set) var invocations: [Invocation] = []

    init(results: [Result<UpdateCommandResult, UpdateCommandError>]) {
        self.results = results
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> UpdateCommandResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        ))
        return try results.removeFirst().get()
    }
}

private func makeUpdater(
    runner: StubUpdateCommandRunner,
    serviceName: String?
) -> HomebrewUpdater {
    HomebrewUpdater(
        resolver: StubBrewResolver(url: URL(fileURLWithPath: "/test/brew")),
        runner: runner,
        environment: serviceName.map { ["XPC_SERVICE_NAME": $0] } ?? [:]
    )
}
