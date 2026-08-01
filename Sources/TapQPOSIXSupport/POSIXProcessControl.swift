import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small process-control operations kept behind the POSIX support boundary so portable
/// clients do not import platform C modules directly.
package enum POSIXProcessControl {
    /// Sends an unconditional termination signal to one known child process.
    ///
    /// The caller must first resolve the exact process identifier and exhaust graceful
    /// termination. This deliberately accepts no names, globs, process groups, or other
    /// broad targets.
    package static func forceTerminate(processIdentifier: Int32) {
        guard processIdentifier > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(processIdentifier, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(processIdentifier, SIGKILL)
        #endif
    }
}
