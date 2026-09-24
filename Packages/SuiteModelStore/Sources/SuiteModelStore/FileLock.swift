import Foundation

/// An advisory `flock(2)` lock on a file.
///
/// flock locks belong to the open file description, so two `FileLock`s on the same path conflict
/// whether they live in different processes or in the same one — which is what makes a single
/// mechanism serve both "two apps" and "two tasks in one app".
///
/// Acquisition polls with `LOCK_NB` and `Task.sleep` instead of blocking, so waiting never parks a
/// Swift-concurrency cooperative thread and is cancellable.
///
/// Lock files are never deleted (deleting a lock file while another process has it open is the
/// classic way to end up with two holders).
public final class FileLock: @unchecked Sendable {
    public enum Mode: Sendable { case shared, exclusive }

    public let url: URL
    private var fd: Int32 = -1
    private let mutex = NSLock()

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { releaseLocked() }

    /// Waits until the lock is acquired. `onWait` is called once if the lock was contended.
    public static func acquire(
        _ url: URL, mode: Mode = .exclusive, pollInterval: Duration = .milliseconds(25),
        onWait: (@Sendable () -> Void)? = nil
    ) async throws -> FileLock {
        var notified = false
        while true {
            if let lock = try tryAcquire(url, mode: mode) { return lock }
            if !notified { onWait?(); notified = true }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Returns nil if someone else holds a conflicting lock.
    public static func tryAcquire(_ url: URL, mode: Mode = .exclusive) throws -> FileLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ModelStoreError.lockFailed(path: url.path, errno: errno) }
        let op = (mode == .exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        while true {
            if flock(fd, op) == 0 { return FileLock(url: url, fd: fd) }
            let err = errno
            if err == EINTR { continue }
            close(fd)
            if err == EWOULDBLOCK { return nil }
            throw ModelStoreError.lockFailed(path: url.path, errno: err)
        }
    }

    /// True if some holder currently has a conflicting lock on `url` (probe only).
    public static func isLocked(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let lock = try? tryAcquire(url) else { return true }
        lock.release()
        return false
    }

    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        releaseLocked()
    }

    private func releaseLocked() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
