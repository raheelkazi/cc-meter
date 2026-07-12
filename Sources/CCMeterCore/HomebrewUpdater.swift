import Foundation

public enum HomebrewUpdateStage: String, Equatable {
    case metadata
    case outdated
    case upgrade
}

public struct UpdateFailure: Equatable {
    public let stage: HomebrewUpdateStage
    public let detail: String

    public init(stage: HomebrewUpdateStage, detail: String) {
        self.stage = stage
        self.detail = detail
    }
}

public enum AutomaticUpdateOutcome: Equatable {
    case unsupported
    case upToDate
    case updated
    case failed(UpdateFailure)
}

public protocol AutomaticUpdating: AnyObject {
    var isSupported: Bool { get }
    func installIfAvailable() async -> AutomaticUpdateOutcome
}

public struct UpdateCommandResult: Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public enum UpdateCommandError: Error, Equatable {
    case launch(String)
    case timeout(String)
}

public protocol UpdateCommandRunning: AnyObject {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> UpdateCommandResult
}

public protocol HomebrewExecutableResolving {
    func resolve() -> URL?
}

public struct HomebrewExecutableResolver: HomebrewExecutableResolving {
    private let candidates: [URL]
    private let fileManager: FileManager

    public init(
        candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew")
        ],
        fileManager: FileManager = .default
    ) {
        self.candidates = candidates
        self.fileManager = fileManager
    }

    public func resolve() -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

public final class HomebrewUpdater: AutomaticUpdating {
    private static let serviceName = "homebrew.mxcl.cc-meter"
    private static let formula = "raheelkazi/tap/cc-meter"
    private static let metadataTimeout: TimeInterval = 120
    private static let upgradeTimeout: TimeInterval = 900
    private static let outputLimit = 64 * 1024

    private let resolver: HomebrewExecutableResolving
    private let runner: UpdateCommandRunning
    private let environment: [String: String]

    public init(
        resolver: HomebrewExecutableResolving,
        runner: UpdateCommandRunning,
        environment: [String: String]
    ) {
        self.resolver = resolver
        self.runner = runner
        self.environment = environment
    }

    public var isSupported: Bool {
        environment["XPC_SERVICE_NAME"] == Self.serviceName && resolver.resolve() != nil
    }

    public func installIfAvailable() async -> AutomaticUpdateOutcome {
        guard isSupported, let brew = resolver.resolve() else {
            return .unsupported
        }

        switch await run(
            stage: .metadata,
            brew: brew,
            arguments: ["update-if-needed"],
            timeout: Self.metadataTimeout
        ) {
        case .success:
            break
        case .failure(let failure):
            return .failed(failure)
        }

        let outdated: UpdateCommandResult
        switch await run(
            stage: .outdated,
            brew: brew,
            arguments: ["outdated", "--quiet", "--formula", Self.formula],
            timeout: Self.metadataTimeout
        ) {
        case .success(let result):
            outdated = result
        case .failure(let failure):
            return .failed(failure)
        }

        let names = Set(outdated.output.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        })
        guard names.contains("cc-meter") || names.contains(Self.formula) else {
            return .upToDate
        }

        switch await run(
            stage: .upgrade,
            brew: brew,
            arguments: ["upgrade", "--formula", Self.formula],
            timeout: Self.upgradeTimeout
        ) {
        case .success:
            return .updated
        case .failure(let failure):
            return .failed(failure)
        }
    }

    private enum StageResult {
        case success(UpdateCommandResult)
        case failure(UpdateFailure)
    }

    private func run(
        stage: HomebrewUpdateStage,
        brew: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> StageResult {
        do {
            let result = try await runner.run(
                executable: brew,
                arguments: arguments,
                timeout: timeout,
                maxOutputBytes: Self.outputLimit
            )
            guard result.status == 0 else {
                let detail = result.output.isEmpty
                    ? "Exited with status \(result.status)"
                    : "Exited with status \(result.status): \(result.output)"
                return .failure(UpdateFailure(stage: stage, detail: detail))
            }
            return .success(result)
        } catch let error as UpdateCommandError {
            let detail: String
            switch error {
            case .launch(let output):
                detail = "launch failed: \(output)"
            case .timeout(let output):
                detail = "timeout: \(output)"
            }
            return .failure(UpdateFailure(stage: stage, detail: detail))
        } catch {
            return .failure(UpdateFailure(stage: stage, detail: String(describing: error)))
        }
    }
}
