import Foundation
import XCTest
@testable import CCMeterCore

final class UpdateCommandProcessTests: XCTestCase {
    func testRunnerPassesArgumentsAndCapturesBoundedOutput() async throws {
        let script = try makeScript("""
        #!/bin/sh
        printf '%s\\n' "$@"
        printf 'stderr-line\\n' >&2
        """)

        let result = try await UpdateCommandProcess().run(
            executable: script,
            arguments: ["one", "two"],
            timeout: 2,
            maxOutputBytes: 64 * 1024
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("one\ntwo"))
        XCTAssertTrue(result.output.contains("stderr-line"))
    }

    func testRunnerTimesOutAndReturnsCapturedOutput() async {
        let script = try! makeScript("""
        #!/bin/sh
        printf 'before-timeout\\n'
        sleep 5
        """)

        do {
            _ = try await UpdateCommandProcess().run(
                executable: script,
                arguments: [],
                timeout: 0.5,
                maxOutputBytes: 1024
            )
            XCTFail("expected timeout")
        } catch let error as UpdateCommandError {
            guard case .timeout(let output) = error else {
                return XCTFail("expected timeout, got \(error)")
            }
            XCTAssertTrue(
                output.contains("before-timeout"),
                "captured timeout output: \(output.debugDescription)"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunnerDrainsLargeOutputWhileBoundingCapturedBytes() async throws {
        let script = try makeScript("""
        #!/bin/sh
        awk 'BEGIN { for (i = 0; i < 200000; i++) printf "x" }'
        awk 'BEGIN { for (i = 0; i < 200000; i++) printf "y" }' >&2
        """)
        let limit = 1024

        let result = try await UpdateCommandProcess().run(
            executable: script,
            arguments: [],
            timeout: 2,
            maxOutputBytes: limit
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.output.utf8.count, limit)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testRunnerReportsLaunchFailureForMissingExecutable() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-missing-\(UUID().uuidString)")

        do {
            _ = try await UpdateCommandProcess().run(
                executable: missing,
                arguments: [],
                timeout: 2,
                maxOutputBytes: 1024
            )
            XCTFail("expected launch failure")
        } catch let error as UpdateCommandError {
            guard case .launch(let detail) = error else {
                return XCTFail("expected launch failure, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("command")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }
}
