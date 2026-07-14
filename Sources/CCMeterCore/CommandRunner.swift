import Foundation

/// A command to run to completion.
public struct Command: Equatable {
    public let executable: String
    public let arguments: [String]
    /// Written to the child's stdin, which is then closed. `nil` gives the child no stdin pipe.
    public let input: Data?
    /// The child's full environment. `nil` inherits ours unchanged.
    public let environment: [String: String]?
    /// The child is killed if it outlives this. Applies to `run` only.
    public let timeout: TimeInterval

    public init(executable: String,
                arguments: [String] = [],
                input: Data? = nil,
                environment: [String: String]? = nil,
                timeout: TimeInterval = 15) {
        self.executable = executable
        self.arguments = arguments
        self.input = input
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandResult: Equatable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data
    /// The watchdog killed it. `status` then reflects the signal, not anything the command decided.
    public let timedOut: Bool

    public init(status: Int32, standardOutput: Data, standardError: Data, timedOut: Bool) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var isSuccess: Bool { status == 0 && !timedOut }

    public var standardOutputText: String { Self.text(standardOutput) }
    public var standardErrorText: String { Self.text(standardError) }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// What to put in an error message when the command failed. Callers used to report bare exit
    /// codes, which say nothing; the child almost always explained itself on stderr.
    public var failureDescription: String {
        if timedOut { return "timed out" }
        let reason = standardErrorText
        return reason.isEmpty ? "exited \(status)" : "exited \(status): \(reason)"
    }
}

public enum CommandError: Error, Equatable {
    /// The process could not be spawned at all: no such executable, not executable, and so on.
    case launchFailed(String)
}

/// Runs external commands. A seam, so credential and update paths can be tested without touching
/// the real Keychain or Homebrew — and, more importantly, so every spawn in the app goes through
/// one implementation that gets the pipe handling and the timeout right.
public protocol CommandRunning {
    /// Runs to completion (or to the timeout) and returns what it printed.
    func run(_ command: Command) throws -> CommandResult
    /// Spawns and returns immediately. The child outlives the call and its output is discarded.
    func launch(_ command: Command) throws
}

/// The one place in the app that spawns a process.
///
/// This replaced four hand-rolled copies of "launch, maybe write stdin, capture stdout, wait,
/// check status", which had drifted into three different sets of bugs:
///
/// - Two of them assigned a `Pipe` to stdout/stderr and then waited **without reading it**. A
///   child that fills the ~64KB pipe buffer blocks forever on `write`, and the parent blocks
///   forever in `waitUntilExit`. Both pipes are therefore drained concurrently here, and so is
///   stdin — a large enough input deadlocks the same way, in reverse.
/// - Two of them had no timeout, so a wedged child wedged the app with no error and no recovery.
/// - All of them discarded stderr, so every failure was reported as a bare exit code.
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: Command) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment = command.environment { process.environment = environment }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdin = Pipe()
        if command.input != nil { process.standardInput = stdin }

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes and fill stdin concurrently: whichever one the child blocks on, some
        // other thread is already servicing it. Doing any of these in sequence on this thread is
        // the deadlock described above.
        let drain = DispatchGroup()
        var outputData = Data()
        var errorData = Data()

        DispatchQueue.global(qos: .utility).async(group: drain) {
            outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: drain) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        if let input = command.input {
            DispatchQueue.global(qos: .utility).async(group: drain) {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                // Without the close the child waits on an EOF that never comes.
                try? stdin.fileHandleForWriting.close()
            }
        }

        let expired = Flag()
        let watchdog = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            expired.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + command.timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        // The child is gone, so every pipe is at EOF and this returns promptly. Joining here is
        // what guarantees `outputData`/`errorData` are fully written before we read them.
        drain.wait()

        return CommandResult(status: process.terminationStatus,
                             standardOutput: outputData,
                             standardError: errorData,
                             timedOut: expired.isSet)
    }

    public func launch(_ command: Command) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment = command.environment { process.environment = environment }
        // Not pipes: nobody is left to drain them, and an undrained pipe is how the child
        // eventually hangs. /dev/null can absorb anything it has to say.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }
    }
}

/// A set-once boolean shared between the watchdog's queue and the calling thread.
private final class Flag {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
