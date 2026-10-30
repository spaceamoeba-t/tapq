import Foundation
import TapQContracts
import TapQKernel
import TapQPOSIXSupport

public enum ClaudeDelegateError: Error, Equatable, CustomStringConvertible {
    case alreadyStarted
    case notStarted
    case stopped
    case launchFailed(String)
    case writeFailed(String)
    /// A reply to a request the delegate never saw, or already answered.
    case unknownRequest(String)
    case notAQuestion(String)
    case answerCount(String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .alreadyStarted: return "the delegate is already running"
        case .notStarted: return "the delegate has not been started"
        case .stopped: return "the delegate has been stopped"
        case .launchFailed(let detail): return "could not launch claude: \(detail)"
        case .writeFailed(let detail): return "could not write to claude's stdin: \(detail)"
        case .unknownRequest(let id): return "no pending request '\(id)'"
        case .notAQuestion(let id): return "request '\(id)' is not a question"
        case .answerCount(let id, let expected, let got):
            return "request '\(id)' has \(expected) questions but got \(got) answers"
        }
    }
}

/// Claude Code as a long-lived subprocess speaking stream-json over a `LineChannel`. The
/// argv is `ClaudeLaunchSpec`, the wire `StreamJSONCodec`, the rules `ClaudeFrameMapper`;
/// this type orders them and owns the process.
@MainActor
public final class ClaudeDelegate: Delegate {
    public struct Configuration: Sendable {
        public var workspace: URL
        public var permissionMode: ClaudePermissionMode
        public var settingSources: [String]?
        /// `--model`; `nil` leaves the choice to the settings.
        public var model: String?
        /// An explicit path to `claude`; `nil` resolves it from `PATH` at start.
        public var executableOverride: String?
        /// The version the startup check accepted (D5). The first `system/init` may report
        /// another in `ClaudeVersions.supported` (an auto-update), which is logged.
        public var checkedVersion: String?
        /// D5's developer override: an unsupported `system/init` version is not a violation.
        public var allowsUnsupportedVersion: Bool

        public init(workspace: URL,
                    permissionMode: ClaudePermissionMode = .standard,
                    settingSources: [String]? = ClaudeLaunchSpec.defaultSettingSources,
                    model: String? = nil,
                    executableOverride: String? = nil,
                    checkedVersion: String? = nil,
                    allowsUnsupportedVersion: Bool = false) {
            self.workspace = workspace
            self.permissionMode = permissionMode
            self.settingSources = settingSources
            self.model = model
            self.executableOverride = executableOverride
            self.checkedVersion = checkedVersion
            self.allowsUnsupportedVersion = allowsUnsupportedVersion
        }
    }

    /// Starts the process for a launch spec, in an already sanitized environment.
    public typealias Launch = (ClaudeLaunchSpec, [String: String]) throws -> any LineChannel

    /// D13: after stdin closes, the CLI gets 5 s to flush its last message to the session
    /// file (02-8, Python SDK #625), then SIGTERM, then 2 s more before SIGKILL.
    public static let stopGrace: Duration = .seconds(5)
    public static let stopKillAfter: Duration = .seconds(2)
    /// How many stderr lines `.exited` carries.
    public static let stderrTailLimit = 20

    public let agent = AgentID.claude
    public let events: AsyncStream<DelegateEvent>

    private let configuration: Configuration
    private let environment: [String: String]
    private let diagnostics: TapQDiagnosticEmitter
    private let launch: Launch
    private let makeSessionID: () -> UUID
    private let makeRequestID: () -> String
    private let continuation: AsyncStream<DelegateEvent>.Continuation

    private var channel: (any LineChannel)?
    private var mapper: ClaudeFrameMapper?
    private var consumer: Task<Void, Never>?
    private var stderrTail: [String] = []
    private var stopping = false

