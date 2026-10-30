import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `realpath(3)`: every symbolic link resolved, as Node's `fs.realpath` resolves them. Unlike
/// Foundation's `resolvingSymlinksInPath`, it keeps the `/private` that `/tmp` and `/var` lead
/// to on macOS. nil when the path does not exist.
public func resolvedRealPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
