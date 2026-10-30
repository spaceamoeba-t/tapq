import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One kernel per workspace (§8): an exclusive `flock` on a file in the kernel directory.
///
/// `run` takes it for the life of the process; the descriptor is never closed, so the OS
/// releases the lock at exit however the process ends, crash and SIGKILL included. `clear`
/// takes it before deleting, so it can never delete under a running kernel. `O_CLOEXEC`
/// keeps it out of every child, or a delegate that outlived the kernel would hold it.
enum KernelWorkspaceLock {
    static let fileName = "kernel.lock"

    /// True when this process now holds the lock; false when another process does.
    static func acquire(in directory: URL) throws -> Bool {
        let path = directory.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw KernelStartupFailure(subsystem: "startup",
                                       reason: "could not open \(path): \(errorText())")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            let detail = errorText()
            close(descriptor)
            if busy { return false }
            throw KernelStartupFailure(subsystem: "startup",
                                       reason: "could not lock \(path): \(detail)")
        }
        return true
    }

    private static func errorText() -> String {
        String(cString: strerror(errno))
    }
}
