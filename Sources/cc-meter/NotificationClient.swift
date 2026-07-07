import Foundation
import CCMeterCore

/// Posts local notifications by shelling out to `osascript`'s `display
/// notification`. cc-meter ships as a bare SwiftPM executable with no app
/// bundle, so `UNUserNotificationCenter` (which requires a bundle identity) is
/// unavailable; `osascript` delivers reliably from any process, mirroring the
/// app's existing use of the Apple-signed `security` tool.
struct OsascriptNotifier: Notifying {
    func post(_ event: NotificationEvent) {
        let script = "display notification \(Self.quote(event.body)) with title \(Self.quote(event.title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // Fire-and-forget: display notification returns quickly and we do not want
        // to block the caller on it. The spawned process outlives this call.
        try? process.run()
    }

    /// Wraps a string as an AppleScript string literal, escaping backslashes and
    /// quotes so user/model-derived text cannot break out of the literal.
    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
