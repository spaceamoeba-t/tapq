import Foundation
import TapQContracts
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
    /// The `accept(2)` call itself, injectable so tests can drive the loop's error
    /// handling without provoking real kernel errnos. It mirrors the syscall: a connected
    /// descriptor, or -1 with `errno` set.
    typealias AcceptCall = @Sendable (Int32) -> Int32

    private let path: String
    private let maxRequestBytes: Int
    private let stateLock = NSLock()
    private let acceptConnection: AcceptCall
    private let diagnostics: TapQDiagnosticEmitter
    private var listenFD: Int32 = -1
    private var running = false
    /// The path this instance bound, so `stop()` removes its own socket and never one a
    /// second broker has since taken over.
    private var boundPath: String?
    private var handler: (@Sendable (Data) async -> Data)?
    private let connectionQueue = DispatchQueue(
        label: "ai.tapq.broker.connection",
        attributes: .concurrent
    )

    public convenience init(
        path: String,
        maxRequestBytes: Int = 1 << 20,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.init(path: path, maxRequestBytes: maxRequestBytes,
                  diagnosticSink: diagnosticSink,
                  acceptConnection: { accept($0, nil, nil) })
    }

    init(
        path: String,
        maxRequestBytes: Int = 1 << 20,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        acceptConnection: @escaping AcceptCall
    ) {
        self.path = path
        self.maxRequestBytes = maxRequestBytes
        self.acceptConnection = acceptConnection
        self.diagnostics = TapQDiagnosticEmitter(category: "BrokerTransport",
                                                 sink: diagnosticSink)
    }

    deinit { stop() }

    public func start(handler: @escaping @Sendable (Data) async -> Data) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listenFD < 0 else { throw SocketError.alreadyStarted }

        try Self.clearStaleSocket(at: path)
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
        boundPath = path
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
        let ownedPath = boundPath
        boundPath = nil
        handler = nil
        stateLock.unlock()

        if descriptor >= 0 { close(descriptor) }
        if let ownedPath { unlink(ownedPath) }
    }

    /// A crashed broker leaves its socket file behind, so a stale path must be
    /// reclaimable — but a path with a broker still listening on it belongs to that
    /// broker. Unlinking it would leave the first `tapq serve` bound to a name no hook
    /// can reach: every hook call would then stall to its timeout against a broker that
    /// still looks healthy. Probe first, and refuse to start rather than take the path.
    private static func clearStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard !isSocketListening(at: path) else { throw SocketError.addressInUse(path) }
        guard unlink(path) == 0 || errno == ENOENT else {
            throw SocketError.errno("unlink", errno)
        }
    }

    /// Connects and immediately closes, sending no application data — the broker treats
    /// an EOF-only connection as a no-op. Anything that is not an accepting listener
    /// (a refused connection, a leftover regular file, a socket nobody owns) reads as
    /// not listening.
    static func isSocketListening(at path: String, timeoutMilliseconds: Int32 = 100) -> Bool {
        let descriptor = socket(AF_UNIX, streamSocketType, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, max(0, timeoutMilliseconds)) > 0 else { return false }

        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR,
                         &socketError, &socketErrorSize) == 0 else { return false }
        return socketError == 0
    }

    private func acceptLoop(descriptor: Int32) {
        var backoff = Self.acceptBackoffFloor
        while isRunning {
            let connection = acceptConnection(descriptor)
            if connection < 0 {
                let code = errno
                // A closed listener during stop() is the ordinary shutdown path, not a
                // failure worth reporting.
                guard isRunning else { break }
                if code == EINTR { continue }
                guard Self.isTransientAcceptErrno(code) else {
                    // Descriptor-level errors mean this listener is gone for good; the
                    // loop has nothing left to accept on.
                    diagnostics.record("accept.stopped", level: .error,
                                       fields: ["errno": "\(code)"])
                    break
                }
                // A per-connection abort or an exhausted descriptor table is momentary:
                // giving up here would leave the broker listening but answering nothing,
                // so back off (bounded) and keep accepting.
                diagnostics.record("accept.retry", level: .warning, fields: [
                    "errno": "\(code)",
                    "backoff_ms": "\(Int(backoff * 1000))",
                ])
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, Self.acceptBackoffCeiling)
                continue
            }
            backoff = Self.acceptBackoffFloor
            connectionQueue.async { [weak self] in
                self?.handleConnection(connection)
            }
        }
    }

    /// Transient accept failures: the connection died before it was accepted, or the
    /// process/system is briefly out of descriptors or buffers. None of them says
    /// anything about the listening socket, which stays valid.
    private static let transientAcceptErrnos: Set<Int32> = [
        ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM, EAGAIN, EWOULDBLOCK, EPROTO,
        ECONNRESET, ETIMEDOUT,
    ]

    static func isTransientAcceptErrno(_ code: Int32) -> Bool {
        transientAcceptErrnos.contains(code)
    }

    /// Backoff starts short enough to be invisible to a healthy broker and is capped so a
    /// persistent transient condition never turns into an unbounded stall.
    private static let acceptBackoffFloor: TimeInterval = 0.01
    private static let acceptBackoffCeiling: TimeInterval = 0.2

    private func handleConnection(_ descriptor: Int32) {
        defer { close(descriptor) }
        #if canImport(Darwin)
        guard Self.suppressSIGPIPE(on: descriptor) else { return }
        #endif
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
                let count = socketWrite(descriptor: descriptor, pointer: pointer,
                                        count: remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func socketWrite(descriptor: Int32, pointer: UnsafeRawPointer,
                                    count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(descriptor, pointer, count, 0)
        #else
        return Glibc.send(descriptor, pointer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    #if canImport(Darwin)
    private static func suppressSIGPIPE(on descriptor: Int32) -> Bool {
        var noSigPipe: Int32 = 1
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }
    #endif

    public enum SocketError: Error, LocalizedError, Equatable {
        case alreadyStarted
        case addressInUse(String)
        case pathTooLong(String)
        case errno(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                return "The broker socket is already running."
            case .addressInUse(let path):
                return "Another TapQ broker is already listening on \(path). "
                    + "Stop it before starting a second one."
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
