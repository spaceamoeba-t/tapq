import Foundation

public enum KernelSessionStoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, detail: String)
    case unwritable(path: String, detail: String)
    case unsupportedSchema(path: String, version: Int)

    public var description: String {
        switch self {
        case .unreadable(let path, let detail): return "cannot read \(path): \(detail)"
        case .unwritable(let path, let detail): return "cannot write \(path): \(detail)"
        case .unsupportedSchema(let path, let version):
            return "\(path) has schema version \(version); this TapQ reads \(KernelSessionStore.schemaVersion)"
        }
    }
}

/// `session.json` v2: {"schemaVersion":2,"sessions":{"claude":"<uuid>","codex":"<thread id>"}}
///
/// Each agent's session id, for resume. Absent file or absent agent is nil; unreadable or
/// undecodable throws.
@MainActor
public final class KernelSessionStore {
    public static let fileName = "session.json"
    nonisolated public static let schemaVersion = 2

    private struct File: Codable {
        var schemaVersion: Int
        var sessions: [String: String]
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public convenience init(directory: URL) {
        self.init(url: directory.appendingPathComponent(KernelSessionStore.fileName))
    }

    public func sessionID(for agent: AgentID) throws -> String? {
        try read()?.sessions[agent.rawValue]
    }

    /// Atomic write: a crash leaves the old file or the new one, never half of either.
    public func save(_ id: String, for agent: AgentID) throws {
        var file = try read() ?? File(schemaVersion: Self.schemaVersion, sessions: [:])
        file.sessions[agent.rawValue] = id
        do {
            try KernelJSON.encoder().encode(file).write(to: url, options: .atomic)
        } catch {
            throw KernelSessionStoreError.unwritable(path: url.path, detail: "\(error)")
        }
    }

    private func read() throws -> File? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file: File
        do {
            file = try KernelJSON.decoder().decode(File.self, from: Data(contentsOf: url))
        } catch {
            throw KernelSessionStoreError.unreadable(path: url.path, detail: "\(error)")
        }
        guard file.schemaVersion == Self.schemaVersion else {
            throw KernelSessionStoreError.unsupportedSchema(path: url.path, version: file.schemaVersion)
        }
        return file
    }
}
