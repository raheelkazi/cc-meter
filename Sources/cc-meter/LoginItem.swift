import Foundation
import CCMeterCore

/// Enables/disables "launch at login" by installing a per-user LaunchAgent and
/// (un)loading it with launchctl. This is the right mechanism for a bare
/// executable: `SMAppService.mainApp` needs a signed .app bundle, which cc-meter
/// (a SwiftPM binary installed via Homebrew) does not have.
enum LoginItem {
    private static let fileManager = FileManager.default

    private static var home: URL { fileManager.homeDirectoryForCurrentUser }
    private static var plistURL: URL { LaunchAgent.plistURL(home: home) }

    /// Absolute path to the currently running executable, resolving symlinks so
    /// the LaunchAgent points at the real binary (e.g. the Homebrew cellar path).
    static var executablePath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "cc-meter"
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    static var isEnabled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// Installs or removes the LaunchAgent to match `enabled`. Best-effort: any
    /// failure is swallowed so a sandbox/permission issue never crashes the app.
    static func setEnabled(_ enabled: Bool) {
        enabled ? install() : remove()
    }

    private static func install() {
        let plist = LaunchAgent.plist(programPath: executablePath)
        do {
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try plist.data(using: .utf8)?.write(to: plistURL, options: .atomic)
            runLaunchctl(["bootout", domainTarget()])   // clear any stale registration
            runLaunchctl(["bootstrap", guiDomain(), plistURL.path])
        } catch {
            // Best-effort; leave the app running regardless.
        }
    }

    private static func remove() {
        runLaunchctl(["bootout", domainTarget()])
        try? fileManager.removeItem(at: plistURL)
    }

    private static func guiDomain() -> String { "gui/\(getuid())" }
    private static func domainTarget() -> String { "gui/\(getuid())/\(LaunchAgent.label)" }

    private static let runner: CommandRunning = SystemCommandRunner()

    /// This used to hand launchctl a Pipe for stdout and stderr and then wait on it without ever
    /// reading either one. A child that fills the ~64KB pipe buffer blocks forever on write while
    /// the parent blocks forever in waitUntilExit — and there was no timeout to break the tie.
    /// The shared runner drains both pipes concurrently and kills anything that overstays.
    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let command = Command(executable: "/bin/launchctl", arguments: arguments, timeout: 10)
        guard let result = try? runner.run(command) else { return -1 }
        return result.status
    }
}
