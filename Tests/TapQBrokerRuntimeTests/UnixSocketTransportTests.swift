import XCTest
@testable import TapQBrokerRuntime
import TapQContracts
import TapQPOSIXBridgeClient
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The transport's survival properties: a momentary accept failure must not silently end
/// the broker's listening life, and a second broker must never take the socket path away
/// from the one already answering on it.
final class UnixSocketTransportTests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        // Short by necessity: `sun_path` is barely 100 bytes, and the sandbox temporary
        // directory alone overruns it.
        socketPath = "/tmp/tapq-transport-\(UUID().uuidString).sock"
    }

    override func tearDown() {
        unlink(socketPath)
        super.tearDown()
    }

    // MARK: - Accept loop

    func testTransientAcceptFailureBacksOffAndKeepsServing() throws {
        let sink = RecordingSink()
        let failures = CountingBox(remaining: 3)
        let transport = UnixSocketTransport(
            path: socketPath,
            diagnosticSink: sink,
            acceptConnection: { descriptor in
                if failures.consume() {
                    errno = ECONNABORTED
                    return -1
                }
                return accept(descriptor, nil, nil)
            }
        )
        defer { transport.stop() }
        try transport.start { _ in Data("served".utf8) }

        let response = try request("ping")

        XCTAssertEqual(String(decoding: response, as: UTF8.self), "served",
                       "the broker must still answer after a transient accept failure")
        let retries = sink.events.filter { $0.name == "accept.retry" }
        XCTAssertEqual(retries.count, 3)
        XCTAssertEqual(retries.first?.category, "BrokerTransport")
        XCTAssertEqual(retries.first?.level, .warning)
        XCTAssertEqual(retries.first?.fields["errno"], "\(ECONNABORTED)")
        XCTAssertEqual(retries.map { $0.fields["backoff_ms"] }, ["10", "20", "40"],
                       "backoff grows but stays bounded")
        XCTAssertTrue(sink.events.allSatisfy { $0.name != "accept.stopped" })
    }

    func testTransientErrnoClassificationCoversTheKnownRecoverableStates() {
        for code in [ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM, EAGAIN, EWOULDBLOCK] {
            XCTAssertTrue(UnixSocketTransport.isTransientAcceptErrno(code), "\(code)")
        }
        for code in [EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP] {
            XCTAssertFalse(UnixSocketTransport.isTransientAcceptErrno(code), "\(code)")
        }
    }

    func testFatalAcceptFailureStopsTheLoopOnce() throws {
        let sink = RecordingSink()
        let attempts = CountingBox(remaining: 0)
        let transport = UnixSocketTransport(
            path: socketPath,
            diagnosticSink: sink,
            acceptConnection: { _ in
                attempts.increment()
                errno = EBADF
                return -1
            }
        )
        defer { transport.stop() }
        try transport.start { _ in Data("served".utf8) }

        XCTAssertTrue(waitUntil { sink.events.contains { $0.name == "accept.stopped" } },
                      "a dead listener must be reported, not looped on")
        let settled = attempts.count
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(attempts.count, settled, "the loop must not spin on a dead listener")
        let stopped = try XCTUnwrap(sink.events.first { $0.name == "accept.stopped" })
        XCTAssertEqual(stopped.level, .error)
        XCTAssertEqual(stopped.fields["errno"], "\(EBADF)")
    }

    // MARK: - Socket ownership

    func testStartRefusesAPathAnotherBrokerIsListeningOnAndLeavesItIntact() throws {
        let survivor = UnixSocketTransport(path: socketPath)
        defer { survivor.stop() }
        try survivor.start { _ in Data("survivor".utf8) }

        let intruder = UnixSocketTransport(path: socketPath)
        XCTAssertThrowsError(try intruder.start { _ in Data("intruder".utf8) }) { error in
            XCTAssertEqual(error as? UnixSocketTransport.SocketError,
                           .addressInUse(socketPath))
        }
        // The failed instance bound nothing, so its teardown owns nothing to remove.
        intruder.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let response = try request("ping")
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "survivor",
                       "the first broker must keep the socket it is answering on")
    }

    func testStartReclaimsTheSocketACrashedBrokerLeftBehind() throws {
        try bindWithoutListening(at: socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let transport = UnixSocketTransport(path: socketPath)
        defer { transport.stop() }
        try transport.start { _ in Data("rebound".utf8) }

        let response = try request("ping")
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "rebound")
    }

    func testStopRemovesOnlyTheSocketThisInstanceBound() throws {
        let survivor = UnixSocketTransport(path: socketPath)
        defer { survivor.stop() }
        try survivor.start { _ in Data("survivor".utf8) }

        let neverStarted = UnixSocketTransport(path: socketPath)
        neverStarted.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath),
                      "a transport that bound nothing must unlink nothing")
        XCTAssertEqual(String(decoding: try request("ping"), as: UTF8.self), "survivor")

        survivor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath),
                       "the instance that bound the path still cleans it up")
    }

    func testDiscoveryRemoveLeavesALiveBrokersRecordsAlone() throws {
        let directory = URL(fileURLWithPath: "/tmp/tapq-discovery-\(UUID().uuidString)",
                            isDirectory: true)
        let discovery = BrokerRuntimeDiscovery(supportDirectory: directory)
        try discovery.prepareDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let survivor = UnixSocketTransport(path: discovery.socketPath)
        defer { survivor.stop() }
        try survivor.start { _ in Data("survivor".utf8) }
        try discovery.publish(token: "tok")

        // What a second `tapq serve` does before it starts its own broker.
        discovery.remove()

        XCTAssertTrue(FileManager.default.fileExists(atPath: discovery.discoveryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: discovery.socketPath))

        survivor.stop()
        discovery.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: discovery.discoveryURL.path))
    }

    // MARK: - Helpers

    private func request(_ line: String, timeout: TimeInterval = 2) throws -> Data {
        try UnixSocketClient.request(Data(line.utf8), socketPath: socketPath, timeout: timeout)
    }

    /// A crashed broker's leftover: the socket file exists but nothing listens on it, so
    /// connecting is refused.
    private func bindWithoutListening(at path: String) throws {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_UNIX, streamType, 0)
        try XCTSkipIf(descriptor < 0, "could not create a stale socket fixture")
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strncpy($0, source, capacity - 1)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { rawAddress in
            rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
                #else
                Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
                #endif
            }
        }
        XCTAssertEqual(bound, 0, "stale socket fixture failed to bind (errno \(errno))")
    }

    private func waitUntil(attempts: Int = 300, condition: () -> Bool) -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private final class CountingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var calls = 0

        init(remaining: Int) {
            self.remaining = remaining
        }

        /// Reports whether this call should fail, spending one of the seeded failures.
        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }

        func increment() {
            lock.lock()
            calls += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