    public init(configuration: Configuration,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                launch: @escaping Launch = ClaudeDelegate.spawn,
                makeSessionID: @escaping () -> UUID = UUID.init,
                makeRequestID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.configuration = configuration
        self.environment = environment
        self.diagnostics = TapQDiagnosticEmitter(category: "delegate.claude", sink: diagnostics)
        self.launch = launch
        self.makeSessionID = makeSessionID
        self.makeRequestID = makeRequestID
        // Created here, not in `start`: the kernel subscribes before anything starts the process.
        let (stream, continuation) = AsyncStream<DelegateEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    /// The default `Launch`: a `ChildProcess` in its own process group.
    public nonisolated static func spawn(_ spec: ClaudeLaunchSpec,
                                         environment: [String: String]) throws -> any LineChannel {
        try ChildProcess(executable: spec.executablePath, arguments: spec.arguments,
                         environment: environment, workingDirectory: spec.workspace)
    }

    // MARK: - Delegate

    /// Resolve the executable, `persist` the session id, then spawn (02-11): the id is on
    /// disk before any process exists that could write to that session. `system/init` is
    /// only cross-checked later. Claude Code has no handshake; the first message is `send`.
    public func start(_ session: DelegateSession, persist: (String) throws -> Void) async throws {
        guard !stopping else { throw ClaudeDelegateError.stopped }
        guard channel == nil else { throw ClaudeDelegateError.alreadyStarted }
        let executable = try ClaudeExecutable.resolve(override: configuration.executableOverride,
                                                      environment: environment,
                                                      workspacePath: configuration.workspace.path)
        let sessionID: String
        let launchSession: ClaudeLaunchSpec.Session
        switch session {
        case .fresh:
            let id = makeSessionID()
            sessionID = id.uuidString.lowercased()
            launchSession = .fresh(id)
        case .resume(let id):
            sessionID = id
            launchSession = .resume(id)
        }
        let spec = ClaudeLaunchSpec(executablePath: executable,
                                    workspace: configuration.workspace,
                                    permissionMode: configuration.permissionMode,
                                    settingSources: configuration.settingSources,
                                    model: configuration.model,
                                    session: launchSession)
        try persist(sessionID)

        let channel: any LineChannel
        do {
            channel = try launch(spec, ClaudeEnvironment.sanitized(environment))
        } catch {
            throw ClaudeDelegateError.launchFailed("\(error)")
        }
        self.channel = channel
        mapper = ClaudeFrameMapper(sessionID: sessionID, version: configuration.checkedVersion,
                                   allowsUnsupportedVersion: configuration.allowsUnsupportedVersion,
                                   diagnostics: diagnostics)
        consumer = Task { [weak self] in
            for await signal in channel.signals { self?.handle(signal) }
        }
        diagnostics.record("launched", fields: [
            "path": spec.executablePath,
            "argv": spec.arguments.joined(separator: " "),
            "workspace": configuration.workspace.path,
        ])
    }

    public func send(_ text: String) throws {
        try write(StreamJSONCodec.encodeUserMessage(text))
    }

    public func interrupt() throws {
        try write(StreamJSONCodec.encodeInterrupt(requestID: makeRequestID()))
    }

    public func resolve(permission id: String, _ decision: PermissionDecision) throws {
        try deliver(try activeMapper().reply(toPermission: id, decision), for: id)
    }

    public func resolve(question id: String, answers: [[String]]) throws {
        try deliver(try activeMapper().reply(toQuestion: id, answers: answers), for: id)
    }

    /// D13 clean stop. No event follows it: the exit is TapQ's own doing.
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        if let channel {
            await channel.terminate(grace: Self.stopGrace, killAfter: Self.stopKillAfter)
        }
        consumer?.cancel()
        continuation.finish()
        diagnostics.record("stopped")
    }

    // MARK: - Writing

    private func activeMapper() throws -> ClaudeFrameMapper {
        guard !stopping else { throw ClaudeDelegateError.stopped }
        guard let mapper else { throw ClaudeDelegateError.notStarted }
        return mapper
    }

    /// A nil reply means Claude Code withdrew the request while TapQ was deciding; the
    /// `withdrawn` event is already on its way to the kernel.
    private func deliver(_ reply: String?, for id: String) throws {
        guard let reply else {
            diagnostics.record("resolve.withdrawn", fields: ["request": id])
            return
        }
        try write(reply)
    }

    private func write(_ line: String) throws {
        guard !stopping else { throw ClaudeDelegateError.stopped }
        guard let channel else { throw ClaudeDelegateError.notStarted }
        do {
            try channel.write(line: line)
        } catch {
            diagnostics.record("write.failed", level: .error, fields: ["error": "\(error)"])
            throw ClaudeDelegateError.writeFailed("\(error)")
        }
    }

    // MARK: - Reading

    private func handle(_ signal: ChannelSignal) {
        switch signal {
        case .stdout(let line):
            let frame = StreamJSONCodec.decode(line: line)
            record(frame)
            guard let output = mapper?.map(frame) else { return }
            for reply in output.replies {
                // A failed reply means stdin is closed: the exit, or `stop`, is under way.
                try? write(reply)
            }
            for event in output.events { continuation.yield(event) }
        case .stderr(let line):
            // Counted, not copied: the text goes to the kernel with `.exited`, not to the log.
            diagnostics.record("stderr", level: .warning, fields: ["chars": "\(line.count)"])
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
        case .exited(let code):
            guard !stopping else { return }
            diagnostics.record("exited", level: .error, fields: ["code": "\(code)"])
            continuation.yield(.exited(code: code, stderrTail: stderrTail))
        }
    }

    /// Kinds, ids and sizes only: no frame text reaches the log (D3).
    private func record(_ frame: ClaudeFrame) {
        switch frame {
        case .ignored(let kind, let level):
            diagnostics.record("frame.ignored", level: level, fields: ["kind": kind])
        case .elicitation(let id, let server):
            diagnostics.record("elicitation.declined", level: .warning,
                               fields: ["request": id, "server": server])
        case .unsupportedControl(let id, let subtype):
            diagnostics.record("control.unsupported", level: .warning,
                               fields: ["request": id, "subtype": subtype])
        case .cancel(let id):
            diagnostics.record("control.cancel", fields: ["request": id])
        case .violation:
            diagnostics.record("frame.violation", level: .error)
        case .permissionDenied(let tool, let reasonType):
            diagnostics.record("permission.denied", level: .warning,
                               fields: ["tool": tool, "type": reasonType ?? "unknown"])
        case .taskStarted:
            diagnostics.record("task.started", level: .debug)
        case .taskEnded(_, let status):
            diagnostics.record("task.ended", level: .debug, fields: ["status": status])
        case .systemInit, .assistant, .toolResults, .result, .canUseTool:
            break
        }
    }
}
