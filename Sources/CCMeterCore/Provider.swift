import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Equatable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
