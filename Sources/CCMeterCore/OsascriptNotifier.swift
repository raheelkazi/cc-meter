import Foundation

/// Posts local notifications by shelling out to `osascript`'s `display notification`.
///
/// cc-meter ships as a bare SwiftPM executable with no app bundle, so `UNUserNotificationCenter`
/// (which requires a bundle identity) is unavailable; `osascript` delivers from any process,
/// mirroring the app's existing use of the Apple-signed `security` tool.
///
/// Lives in the core module, rather than beside the AppKit code, so the AppleScript quoting is
/// reachable from tests: the title and body are built from fetched data, and an unescaped quote
/// in them would break out of the string literal and change what AppleScript executes.
public struct OsascriptNotifier: Notifying {
    private let runner: CommandRunning

    public init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    public func post(_ event: NotificationEvent) {
        // Fire-and-forget: `display notification` returns quickly, and post() is called from the
        // main actor on the refresh path, which must never block on a child process.
        try? runner.launch(Self.command(for: event))
    }

    static func command(for event: NotificationEvent) -> Command {
        let script = "display notification \(quote(event.body)) with title \(quote(event.title))"
        return Command(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    /// Wraps a string as an AppleScript string literal, escaping backslashes and quotes so
    /// data-derived text cannot break out of the literal.
    ///
    /// Backslashes are escaped *first*: escaping quotes first would turn `\` + `"` into `\` + `\"`
    /// and then double the original backslash into `\\\"`, re-exposing the quote.
    private static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
