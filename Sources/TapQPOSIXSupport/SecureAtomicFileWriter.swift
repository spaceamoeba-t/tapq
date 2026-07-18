import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum SecureAtomicWriteDisposition {
    /// Atomically replaces the destination after the complete temporary file is durable.
    case replaceExisting
    /// Atomically publishes a new destination and fails rather than replacing an existing file.
    case createNew
}

package protocol SecureAtomicFileWriting {
    func write(
        _ data: Data,
        to destination: URL,
        mode: UInt16,
        disposition: SecureAtomicWriteDisposition
    ) throws
}

/// Writes a complete sibling temporary file with restrictive permissions, then publishes it
/// atomically. The destination is never exposed with the process umask's default permissions.
package struct POSIXSecureAtomicFileWriter: SecureAtomicFileWriting {
    package init() {}

    package func write(
        _ data: Data,
        to destination: URL,
        mode: UInt16,
        disposition: SecureAtomicWriteDisposition
    ) throws {
        let temporaryURL = try makeTemporaryFile(beside: destination)
        var descriptor = temporaryURL.descriptor

        defer {
            if descriptor >= 0 {
                _ = systemClose(descriptor)
            }
            // After rename this path is already absent. After link it is the extra temporary
            // name. On every error it removes the incomplete file.
            _ = systemUnlink(temporaryURL.url.path)
        }

        try writeAll(data, to: descriptor, path: temporaryURL.url.path)
        try changeMode(descriptor, to: mode, path: temporaryURL.url.path)
        try synchronize(descriptor, path: temporaryURL.url.path)

        let descriptorToClose = descriptor
        descriptor = -1
        guard systemClose(descriptorToClose) == 0 else {
            throw POSIXFileOperationError(
                operation: "close",
                path: temporaryURL.url.path,
                code: errno
            )
        }

        switch disposition {
        case .replaceExisting:
            guard systemRename(temporaryURL.url.path, destination.path) == 0 else {
                throw POSIXFileOperationError(
                    operation: "rename",
                    path: destination.path,
                    code: errno
                )
            }
        case .createNew:
            // A hard link publishes the already-complete sibling inode atomically while
            // retaining O_EXCL semantics for the final backup name.
            guard systemLink(temporaryURL.url.path, destination.path) == 0 else {
                throw POSIXFileOperationError(
                    operation: "link",
                    path: destination.path,
                    code: errno
                )
            }
        }
    }

    private func makeTemporaryFile(
        beside destination: URL
    ) throws -> (url: URL, descriptor: Int32) {
        let directory = destination.deletingLastPathComponent()
        for _ in 0..<16 {
            let name = ".\(destination.lastPathComponent).tapq-tmp-\(UUID().uuidString)"
            let url = directory.appendingPathComponent(name)
            let descriptor = systemOpenExclusive(url.path, mode: 0o600)
            if descriptor >= 0 {
                return (url, descriptor)
            }
            if errno == EINTR || errno == EEXIST {
                continue
            }
            throw POSIXFileOperationError(operation: "open", path: url.path, code: errno)
        }
        throw POSIXFileOperationError(operation: "open", path: directory.path, code: EEXIST)
    }

    private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            var offset = 0
            while offset < bytes.count {
                let count = systemWrite(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw POSIXFileOperationError(
                    operation: "write",
                    path: path,
                    code: count == 0 ? EIO : errno
                )
            }
        }
    }

    private func changeMode(_ descriptor: Int32, to mode: UInt16, path: String) throws {
        while systemFchmod(descriptor, mode_t(mode & 0o777)) != 0 {
            if errno == EINTR { continue }
            throw POSIXFileOperationError(operation: "fchmod", path: path, code: errno)
        }
    }

    private func synchronize(_ descriptor: Int32, path: String) throws {
        while systemFsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw POSIXFileOperationError(operation: "fsync", path: path, code: errno)
        }
    }
}

private struct POSIXFileOperationError: Error, LocalizedError {
    let operation: String
    let path: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed for \(path): \(systemErrorMessage(code)) (errno \(code))"
    }
}

private func systemOpenExclusive(_ path: String, mode: mode_t) -> Int32 {
    path.withCString { pointer in
        #if canImport(Darwin)
        Darwin.open(pointer, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        #else
        Glibc.open(pointer, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        #endif
    }
}

private func systemWrite(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #else
    Glibc.write(descriptor, buffer, count)
    #endif
}

private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.fchmod(descriptor, mode)
    #else
    Glibc.fchmod(descriptor, mode)
    #endif
}

private func systemFsync(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.fsync(descriptor)
    #else
    Glibc.fsync(descriptor)
    #endif
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #else
    Glibc.close(descriptor)
    #endif
}

private func systemRename(_ source: String, _ destination: String) -> Int32 {
    source.withCString { sourcePointer in
        destination.withCString { destinationPointer in
            #if canImport(Darwin)
            Darwin.rename(sourcePointer, destinationPointer)
            #else
            Glibc.rename(sourcePointer, destinationPointer)
            #endif
        }
    }
}

private func systemLink(_ source: String, _ destination: String) -> Int32 {
    source.withCString { sourcePointer in
        destination.withCString { destinationPointer in
            #if canImport(Darwin)
            Darwin.link(sourcePointer, destinationPointer)
            #else
            Glibc.link(sourcePointer, destinationPointer)
            #endif
        }
    }
}

private func systemUnlink(_ path: String) -> Int32 {
    path.withCString { pointer in
        #if canImport(Darwin)
        Darwin.unlink(pointer)
        #else
        Glibc.unlink(pointer)
        #endif
    }
}

private func systemErrorMessage(_ code: Int32) -> String {
    #if canImport(Darwin)
    guard let pointer = Darwin.strerror(code) else { return "unknown error" }
    #else
    guard let pointer = Glibc.strerror(code) else { return "unknown error" }
    #endif
    return String(cString: pointer)
}
