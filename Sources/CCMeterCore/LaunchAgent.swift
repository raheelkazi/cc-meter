import Foundation

/// Builds the per-user LaunchAgent that relaunches cc-meter at login. Kept as
/// pure string/URL construction (no file IO) so the generated plist can be
/// unit-tested; the executable layer handles writing it and calling launchctl.
public enum LaunchAgent {
    public static let label = "com.raheelkazi.cc-meter"

    /// The launchd plist XML that runs `programPath` at login and keeps it alive.
    public static func plist(label: String = label, programPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(programPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    /// ~/Library/LaunchAgents/<label>.plist for the given home directory.
    public static func plistURL(home: URL, label: String = label) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}
