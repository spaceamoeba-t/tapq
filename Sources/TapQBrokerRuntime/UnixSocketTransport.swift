import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("TapQBrokerRuntime requires a POSIX platform")
#endif

/// Concurrent newline-delimited JSON server over a user-private Unix-domain socket.
///
/// Each connection handles one request. Long-running approval windows therefore do not
/// prevent another agent session from reaching the broker; interaction serialization is a
/// higher-level runtime responsibility.
public final class UnixSocketTransport: BrokerTransport, @unchecked Sendable {
    private let path: String
    private let maxRequestBytes: Int
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var handler: (@Sendable (Data) async -> Data)?
    private let connectionQueue = DispatchQueue(
        label: "dev.tapq.broker.connection",
        attributes: .concurrent
    )

    public init(path: String, maxRequestBytes: Int = 1 << 20) {
        self.path = path
        self.maxRequestBytes = maxRequestBytes
    }

    deinit { stop() }

    public func start(handler: @escaping @Sendable (Data) async -> Data) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listenFD < 0 else { throw SocketError.alreadyStarted }

        unlink(path)
        let descriptor = socket(AF_UNIX, Self.streamSocketType, 0)
        guard descriptor >= 0 else { throw SocketError.errno("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(descriptor)
            throw SocketError.pathTooLong(path)
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }

        let bound = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.errno("bind", code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw SocketError.errno("chmod", code)
        }
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw SocketError.errno("listen", code)
        }

        self.handler = handler
        listenFD = descriptor
        running = true
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(descriptor: descriptor)
        }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let descriptor = listenFD
        listenFD = -1
        handler = nil
        stateLock.unlock()

        if descriptor >= 0 { close(descriptor) }
        unlink(path)
    }

    private func acceptLoop(descriptor: Int32) {
        while isRunning {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                if isRunning, errno == EINTR { continue }
                break
            }
            connectionQueue.async { [weak self] in
                self?.handleConnection(connection)
            }
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        defer { close(descriptor) }
        guard let request = Self.readLine(descriptor: descriptor, maximum: maxRequestBytes),
              let handler = currentHandler else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let response = ResponseBox()
        Task {
            response.value = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()

        var line = response.value ?? Data()
        line.append(0x0A)
        Self.writeAll(descriptor: descriptor, data: line)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private var currentHandler: (@Sendable (Data) async -> Data)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handler
    }

    private static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static func readLine(descriptor: Int32, maximum: Int) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximum {
            let count = read(descriptor, &byte, 1)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    private static func writeAll(descriptor: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    public enum SocketError: Error, LocalizedError, Equatable {
        case alreadyStarted
        case pathTooLong(String)
        case errno(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                return "The broker socket is already running."
            case .pathTooLong(let path):
                return "The broker socket path is too long: \(path)"
            case .errno(let operation, let code):
                return "Broker socket \(operation) failed with errno \(code)."
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: Data?
}

