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
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()

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
            guard let self else { return }
            self.readAvailableData(from: handle, synchronizedBy: self.stdoutReadLock)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.readAvailableData(from: handle, synchronizedBy: self.stderrReadLock)
        }
        process.terminationHandler = { [weak self] process in
            self?.finishAfterTermination(status: process.terminationStatus)
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

    private func readAvailableData(from handle: FileHandle, synchronizedBy readLock: NSLock) {
        readLock.withLock {
            consume(handle.availableData)
        }
    }

    private func finishAfterTermination(status: Int32) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutReadLock.withLock {
            consume(stdout.fileHandleForReading.readDataToEndOfFile())
        }
        stderrReadLock.withLock {
            consume(stderr.fileHandleForReading.readDataToEndOfFile())
        }
        finish(.success(UpdateCommandResult(
            status: status,
            output: capturedText()
        )))
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
        // Held on the stack until the frame ends. `retainedSelf` is our only strong reference, so
        // clearing the ivar here — with the lock still held and teardown still to come — can
        // deallocate `self` out from under the rest of this function.
        let retained = retainedSelf
        retainedSelf = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        completion?(result)
        withExtendedLifetime(retained) {}
    }
}
