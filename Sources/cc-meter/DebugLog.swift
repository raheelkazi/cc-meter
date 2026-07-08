import Foundation

/// Temporary env-gated startup tracer (set CCMETER_DEBUG_LOG=1) to diagnose a
/// launchd-only clean-exit. Writes to stderr so a LaunchAgent's StandardErrorPath
/// captures it.
enum DebugLog {
    private static let enabled = ProcessInfo.processInfo.environment["CCMETER_DEBUG_LOG"] != nil
    static func log(_ message: String) {
        guard enabled else { return }
        fputs("[ccmeter] \(message)\n", stderr)
        fflush(stderr)
    }
}
