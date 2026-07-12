import Foundation

public protocol UpdateLogging {
    func record(_ failure: UpdateFailure, at date: Date)
}

public final class FileUpdateLogger: UpdateLogging {
    public static let maxBytes = 64 * 1024

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/cc-meter/update.log")
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL = FileUpdateLogger.defaultURL) {
        self.url = url
    }

    public func record(_ failure: UpdateFailure, at date: Date) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime]
            let entry = "\(formatter.string(from: date)) stage=\(failure.stage.rawValue) detail=\(failure.detail)\n"
            let existing = (try? Data(contentsOf: url)) ?? Data()
            var combined = existing
            combined.append(Data(entry.utf8))
            let retained = Data(combined.suffix(Self.maxBytes))

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try retained.write(to: url, options: .atomic)
        } catch {
            // Update diagnostics must never interfere with the menu-bar app.
        }
    }
}
