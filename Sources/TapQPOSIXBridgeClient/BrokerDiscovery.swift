import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
            // Wavo was TapQ's internal pre-release codename. Read its old broker record
            // only as a migration fallback; all newly created state uses the TapQ path.
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
        let record = try readRecord()
        return (record.socket, record.token, record.protocolVersion,
                record.steeringEnabled ?? false)
    }

    /// Reads discovery only when its publishing runtime process is still alive.
    ///
    /// Steering is intentionally gated on this stronger view. A runtime terminated by
    /// SIGKILL cannot remove its discovery file, so treating file presence as liveness
    /// would leave advisory prompt injection enabled indefinitely. Older records without
    /// a publisher PID fail closed for steering while remaining readable for the normal
    /// broker connection path.
    public func readLiveDiscovery() throws -> (
        socket: String,
        token: String,
        protocolVersion: Int?,
        steeringEnabled: Bool
    ) {
        try readLiveDiscovery(socketIsReachable: {
            UnixSocketClient.canConnect(socketPath: $0)
        })
    }

    func readLiveDiscovery(
        socketIsReachable: (String) -> Bool
    ) throws -> (
        socket: String,
        token: String,
        protocolVersion: Int?,
        steeringEnabled: Bool
    ) {
        let record = try readRecord()
        guard let processID = record.processID,
              processID > 0,
              Self.processIsAlive(processID),
              socketIsReachable(record.socket) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (record.socket, record.token, record.protocolVersion,
                record.steeringEnabled ?? false)
    }

    /// Whether the live runtime advertises that it will hold a turn boundary open.
    ///
    /// Non-throwing and fail-closed at every step — an unreadable record, a record from a
    /// runtime that predates voice sessions, a publisher that is no longer alive — because
    /// the only thing this answer can do is make a Stop hook *wait*, and a hook that waits
    /// on a runtime that will not answer is the one failure mode this whole feature has to
    /// avoid. Liveness is checked for the same reason steering checks it: a runtime killed
    /// with SIGKILL cannot remove its own record.
    public func liveVoiceSessionEnabled() -> Bool {
        liveVoiceSessionEnabled(socketIsReachable: {
            UnixSocketClient.canConnect(socketPath: $0)
        })
    }

    func liveVoiceSessionEnabled(socketIsReachable: (String) -> Bool) -> Bool {
        guard let record = try? readRecord(),
              let processID = record.processID,
              processID > 0,
              Self.processIsAlive(processID),
              socketIsReachable(record.socket) else { return false }
        return record.voiceSessionEnabled ?? false
    }

    private func readRecord() throws -> DiscoveryRecord {
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
        return record
    }

    private static func processIsAlive(_ processID: Int32) -> Bool {
        if kill(pid_t(processID), 0) == 0 {
            return true
        }
        // A process owned by another user may reject the signal probe even though it is
        // alive. Discovery is private to this user, but accepting EPERM keeps the helper
        // correct if ownership rules differ on a supported POSIX platform.
        return errno == EPERM
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
        /// Absent in every record written before voice sessions existed, which decodes to
        /// nil and reads as `false` — an older runtime is never long-polled.
        let voiceSessionEnabled: Bool?
        let processID: Int32?

        enum CodingKeys: String, CodingKey {
            case socket, token
            case protocolVersion = "protocol_version"
            case steeringEnabled = "steering_enabled"
            case voiceSessionEnabled = "voice_session"
            case processID = "process_id"
        }
    }
}
