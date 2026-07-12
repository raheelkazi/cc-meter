import Foundation

public final class UpdateCommandProcess: UpdateCommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> UpdateCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            ProcessSession(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                maxOutputBytes: max(0, maxOutputBytes)
            ).start { result in
                continuation.resume(with: result)
            }
        }
    }
}

private final class ProcessSession {
    typealias Completion = (Result<UpdateCommandResult, UpdateCommandError>) -> Void

    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let timeout: TimeInterval
    private let maxOutputBytes: Int
    private let lock = NSLock()

    private var output = Data()
    private var completion: Completion?
    private var timeoutWorkItem: DispatchWorkItem?
    private var retainedSelf: ProcessSession?

    init(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) {
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start(completion: @escaping Completion) {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.finish(.success(UpdateCommandResult(
                status: process.terminationStatus,
                output: self.capturedText()
            )))
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.failure(.timeout(self.capturedText())))
        }
        lock.lock()
        self.completion = completion
        self.timeoutWorkItem = timeoutWorkItem
        retainedSelf = self
        lock.unlock()

        do {
            try process.run()
        } catch {
            finish(.failure(.launch(error.localizedDescription)))
            return
        }

        DispatchQueue.global().asyncAfter(
            deadline: .now() + max(0, timeout),
            execute: timeoutWorkItem
        )
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard completion != nil, output.count < maxOutputBytes else { return }
        output.append(data.prefix(maxOutputBytes - output.count))
    }

    private func capturedText() -> String {
        lock.lock()
        let data = output
        lock.unlock()

        var text = String(decoding: data, as: UTF8.self)
        while text.utf8.count > maxOutputBytes {
            text.removeLast()
        }
        return text
    }

    private func finish(_ result: Result<UpdateCommandResult, UpdateCommandError>) {
        let completion: Completion?
        let timeoutWorkItem: DispatchWorkItem?

        lock.lock()
        completion = self.completion
        guard completion != nil else {
            lock.unlock()
            return
        }
        self.completion = nil
        timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        retainedSelf = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        completion?(result)
    }
}
