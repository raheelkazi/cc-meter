import Foundation

/// One file the indexer might read: enough to decide whether it changed and where to resume.
public struct FileEntry: Equatable {
    public let path: String
    public let modified: Date
    public let size: Int
    public init(path: String, modified: Date, size: Int) {
        self.path = path; self.modified = modified; self.size = size
    }
}

/// The one seam over the filesystem, so parsing/indexing is testable without touching real logs.
public protocol FileSystemReading {
    /// Every file under `dir` (recursively) whose path ends in `suffix`.
    func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry]
    /// `length` bytes starting at `offset`. Returns fewer bytes at EOF; nil if the file is unreadable.
    func read(path: String, fromOffset offset: Int, length: Int) -> Data?
}

/// Real Foundation-backed implementation. Pure Foundation, so it lives in Core and stays testable.
public struct SystemFileSystem: FileSystemReading {
    public init() {}

    public func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry] {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else {
            return []
        }
        var out: [FileEntry] = []
        for case let url as URL in en where url.path.hasSuffix(suffix) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            out.append(FileEntry(path: url.path,
                                 modified: values?.contentModificationDate ?? .distantPast,
                                 size: values?.fileSize ?? 0))
        }
        return out
    }

    public func read(path: String, fromOffset offset: Int, length: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: max(0, length)) ?? Data()
        } catch {
            return nil
        }
    }
}

/// In-memory filesystem for tests.
public final class InMemoryFileSystem: FileSystemReading {
    private var files: [String: (data: Data, modified: Date)] = [:]
    public init() {}

    public func addFile(path: String, contents: Data, modified: Date) {
        files[path] = (contents, modified)
    }

    public func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry] {
        files.filter { $0.key.hasPrefix(dir) && $0.key.hasSuffix(suffix) }
            .map { FileEntry(path: $0.key, modified: $0.value.modified, size: $0.value.data.count) }
            .sorted { $0.path < $1.path }
    }

    public func read(path: String, fromOffset offset: Int, length: Int) -> Data? {
        guard let data = files[path]?.data, offset <= data.count else {
            return files[path] == nil ? nil : Data()
        }
        let end = min(data.count, offset + length)
        return data.subdata(in: offset..<end)
    }
}
