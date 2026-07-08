import Foundation

/// Prevents a second cc-meter from running at once. Launch-at-login plus a manual
/// start (terminal, Homebrew, `swift run`) would otherwise put two menu bar items
/// up, each polling the shared usage endpoint and each able to refresh the OAuth
/// token independently. An advisory `flock` on a lock file, held for the process
/// lifetime, is a simple cross-process mutex that the OS releases automatically
/// on exit (even on crash).
enum SingleInstance {
    // Retained for the process lifetime so the lock is held until we exit.
    private static var lockDescriptor: Int32 = -1

    /// Returns true if this process acquired the lock (i.e. it is the only
    /// instance). Returns false when another instance already holds it. If the
    /// lock file can't be opened at all, we fail open (allow startup) rather than
    /// block the app over a best-effort guard.
    static func acquire() -> Bool {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-meter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("instance.lock").path

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        lockDescriptor = fd
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
