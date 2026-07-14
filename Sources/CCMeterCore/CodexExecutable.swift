import Foundation

/// A resolved codex CLI together with the PATH its process needs to launch.
///
/// The search path matters because npm ships codex as a `#!/usr/bin/env node` script: launching
/// it requires `node` on the child's PATH. cc-meter runs as a launchd agent, whose PATH is only
/// `/usr/bin:/bin:/usr/sbin:/sbin`, so without this the script cannot start.
public struct CodexExecutable: Equatable {
    public let url: URL
    /// PATH for the spawned process. `nil` inherits the parent environment unchanged.
    public let searchPath: String?

    public init(url: URL, searchPath: String?) {
        self.url = url
        self.searchPath = searchPath
    }
}

public protocol LoginShellPathProviding {
    /// PATH as the user's login shell sees it, or `nil` if it cannot be read.
    func loginShellPath() -> String?
}

/// Reads PATH from the user's login shell.
///
/// Version managers (nvm, fnm, volta, asdf) and custom npm prefixes install codex on a PATH
/// launchd never hands us, so the shell is the only way to find those installs. It is run
/// interactively (`-i`) as well as as a login shell (`-l`) because nvm's installer appends to
/// `~/.zshrc`, which non-interactive shells skip. Output is fenced with markers so a chatty rc
/// file cannot corrupt the result, and the read is abandoned on timeout so a hanging rc file
/// cannot wedge the menu bar's refresh.
public final class LoginShellPath: LoginShellPathProviding {
    private static let startMarker = "__CC_METER_PATH__"
    private static let endMarker = "__CC_METER_END__"

    private let shell: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    /// Outer `nil` means "not read yet"; inner `nil` means "read, and unavailable".
    private var cached: String??

    public init(shell: String? = nil, timeout: TimeInterval = 5) {
        self.shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.timeout = timeout
    }

    public func loginShellPath() -> String? {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = readFromLoginShell()

        lock.lock()
        cached = value
        lock.unlock()
        return value
    }

    private func readFromLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [
            "-i", "-l", "-c",
            "printf '\(Self.startMarker)%s\(Self.endMarker)' \"$PATH\""
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.extractPath(from: text)
    }

    private static func extractPath(from text: String) -> String? {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }
}
