import Foundation

/// Maps a working-directory path to the project name shown in the Usage tab.
///
/// Worktree checkouts would otherwise appear as separate projects; a `.claude-worktrees`
/// segment is mapped back to its parent project. Codex worktrees already end in the project
/// name (`.codex/worktrees/<hash>/<project>`), so the leaf is correct there.
public enum ProjectName {
    public static func from(cwd: String) -> String {
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return cwd }
        if let i = parts.firstIndex(of: ".claude-worktrees"), i > 0 {
            return parts[i - 1]
        }
        return parts.last ?? cwd
    }
}
