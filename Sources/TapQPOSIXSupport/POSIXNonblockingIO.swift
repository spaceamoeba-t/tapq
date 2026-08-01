#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("TapQPOSIXSupport requires a POSIX platform")
#endif

/// Minimal nonblocking descriptor operations kept behind TapQ's POSIX boundary.
package enum POSIXNonblockingIO {
    package enum ReadResult: Sendable {
        case bytes(Int)
        case endOfFile
        case wouldBlock
        case failed
    }

    package static func configure(_ descriptor: Int32) -> Bool {
        var flags: Int32
        repeat {
            flags = fcntl(descriptor, F_GETFL, 0)
        } while flags < 0 && errno == EINTR
        guard flags >= 0 else { return false }
        if flags & O_NONBLOCK != 0 { return true }
        var result: Int32
        repeat {
            result = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        } while result < 0 && errno == EINTR
        return result == 0
    }

    package static func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> ReadResult {
        guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else {
            return .wouldBlock
        }
        while true {
            #if canImport(Darwin)
            let count = Darwin.read(descriptor, baseAddress, buffer.count)
            #else
            let count = Glibc.read(descriptor, baseAddress, buffer.count)
            #endif
            if count > 0 { return .bytes(count) }
            if count == 0 { return .endOfFile }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .failed
        }
    }
}
