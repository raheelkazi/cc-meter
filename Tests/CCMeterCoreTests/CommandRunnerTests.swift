import XCTest
@testable import CCMeterCore

/// These run real child processes. Several of them assert on *not hanging*, and a hang in a
/// test is worse than a failure: it wedges the whole suite with no diagnosis. So the work runs
/// on a background queue behind an expectation, which turns "deadlocked" into a clean failure.
private func withDeadline(_ seconds: TimeInterval = 15,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          _ body: @escaping () -> Void) {
    let finished = XCTestExpectation(description: "command finished")
    DispatchQueue.global().async {
        body()
        finished.fulfill()
    }
    let outcome = XCTWaiter().wait(for: [finished], timeout: seconds)
    if outcome != .completed {
        XCTFail("deadlocked: the runner never returned within \(seconds)s", file: file, line: line)
    }
}

final class CommandRunnerTests: XCTestCase {
    private let runner = SystemCommandRunner()

    // MARK: - The basics every caller depends on

    func testCapturesStandardOutput() throws {
        let result = try runner.run(Command(executable: "/bin/echo", arguments: ["hello"]))

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutputText, "hello")
        XCTAssertFalse(result.timedOut)
    }

    /// Every hand-rolled copy this replaces threw stderr away, so a failing command reported only
    /// "exited 1" — the one number that says nothing about what went wrong.
    func testCapturesStandardError() throws {
        let result = try runner.run(
            Command(executable: "/bin/sh", arguments: ["-c", "echo boom >&2; exit 2"])
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.standardErrorText, "boom")
    }

    func testWritesInputToStandardInput() throws {
        let result = try runner.run(
            Command(executable: "/bin/cat", input: Data("piped".utf8))
        )

        XCTAssertEqual(result.standardOutputText, "piped")
    }

    func testPassesEnvironmentToTheChild() throws {
        let result = try runner.run(
            Command(executable: "/bin/sh",
                    arguments: ["-c", "printf %s \"$CC_METER_PROBE\""],
                    environment: ["CC_METER_PROBE": "visible"])
        )

        XCTAssertEqual(result.standardOutputText, "visible")
    }

    func testThrowsWhenTheExecutableDoesNotExist() {
        XCTAssertThrowsError(
            try runner.run(Command(executable: "/nonexistent/tool"))
        )
    }

    // MARK: - The failure modes the hand-rolled copies got wrong

    /// LoginItem's launchctl call assigned a Pipe to stdout and stderr and then waited without
    /// ever reading them. A child that fills the ~64KB pipe buffer blocks forever on write, and
    /// the parent blocks forever in waitUntilExit. This is that bug, made to happen on purpose.
    func testDoesNotDeadlockWhenTheChildFloodsStandardError() {
        withDeadline {
            let result = try? self.runner.run(
                Command(executable: "/bin/sh",
                        arguments: ["-c", "for i in $(seq 1 40000); do echo 'noisy-diagnostic' >&2; done"],
                        timeout: 10)
            )

            XCTAssertEqual(result?.status, 0)
            XCTAssertGreaterThan(result?.standardError.count ?? 0, 64 * 1024,
                                 "the point of this test is to exceed the pipe buffer")
            XCTAssertEqual(result?.timedOut, false)
        }
    }

    /// The mirror image: input larger than the pipe buffer deadlocks if it is written from the
    /// same thread that later drains stdout. The Keychain blob is small today, but "small today"
    /// is not a design.
    func testDoesNotDeadlockWhenTheInputExceedsThePipeBuffer() {
        let big = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)

        withDeadline {
            let result = try? self.runner.run(
                Command(executable: "/bin/cat", input: big, timeout: 10)
            )

            XCTAssertEqual(result?.standardOutput.count, big.count)
        }
    }

    /// LoginItem and the notifier had no timeout at all: a wedged child wedged the app.
    func testKillsAChildThatOutlivesItsTimeoutAndSaysSo() {
        withDeadline {
            let result = try? self.runner.run(
                Command(executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.5)
            )

            XCTAssertEqual(result?.timedOut, true, "the watchdog fired, so the caller must be told")
            XCTAssertNotEqual(result?.status, 0, "a killed command must not look like a success")
        }
    }

    /// A timed-out command must be reaped, not left running in the background.
    func testTheTimedOutChildIsActuallyDead() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-timeout-\(UUID().uuidString)")

        _ = try? runner.run(
            Command(executable: "/bin/sh",
                    arguments: ["-c", "sleep 1; touch '\(marker.path)'"],
                    timeout: 0.2)
        )

        // If terminate() did not land, the child is still alive and will create the marker.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the child survived the watchdog and kept running")
    }

    // MARK: - Fire and forget

    /// The notifier must not block the main thread waiting on osascript.
    func testLaunchReturnsWithoutWaitingForTheChild() throws {
        let started = Date()

        try runner.launch(Command(executable: "/bin/sh", arguments: ["-c", "sleep 5"]))

        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "launch must not wait for the child to exit")
    }

    func testLaunchThrowsWhenTheExecutableDoesNotExist() {
        XCTAssertThrowsError(try runner.launch(Command(executable: "/nonexistent/tool")))
    }
}
