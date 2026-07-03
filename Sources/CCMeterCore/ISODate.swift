import Foundation

/// Parses the ISO8601 timestamps returned by the usage endpoint, which use
/// six fractional-second digits and a "+00:00" style offset.
public enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        if let d = fractional.date(from: s) { return d }
        if let d = plain.date(from: s) { return d }
        // Last resort: strip the fractional seconds and retry the plain form.
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            var stripped = s
            stripped.removeSubrange(dot..<end)
            return plain.date(from: stripped)
        }
        return nil
    }
}
