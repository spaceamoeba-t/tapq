import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("TapQPOSIXBridgeClient requires a POSIX platform")
#endif

/// A one-shot POSIX Unix-domain-socket client: connect, write one request line, read one
/// response line, and close. It is shared by the macOS and Linux hook executables.
public enum UnixSocketClient {
    /// Opens and closes a Unix-domain socket without sending application data.
    ///
    /// Hook steering uses this as a liveness probe: a stale discovery file and a reused
    /// process identifier are insufficient unless the recorded broker socket also accepts
    /// a connection. The broker treats an EOF-only connection as a no-op.
    public static func canConnect(
        socketPath: String,
        timeoutMilliseconds: Int32 = 100
    ) -> Bool {
        let fd = socket(AF_UNIX, streamSocketType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { return false }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let boundedTimeout = max(0, timeoutMilliseconds)
        // An interrupted probe fails through immediately instead of restarting a full
        // timeout window; the hook must have a hard internal latency bound.
        let pollResult = poll(&descriptor, 1, boundedTimeout)
        guard pollResult > 0 else { return false }

        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorSize
        ) == 0 else { return false }
        return socketError == 0
    }

    public static func request(_ payload: Data, socketPath: String,
                               timeout: TimeInterval = 5) throws -> Data {
        let fd = socket(AF_UNIX, streamSocketType, 0)
        guard fd >= 0 else { throw ClientError.errno("socket", errno) }
        defer { close(fd) }

        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ClientError.errno("setsockopt(SO_NOSIGPIPE)", errno)
        }
        #endif

        var timeoutValue = socketTimeout(timeout)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ClientError.errno("setsockopt(SO_RCVTIMEO)", errno)
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ClientError.errno("setsockopt(SO_SNDTIMEO)", errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw ClientError.pathTooLong }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connected == 0 else { throw ClientError.errno("connect", errno) }

        var line = payload
        line.append(0x0A)
        try writeAll(fd: fd, data: line)

        guard let response = try readLine(fd: fd, max: 1 << 20) else {
            throw ClientError.noResponse
        }
        return response
    }

    private static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static func socketTimeout(_ timeout: TimeInterval) -> timeval {
        let clamped = max(0, timeout)
        let seconds = floor(clamped)
        let microseconds = (clamped - seconds) * 1_000_000
        return timeval(tv_sec: time_t(seconds), tv_usec: suseconds_t(microseconds))
    }

    private static func readLine(fd: Int32, max: Int) throws -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < max {
            let count = read(fd, &byte, 1)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClientError.errno("read", errno)
            }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = socketWrite(fd: fd, pointer: pointer, count: remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ClientError.errno("write", errno)
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func socketWrite(fd: Int32, pointer: UnsafeRawPointer,
                                    count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, pointer, count, 0)
        #else
        return Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    public enum ClientError: Error, Equatable {
        case pathTooLong
        case noResponse
        case errno(String, Int32)
    }
}
