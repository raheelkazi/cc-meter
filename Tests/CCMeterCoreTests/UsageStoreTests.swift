import XCTest
@testable import CCMeterCore

final class UsageStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-usage.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func sampleSaved() -> SavedUsage {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let usage = Usage(limits: [
            UsageLimit(kind: .session, percent: 3,
                       resetsAt: now.addingTimeInterval(3600), isActive: false),
            UsageLimit(kind: .weeklyScoped(model: "Fable"), percent: 54,
                       resetsAt: now.addingTimeInterval(3600), isActive: true)
        ], fetchedAt: now)
        return SavedUsage(usage: usage, savedAt: now)
    }

    func testSaveThenLoadRoundTrips() {
        let store = DiskUsageStore(fileURL: fileURL)
        let saved = sampleSaved()
        store.save(saved)
        XCTAssertEqual(store.load(), saved)
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(DiskUsageStore(fileURL: fileURL).load())
    }

    func testLoadReturnsNilOnCorruptFile() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(DiskUsageStore(fileURL: fileURL).load())
    }

    func testSaveCreatesIntermediateDirectories() {
        // The Application Support subfolder does not exist on first run.
        let store = DiskUsageStore(fileURL: fileURL)
        store.save(sampleSaved())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testProviderStandardCachesUseDistinctFilenames() {
        XCTAssertTrue(DiskUsageStore.standard(provider: .claude).fileURL.path
            .hasSuffix("last-usage.json"))
        XCTAssertTrue(DiskUsageStore.standard(provider: .codex).fileURL.path
            .hasSuffix("last-usage-codex.json"))
    }
}
