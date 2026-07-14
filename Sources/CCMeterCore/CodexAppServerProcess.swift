import Foundation

public final class CodexAppServerProcess: CodexAppServerTransport {
    public init() {}

    public func exchange(executable: CodexExecutable,
                         input: Data,
                         responseIDs: Set<Int>,
                         timeout: TimeInterval) async throws -> [Int: Data] {
        try await withCheckedThrowingContinuation { continuation in
            let session = CodexProcessSession(executable: executable,
                                              input: input,
                                              responseIDs: responseIDs,
                                              timeout: timeout)
            session.start { result in
                continuation.resume(with: result)
            }
        }
    }
}

private final class CodexProcessSession {
    private let executable: CodexExecutable
    private let input: Data
    private let responseIDs: Set<Int>
    private let timeout: TimeInterval
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var responses: [Int: Data] = [:]
    private var completion: ((Result<[Int: Data], Error>) -> Void)?
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var keepAlive: CodexProcessSession?

    init(executable: CodexExecutable, input: Data, responseIDs: Set<Int>, timeout: TimeInterval) {
        self.executable = executable
        self.input = input
        self.responseIDs = responseIDs
        self.timeout = timeout
    }

    func start(completion: @escaping (Result<[Int: Data], Error>) -> Void) {
        keepAlive = self
        self.completion = completion
        process.executableURL = executable.url
        process.arguments = ["app-server", "--stdio"]
        // An npm-installed codex is a `#!/usr/bin/env node` script; under launchd our PATH does
        // not contain node, so the script cannot launch unless we widen the child's PATH.
        if let searchPath = executable.searchPath {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let detail = self.sanitizedStderr()
            let suffix = detail.isEmpty ? "exit \(process.terminationStatus)" : detail
            self.finish(.failure(CodexTransportError.prematureEOF(suffix)))
        }

        do {
            try process.run()
        } catch {
            finish(.failure(CodexTransportError.launch(error.localizedDescription)))
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CodexTransportError.timeout))
        }
        // Under the lock: process.run() has already returned, so the readability and termination
        // handlers can be calling finish() on another queue right now, and finish() reads both of
        // these. The window is nanoseconds and no child can answer that fast, so this has never
        // fired — but "the child is too slow to hit it" is not synchronisation.
        lock.lock()
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()

        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        writeInputIfRunning()
    }

    private func writeInputIfRunning() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(CodexTransportError.prematureEOF(
                "stdin write failed: \(error.localizedDescription)"
            )))
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            lines.append(Data(stdoutBuffer[..<newline]))
            stdoutBuffer.removeSubrange(...newline)
        }
        lock.unlock()

        for line in lines {
            collectResponse(line)
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if stderrBuffer.count < 4096 {
            stderrBuffer.append(data.prefix(4096 - stderrBuffer.count))
        }
        lock.unlock()
    }

    private func collectResponse(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let number = object["id"] as? NSNumber else { return }
        let id = number.intValue
        guard responseIDs.contains(id) else { return }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        responses[id] = line
        let complete = responseIDs.allSatisfy { responses[$0] != nil }
        let collected = responses
        lock.unlock()

        if complete { finish(.success(collected)) }
    }

    private func sanitizedStderr() -> String {
        lock.lock()
        let data = stderrBuffer
        lock.unlock()
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        text = text.replacingOccurrences(of: #"Bearer\s+\S+"#,
                                        with: "Bearer [redacted]",
                                        options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z0-9_.-]{80,}"#,
                                        with: "[redacted]",
                                        options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finish(_ result: Result<[Int: Data], Error>) {
        // Everything the completion path touches comes out under the one lock, and is acted on
        // outside it. The timeout item and the self-retain used to be read and cleared out here
        // in the open, racing start().
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let completion = self.completion
        let timeoutWorkItem = self.timeoutWorkItem
        // Moved into a local before the ivar is cleared. `keepAlive` is our only strong reference:
        // dropping it here, while we still have the lock held and teardown still to do, can
        // deallocate `self` out from under the rest of this function. It stays alive on the stack
        // until the frame ends.
        let retained = self.keepAlive
        self.completion = nil
        self.timeoutWorkItem = nil
        self.keepAlive = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        completion?(result)
        withExtendedLifetime(retained) {}
    }
}
