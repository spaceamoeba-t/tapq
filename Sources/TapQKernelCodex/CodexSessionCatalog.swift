import Foundation
import TapQContracts
import TapQKernel
import TapQPOSIXSupport

/// Codex's threads in one folder, from `thread/list` (stable app-server API in 0.161.0) on a
/// short-lived `codex app-server` of the catalog's own, so the thread TapQ's Codex runs is never
/// touched. Read only: `useStateDbOnly` lists from Codex's state database without the rollout
/// scan that repairs it. The sources are the interactive ones and the app-server's: Codex
/// records TapQ's own threads as `vscode` (live, 2026-10-12). Subagents' threads are left out.
public struct CodexSessionCatalog: SessionCatalog {
    public typealias Spawn = @Sendable (CodexLaunchSpec) throws -> any LineChannel

    public struct Configuration: Sendable {
        public var executablePath: String
        /// TapQ's version, sent as `clientInfo.version`.
        public var clientVersion: String
        /// D5's developer override: an unsupported `userAgent` version is not refused.
        public var allowsUnsupportedVersion: Bool

        public init(executablePath: String, clientVersion: String, allowsUnsupportedVersion: Bool = false) {
            self.executablePath = executablePath
            self.clientVersion = clientVersion
            self.allowsUnsupportedVersion = allowsUnsupportedVersion
        }
    }

    static let limit = 50
    static let sourceKinds = ["cli", "vscode", "appServer"]

    /// The production `spawn`.
    public static let spawnChildProcess: Spawn = { spec in
        try ChildProcess(executable: spec.executablePath, arguments: spec.arguments,
                         environment: spec.environment, workingDirectory: spec.workspace)
    }

    private let configuration: Configuration
    private let environment: [String: String]
    private let spawn: Spawn

    /// `environment`: the one Codex gets; the spec sanitizes it as for the delegate.
    public init(configuration: Configuration, environment: [String: String], spawn: @escaping Spawn) {
        self.configuration = configuration
        self.environment = environment
        self.spawn = spawn
    }

    /// The server is always ended: on the answer, on an error, and when the caller's bound
    /// cancels the listing, which closes its stdin at once.
    public func sessions(in workspace: URL) async throws -> [SessionSummary] {
        let channel = try spawn(CodexLaunchSpec(executablePath: configuration.executablePath,
                                                workspace: workspace, environment: environment))
        do {
            let sessions = try await withTaskCancellationHandler {
                try await list(over: channel, workspace: workspace)
            } onCancel: {
                channel.closeInput()
            }
            await channel.terminate(grace: .seconds(2), killAfter: .seconds(1))
            return sessions
        } catch {
            await channel.terminate(grace: .seconds(2), killAfter: .seconds(1))
            throw error
        }
    }

    private func list(over channel: any LineChannel, workspace: URL) async throws -> [SessionSummary] {
        var lines = channel.signals.makeAsyncIterator()
        func response(_ id: Int, _ method: String) async throws -> JSONValue {
            while let signal = await lines.next() {
                switch signal {
                case .stdout(let line):
                    switch CodexRPCCodec.decode(line) {
                    case .result(id, let result)?: return result
                    case .error(id, _, let message, _)?: throw CodexDelegateError.rejected(method: method, message: message)
                    default: continue
                    }
                case .stderr: continue
                case .exited(let code): throw CodexDelegateError.exited(code)
                }
            }
            throw CancellationError()
        }

        try write(CodexRPCCodec.request(id: 1, method: "initialize",
                                        params: CodexDelegate.initializeParams(clientVersion: configuration.clientVersion)),
                  to: channel)
        let server = try await response(1, "initialize")
        try checkVersion(userAgent: server["userAgent"]?.stringValue ?? "")
        try write(CodexRPCCodec.notification(method: "initialized"), to: channel)
        try write(CodexRPCCodec.request(id: 2, method: "thread/list", params: Self.listParams(workspace)), to: channel)
        let threads = try await response(2, "thread/list")["data"]?.arrayValue ?? []
        return threads.compactMap(Self.session).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The folder as given (TapQ starts its threads with it) and resolved, when that differs.
    static func listParams(_ workspace: URL) -> String {
        let given = workspace.path
        let resolved = workspace.resolvingSymlinksInPath().path
        let folders = given == resolved ? [given] : [given, resolved]
        return JSONText.object([
            ("cwd", JSONText.array(folders.map(JSONText.quoted))),
            ("sourceKinds", JSONText.array(sourceKinds.map(JSONText.quoted))),
            ("sortKey", #""updated_at""#),
            ("limit", String(limit)),
            ("useStateDbOnly", "true"),
        ])
    }

    /// The thread's name when it has one, else its preview (usually its first message).
    static func session(_ thread: JSONValue) -> SessionSummary? {
        guard let id = thread["id"]?.stringValue, !id.isEmpty,
              (thread["parentThreadId"] ?? .null) == .null else { return nil }
        let name = thread["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = thread["preview"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seconds = seconds(thread["updatedAt"]) ?? seconds(thread["createdAt"]) ?? 0
        return SessionSummary(id: id, title: !name.isEmpty ? name : !preview.isEmpty ? preview : "(conversation)",
                              updatedAt: Date(timeIntervalSince1970: seconds))
    }

    private static func seconds(_ value: JSONValue?) -> Double? {
        if case .number(let seconds)? = value { return seconds }
        return nil
    }

    private func write(_ line: String, to channel: any LineChannel) throws {
        do {
            try channel.write(line: line)
        } catch {
            throw CodexDelegateError.writeFailed("\(error)")
        }
    }

    private func checkVersion(userAgent: String) throws {
        guard let version = CodexVersions.parse(userAgent: userAgent) else {
            throw CodexDelegateError.violation("Codex's initialize response names no version")
        }
        guard !CodexVersions.supported.contains(version), !configuration.allowsUnsupportedVersion else { return }
        throw CodexDelegateError.unsupportedVersion(CodexVersions.supported.refusal(for: .codex, found: version))
    }
}
