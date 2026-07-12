import Foundation
import CCMeterCore

final class CodexAppServerProcess: CodexAppServerTransport {
    func exchange(executable: URL,
                  input: Data,
                  responseID: Int,
                  timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let session = CodexProcessSession(executable: executable,
                                              input: input,
                                              responseID: responseID,
                                              timeout: timeout)
            session.start { result in
                continuation.resume(with: result)
            }
        }
    }
}

private final class CodexProcessSession {
    private let executable: URL
    private let input: Data
    private let responseID: Int
    private let timeout: TimeInterval
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(executable: URL, input: Data, responseID: Int, timeout: TimeInterval) {
        self.executable = executable
        self.input = input
        self.responseID = responseID
        self.timeout = timeout
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
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
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        stdin.fileHandleForWriting.write(input)
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

        for line in lines where responseMatches(line) {
            finish(.success(line))
            return
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

    private func responseMatches(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? NSNumber else { return false }
        return id.intValue == responseID
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

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        completion?(result)
    }
}
