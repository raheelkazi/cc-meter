import Foundation

/// Maps a working-directory path to the project name shown in the Usage tab.
///
/// Worktree checkouts would otherwise appear as separate projects. A Claude worktree lives at
/// `<project>/.claude/worktrees/<branch>`, so it is mapped back to the `<project>` component that
/// precedes `.claude`. Codex worktrees are `~/.codex/worktrees/<hash>/<project>` and already end
/// in the project name, so the leaf is correct there.
public enum ProjectName {
    public static func from(cwd: String) -> String {
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return cwd }
        if let i = parts.firstIndex(of: "worktrees"), i >= 2, parts[i - 1] == ".claude" {
            return parts[i - 2]
        }
        return parts.last ?? cwd
    }
}
