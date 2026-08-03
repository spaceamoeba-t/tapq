import XCTest
@testable import TapQBrokerRuntime
@testable import TapQPOSIXBridgeClient
import TapQWireProtocol

final class BrokerRuntimeDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-discovery-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testPublishedRecordIsReadableByBridgeClient() throws {
        let runtime = BrokerRuntimeDiscovery(supportDirectory: directory)
        try runtime.prepareDirectory()
        try runtime.publish(token: "tok", steeringEnabled: true)

        let client = TapQPOSIXBridgeClient.BrokerDiscovery(supportDir: directory)
        let record = try client.readDiscovery()
        XCTAssertEqual(record.socket, runtime.socketPath)
        XCTAssertEqual(record.token, "tok")
        XCTAssertEqual(record.protocolVersion, WireProtocol.version)
        XCTAssertTrue(record.steeringEnabled)
        XCTAssertTrue(
            try client.readLiveDiscovery(socketIsReachable: { $0 == runtime.socketPath })
                .steeringEnabled
        )

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let recordMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: runtime.discoveryURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(recordMode & 0o777, 0o600)
    }

    func testRemoveDeletesDiscoveryRecord() throws {
        let runtime = BrokerRuntimeDiscovery(supportDirectory: directory)
        try runtime.prepareDirectory()
        try runtime.publish(token: "tok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.discoveryURL.path))

        runtime.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.discoveryURL.path))
    }

    func testGeneratedTokensAreFreshAnd256BitsWide() {
        let first = BrokerRuntimeDiscovery.generateToken()
        let second = BrokerRuntimeDiscovery.generateToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second.count, 64)
        XCTAssertNotEqual(first, second)
    }
}
