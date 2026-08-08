import XCTest
@testable import TapQPOSIXBridgeClient
import TapQWireProtocol

final class BrokerDiscoveryTests: XCTestCase {
    private var dir: URL!
    private var discovery: BrokerDiscovery!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-discovery-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        discovery = BrokerDiscovery(supportDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testReadsServerOwnedRecordIncludingProtocolVersion() throws {
        let record = """
        {"socket":"/tmp/tapq.sock","token":"tok","protocol_version":\(WireProtocol.version),\
        "steering_enabled":true,"process_id":\(ProcessInfo.processInfo.processIdentifier)}
        """
        try Data(record.utf8).write(to: discovery.discoveryURL)
        let read = try discovery.readDiscovery()
        XCTAssertEqual(read.socket, "/tmp/tapq.sock")
        XCTAssertEqual(read.token, "tok")
        XCTAssertEqual(read.protocolVersion, WireProtocol.version)
        XCTAssertTrue(read.steeringEnabled)
        XCTAssertTrue(
            try discovery.readLiveDiscovery(socketIsReachable: { $0 == "/tmp/tapq.sock" })
                .steeringEnabled
        )
    }

    func testLegacyDiscoveryWithoutVersionReadsAsNil() throws {
        let legacy = #"{"socket":"/tmp/x.sock","token":"tok"}"#
        try Data(legacy.utf8).write(to: discovery.discoveryURL)
        let read = try discovery.readDiscovery()
        XCTAssertEqual(read.token, "tok")
        XCTAssertNil(read.protocolVersion)
    }

    func testLegacyDiscoveryWithoutSteeringKeyReadsFalse() throws {
        let legacy = #"{"socket":"/tmp/x.sock","token":"tok"}"#
        try Data(legacy.utf8).write(to: discovery.discoveryURL)
        XCTAssertFalse(try discovery.readDiscovery().steeringEnabled)
    }

    func testLiveDiscoveryRejectsLegacyRecordWithoutPublisherPID() throws {
        let legacy = #"{"socket":"/tmp/x.sock","token":"tok","steering_enabled":true}"#
        try Data(legacy.utf8).write(to: discovery.discoveryURL)

        XCTAssertTrue(try discovery.readDiscovery().steeringEnabled)
        XCTAssertThrowsError(try discovery.readLiveDiscovery())
    }

    func testLiveDiscoveryRejectsDeadPublisherPID() throws {
        let stale = #"{"socket":"/tmp/x.sock","token":"tok","steering_enabled":true,"process_id":2147483647}"#
        try Data(stale.utf8).write(to: discovery.discoveryURL)

        XCTAssertThrowsError(try discovery.readLiveDiscovery())
    }

    func testLiveDiscoveryRejectsUnreachableBrokerSocket() throws {
        let record = """
        {"socket":"/tmp/not-listening.sock","token":"tok","steering_enabled":true,\
        "process_id":\(ProcessInfo.processInfo.processIdentifier)}
        """
        try Data(record.utf8).write(to: discovery.discoveryURL)

        XCTAssertThrowsError(
            try discovery.readLiveDiscovery(socketIsReachable: { _ in false })
        )
    }

    func testMissingRequiredFieldsAreRejected() throws {
        try Data(#"{"socket":"/tmp/x.sock"}"#.utf8).write(to: discovery.discoveryURL)
        XCTAssertThrowsError(try discovery.readDiscovery())
    }

    func testEnvironmentOverrideWins() {
        let path = "/tmp/tapq-explicit"
        let result = BrokerDiscovery.defaultSupportDirectory(
            environment: ["TAPQ_BROKER_DIR": path],
            homeDirectory: URL(fileURLWithPath: "/home/example"))
        XCTAssertEqual(result.path, path)
    }

    #if os(macOS)
    func testMacDefaultUsesTapQRuntimeDirectory() {
        let result = BrokerDiscovery.defaultSupportDirectory(
            environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/example"))
        XCTAssertEqual(result.path, "/Users/example/Library/Application Support/TapQ/runtime")
    }

    func testMacClientFallsBackToLegacyBrokerRecord() throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let legacyDirectory = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Wavo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let record = #"{"socket":"/tmp/wavo.sock","token":"legacy","protocol_version":2}"#
        try Data(record.utf8).write(
            to: legacyDirectory.appendingPathComponent("broker.json")
        )

        let client = BrokerDiscovery(environment: [:], homeDirectory: home)
        let read = try client.readDiscovery()

        XCTAssertEqual(read.socket, "/tmp/wavo.sock")
        XCTAssertEqual(read.token, "legacy")
    }
    #else
    func testLinuxUsesXdgRuntimeDirectory() {
        let result = BrokerDiscovery.defaultSupportDirectory(
            environment: ["XDG_RUNTIME_DIR": "/run/user/1000"],
            homeDirectory: URL(fileURLWithPath: "/home/example"))
        XCTAssertEqual(result.path, "/run/user/1000/tapq")
    }

    func testLinuxHasUserPrivateFallback() {
        let result = BrokerDiscovery.defaultSupportDirectory(
            environment: [:], homeDirectory: URL(fileURLWithPath: "/home/example"))
        XCTAssertEqual(result.path, "/home/example/.local/state/tapq/runtime")
    }
    #endif
}
