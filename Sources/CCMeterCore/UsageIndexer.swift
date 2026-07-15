import Foundation

/// Where we last stopped reading a file, plus the Codex model/cwd in effect there.
public struct FileCursor: Codable, Equatable {
    public var offset: Int
    public var size: Int
    public var codexModel: String?
    public var codexCwd: String?
    public var codexSessionId: String?
    public init(offset: Int = 0, size: Int = 0, codexModel: String? = nil,
                codexCwd: String? = nil, codexSessionId: String? = nil) {
        self.offset = offset; self.size = size; self.codexModel = codexModel
        self.codexCwd = codexCwd; self.codexSessionId = codexSessionId
    }
}

public protocol CursorStoring: AnyObject {
    func load() -> [String: FileCursor]
    func save(_ cursors: [String: FileCursor])
}

/// Persists cursors as one JSON blob (small: one entry per recently-touched file).
public final class FileCursorStore: CursorStoring {
    private let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-index-cursors.json")
    }

    public func load() -> [String: FileCursor] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: FileCursor].self, from: data)) ?? [:]
    }

    public func save(_ cursors: [String: FileCursor]) {
        guard let data = try? JSONEncoder().encode(cursors) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public final class InMemoryCursorStore: CursorStoring {
    private var cursors: [String: FileCursor]
    public init(_ initial: [String: FileCursor] = [:]) { self.cursors = initial }
    public func load() -> [String: FileCursor] { cursors }
    public func save(_ cursors: [String: FileCursor]) { self.cursors = cursors }
}

/// Reads only the new bytes of recently-touched Claude and Codex log files each tick and folds
/// them into the store. Runs off the main thread. The store dedups by key, so cursor drift or a
/// re-read is a performance issue, never a correctness one.
public final class UsageIndexer {
    private let fileSystem: FileSystemReading
    private let store: UsageEventStoring
    private let cursors: CursorStoring
    private let claudeProjectsDir: String
    private let codexSessionsDir: String
    private let horizon: TimeInterval
    private let maxBytesPerFilePerTick: Int
    private let now: () -> Date

    public init(fileSystem: FileSystemReading, store: UsageEventStoring, cursors: CursorStoring,
                claudeProjectsDir: String, codexSessionsDir: String,
                horizon: TimeInterval = 8*24*3600, maxBytesPerFilePerTick: Int = 16*1024*1024,
                now: @escaping () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.store = store
        self.cursors = cursors
        self.claudeProjectsDir = claudeProjectsDir
        self.codexSessionsDir = codexSessionsDir
        self.horizon = horizon
        self.maxBytesPerFilePerTick = maxBytesPerFilePerTick
        self.now = now
    }

    public static func defaultClaudeProjectsDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    public static func defaultCodexSessionsDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    public func tick() {
        var state = cursors.load()
        let cutoff = now().addingTimeInterval(-horizon)

        let claude = fileSystem.recursiveFiles(inDirectory: claudeProjectsDir, withSuffix: ".jsonl")
        let codex = fileSystem.recursiveFiles(inDirectory: codexSessionsDir, withSuffix: ".jsonl")
        let recent = (claude + codex).filter { $0.modified >= cutoff }
        // Drop cursors for files that aged out of the horizon or were deleted, so the cursor map
        // stays bounded to currently-relevant files (Codex never deletes its rollout files).
        let recentPaths = Set(recent.map(\.path))
        state = state.filter { recentPaths.contains($0.key) }

        for entry in recent {
            let isCodex = entry.path.hasPrefix(codexSessionsDir)
            var cursor = state[entry.path] ?? FileCursor()
            if entry.size < cursor.offset {
                cursor = FileCursor()   // rotated/truncated: re-read from the top
            }
            guard entry.size > cursor.offset else { state[entry.path] = cursor; continue }

            let length = min(maxBytesPerFilePerTick, entry.size - cursor.offset)
            guard let chunk = fileSystem.read(path: entry.path, fromOffset: cursor.offset, length: length),
                  !chunk.isEmpty else { continue }

            // Only parse up to the last complete line; a partial trailing line is re-read next tick.
            guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
                // No newline in the chunk. If the read filled the cap, one line is larger than the
                // cap (e.g. a base64 image pasted into a single JSON record): skip past it so the
                // next tick makes progress - the oversized line is dropped. Otherwise it is a partial
                // trailing line still being written, so leave the cursor and wait for more.
                if length == maxBytesPerFilePerTick {
                    cursor.offset += chunk.count
                    cursor.size = entry.size
                    state[entry.path] = cursor
                }
                continue
            }
            let complete = chunk.prefix(upTo: chunk.index(after: lastNewline))

            if isCodex {
                let seed = CodexParseState(model: cursor.codexModel, cwd: cursor.codexCwd,
                                           sessionId: cursor.codexSessionId)
                let (events, newState) = CodexUsageLogParser.parse(lines: Data(complete), state: seed)
                store.append(events)
                cursor.codexModel = newState.model
                cursor.codexCwd = newState.cwd
                cursor.codexSessionId = newState.sessionId
            } else {
                store.append(ClaudeUsageLogParser.parse(lines: Data(complete)))
            }

            cursor.offset += complete.count
            cursor.size = entry.size
            state[entry.path] = cursor
        }

        cursors.save(state)
    }
}
