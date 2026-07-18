import Foundation

/// Read-only discovery for a server-owned local broker record.
///
/// The client never creates directories, writes credentials, changes permissions, or
/// owns broker lifecycle. `TAPQ_BROKER_DIR` provides an explicit path on both platforms.
public struct BrokerDiscovery {
    public let supportDir: URL
    private let fallbackDiscoveryURLs: [URL]

    public init(supportDir: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.supportDir = supportDir ?? Self.defaultSupportDirectory(
            environment: environment, homeDirectory: homeDirectory)
        if supportDir == nil, Self.nonempty(environment["TAPQ_BROKER_DIR"]) == nil {
            #if os(macOS)
            self.fallbackDiscoveryURLs = [
                homeDirectory
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
                    .appendingPathComponent("Wavo", isDirectory: true)
                    .appendingPathComponent("broker.json")
            ]
            #else
            self.fallbackDiscoveryURLs = []
            #endif
        } else {
            self.fallbackDiscoveryURLs = []
        }
    }

    public var discoveryURL: URL {
        supportDir.appendingPathComponent("broker.json")
    }

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
        // A user-private, deterministic fallback for environments (including many
        // containers) that do not provide XDG_RUNTIME_DIR. The server remains responsible
        // for creating it with restrictive permissions.
        return homeDirectory
            .appendingPathComponent(".local/state/tapq/runtime", isDirectory: true)
        #endif
    }

    /// Reads the server-owned discovery record.
    public func readDiscovery() throws -> (
        socket: String,
        token: String,
        protocolVersion: Int?,
        steeringEnabled: Bool
    ) {
        let candidates = [discoveryURL] + fallbackDiscoveryURLs
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(DiscoveryRecord.self, from: data)
        guard !record.socket.isEmpty, !record.token.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (record.socket, record.token, record.protocolVersion,
                record.steeringEnabled ?? false)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private struct DiscoveryRecord: Decodable {
        let socket: String
        let token: String
        let protocolVersion: Int?
        let steeringEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case socket, token
            case protocolVersion = "protocol_version"
            case steeringEnabled = "steering_enabled"
        }
    }
}
