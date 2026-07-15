import XCTest
@testable import CCMeterCore

final class FileSystemReadingTests: XCTestCase {
    func testInMemoryListsBySuffixAndReadsRanges() {
        let fs = InMemoryFileSystem()
        fs.addFile(path: "/logs/a.jsonl", contents: Data("hello\nworld".utf8),
                   modified: Date(timeIntervalSince1970: 100))
        fs.addFile(path: "/logs/b.txt", contents: Data("nope".utf8),
                   modified: Date(timeIntervalSince1970: 100))

        let entries = fs.recursiveFiles(inDirectory: "/logs", withSuffix: ".jsonl")
        XCTAssertEqual(entries.map(\.path), ["/logs/a.jsonl"])
        XCTAssertEqual(entries.first?.size, 11)

        XCTAssertEqual(fs.read(path: "/logs/a.jsonl", fromOffset: 6, length: 5), Data("world".utf8))
        XCTAssertEqual(fs.read(path: "/logs/a.jsonl", fromOffset: 6, length: 999), Data("world".utf8))
        XCTAssertNil(fs.read(path: "/missing", fromOffset: 0, length: 1))
    }

    func testSystemFileSystemReadsARealFileRange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccm-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.jsonl")
        try Data("0123456789".utf8).write(to: file)

        let fs = SystemFileSystem()
        let entries = fs.recursiveFiles(inDirectory: dir.path, withSuffix: ".jsonl")
        XCTAssertEqual(entries.map { ($0.path as NSString).lastPathComponent }, ["x.jsonl"])
        XCTAssertEqual(fs.read(path: file.path, fromOffset: 3, length: 4), Data("3456".utf8))
    }
}
