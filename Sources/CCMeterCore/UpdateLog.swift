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
            let prefix = "\(formatter.string(from: date)) stage=\(failure.stage.rawValue) detail="
            let detailByteLimit = Self.maxBytes - prefix.utf8.count - 1
            let detail = Self.boundedDetail(failure.detail, maxUTF8Bytes: detailByteLimit)
            let entry = Data("\(prefix)\(detail)\n".utf8)
            let existing = (try? Data(contentsOf: url)) ?? Data()
            var retained = Data(existing.suffix(Self.maxBytes - entry.count))
            retained.append(entry)

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try retained.write(to: url, options: .atomic)
        } catch {
            // Update diagnostics must never interfere with the menu-bar app.
        }
    }

    private static func boundedDetail(_ detail: String, maxUTF8Bytes: Int) -> String {
        guard detail.utf8.count > maxUTF8Bytes else { return detail }

        let marker = "…"
        let markerBytes = marker.utf8.count
        guard maxUTF8Bytes >= markerBytes else {
            return prefix(of: detail, fittingUTF8Bytes: maxUTF8Bytes)
        }

        let contentBytes = maxUTF8Bytes - markerBytes
        let head = prefix(of: detail, fittingUTF8Bytes: (contentBytes + 1) / 2)
        let tail = suffix(of: detail, fittingUTF8Bytes: contentBytes - head.utf8.count)
        return head + marker + tail
    }

    private static func prefix(of value: String, fittingUTF8Bytes limit: Int) -> String {
        var index = value.startIndex
        var byteCount = 0
        while index < value.endIndex {
            let next = value.index(after: index)
            let characterBytes = value[index..<next].utf8.count
            guard byteCount + characterBytes <= limit else { break }
            byteCount += characterBytes
            index = next
        }
        return String(value[..<index])
    }

    private static func suffix(of value: String, fittingUTF8Bytes limit: Int) -> String {
        var index = value.endIndex
        var byteCount = 0
        while index > value.startIndex {
            let previous = value.index(before: index)
            let characterBytes = value[previous..<index].utf8.count
            guard byteCount + characterBytes <= limit else { break }
            byteCount += characterBytes
            index = previous
        }
        return String(value[index...])
    }
}
