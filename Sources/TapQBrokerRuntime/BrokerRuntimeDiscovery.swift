import Foundation
import TapQWireProtocol

/// Server-owned filesystem discovery record shared with local agent adapters.
///
/// The directory and record are private to the current user. A fresh token is generated
/// for each runtime launch; adapters prove they could read the `0600` record by returning it.
public struct BrokerRuntimeDiscovery: Sendable {
    public let supportDirectory: URL

    public init(
        supportDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    public var socketURL: URL { supportDirectory.appendingPathComponent("broker.sock") }
    public var discoveryURL: URL { supportDirectory.appendingPathComponent("broker.json") }
    public var socketPath: String { socketURL.path }

    public static func defaultSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = nonempty(environment["TAPQ_BROKER_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        #if os(macOS)
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("TapQ/runtime", isDirectory: true)
        #else
        if let runtimeDirectory = nonempty(environment["XDG_RUNTIME_DIR"]) {
            return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
                .appendingPathComponent("tapq", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local/state/tapq/runtime", isDirectory: true)
        #endif
    }

    public func prepareDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
    }

    public func publish(token: String, steeringEnabled: Bool = false) throws {
        let record = DiscoveryRecord(
            socket: socketPath,
            token: token,
            protocolVersion: WireProtocol.version,
            steeringEnabled: steeringEnabled,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        try data.write(to: discoveryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: discoveryURL.path
        )
    }

    /// Clears this runtime's discovery record and socket file, including the pair a
    /// crashed run left behind.
    ///
    /// A socket another broker is still listening on is left alone, record and all: it
    /// belongs to whoever is answering on it, and removing either half would strand every
    /// hook against a broker that still looks healthy. A second `tapq serve` therefore
    /// clears nothing here and fails at bind time with `SocketError.addressInUse`.
    public func remove() {
        guard !UnixSocketTransport.isSocketListening(at: socketPath) else { return }
        try? FileManager.default.removeItem(at: discoveryURL)
        try? FileManager.default.removeItem(at: socketURL)
    }

    public static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private struct DiscoveryRecord: Encodable {
        let socket: String
        let token: String
        let protocolVersion: Int
        let steeringEnabled: Bool
        let processID: Int32

        enum CodingKeys: String, CodingKey {
            case socket, token
            case protocolVersion = "protocol_version"
            case steeringEnabled = "steering_enabled"
            case processID = "process_id"
        }
    }
}
