import Foundation
import XCTest
@testable import CCMeterCore

final class UpdateLogTests: XCTestCase {
    func testLoggerAppendsTimestampedFailures() throws {
        let url = try makeLogURL()
        let logger = FileUpdateLogger(url: url)

        logger.record(
            UpdateFailure(stage: .metadata, detail: "metadata detail"),
            at: Date(timeIntervalSince1970: 0)
        )
        logger.record(
            UpdateFailure(stage: .upgrade, detail: "upgrade detail"),
            at: Date(timeIntervalSince1970: 60)
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(contents.contains("metadata"))
        XCTAssertTrue(contents.contains("metadata detail"))
        XCTAssertTrue(contents.contains("1970-01-01T00:01:00Z"))
        XCTAssertTrue(contents.contains("upgrade"))
        XCTAssertTrue(contents.contains("upgrade detail"))
    }

    func testLoggerBoundsFileAndRetainsNewestEntry() throws {
        let url = try makeLogURL()
        let logger = FileUpdateLogger(url: url)
        logger.record(
            UpdateFailure(stage: .metadata, detail: String(repeating: "a", count: FileUpdateLogger.maxBytes)),
            at: Date(timeIntervalSince1970: 0)
        )
        let marker = "newest-entry-marker"
        let failurePrefix = "exit 42: "

        logger.record(
            UpdateFailure(
                stage: .upgrade,
                detail: failurePrefix
                    + String(repeating: "b", count: FileUpdateLogger.maxBytes)
                    + marker
            ),
            at: Date(timeIntervalSince1970: 60)
        )

        let data = try Data(contentsOf: url)
        let contents = String(decoding: data, as: UTF8.self)
        XCTAssertLessThanOrEqual(data.count, FileUpdateLogger.maxBytes)
        XCTAssertTrue(contents.hasPrefix(
            "1970-01-01T00:01:00Z stage=upgrade detail=\(failurePrefix)"
        ))
        XCTAssertTrue(contents.contains(marker))
    }

    func testLoggerSwallowsFilesystemFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-update-log-test-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = FileUpdateLogger(url: directory.appendingPathComponent("update.log"))

        logger.record(
            UpdateFailure(stage: .upgrade, detail: "must not escape"),
            at: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-update-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("update.log")
    }
}
