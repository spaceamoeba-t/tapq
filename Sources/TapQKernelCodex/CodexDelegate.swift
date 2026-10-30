import Foundation
import TapQContracts
import TapQKernel
import TapQPOSIXSupport

public enum CodexDelegateError: Error, Equatable, CustomStringConvertible {
    case alreadyStarted
    case notStarted
    case notLoggedIn
    /// The D5 refusal sentence, from `VersionRange.refusal`.
    case unsupportedVersion(String)
    /// An error response to a handshake or thread request.
    case rejected(method: String, message: String)
    case violation(String)
    case exited(Int32)
    case writeFailed(String)
    /// `resolve` for a request the delegate never saw, or already answered.
    case unknownRequest(String)
    case notAPermission(String)
    case notAQuestion(String)
    case answerCount(id: String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .alreadyStarted: return "the Codex delegate is already running"
        case .notStarted: return "the Codex delegate is not running"
        case .notLoggedIn: return "Codex is not logged in; run `codex login`"
        case .unsupportedVersion(let refusal): return refusal
        case .rejected(let method, let message): return "Codex refused \(method): \(message)"
        case .violation(let reason): return reason
        case .exited(let code): return "codex app-server exited with code \(code)"
        case .writeFailed(let detail): return "could not write to codex's stdin: \(detail)"
        case .unknownRequest(let id): return "no pending Codex request '\(id)'"
        case .notAPermission(let id): return "Codex request '\(id)' is not a permission"
        case .notAQuestion(let id): return "Codex request '\(id)' is not a question"
        case .answerCount(let id, let expected, let got):
            return "Codex request '\(id)' has \(expected) questions, got \(got) answers"
        }
    }
}

/// Who reviews Codex's approval requests (`approvalsReviewer`): the user, through TapQ, or,
/// opt-in with `--auto-mode` (2026-10-12), Codex's own `auto_review` agent, which approves or
/// denies them itself.
public enum CodexApprovalsReviewer: String, Sendable, Equatable {
    case user
    case autoReview = "auto_review"
}

/// Codex as a delegate over `codex app-server` and a `LineChannel` (the wire as of
/// `rust-v0.161.0`). The wire is `CodexRPCCodec`, the vocabulary
/// `CodexMapper`; this class owns the handshake, the turn and the open requests.
@MainActor
public final class CodexDelegate: Delegate {
    public typealias Spawn = @MainActor (CodexLaunchSpec) throws -> any LineChannel

    public struct Configuration: Sendable {
        public var workspace: URL
        public var executablePath: String
        /// TapQ's version, sent as `clientInfo.version`.
        public var clientVersion: String
        /// The thread's `model` on `thread/start` and `thread/resume`; `nil` leaves the
        /// choice to Codex's config.
        public var model: String?
        /// D5's developer override: an unsupported `userAgent` version is logged, not refused.
        public var allowsUnsupportedVersion: Bool
        public var reviewer: CodexApprovalsReviewer

        public init(workspace: URL, executablePath: String, clientVersion: String,
                    model: String? = nil, allowsUnsupportedVersion: Bool = false,
                    reviewer: CodexApprovalsReviewer = .user) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.clientVersion = clientVersion
            self.model = model
            self.allowsUnsupportedVersion = allowsUnsupportedVersion
            self.reviewer = reviewer
        }
    }

    /// The model TapQ starts and resumes Codex's threads on, whatever the user's
    /// config.toml names (maintainer, 2026-10-11).
    public nonisolated static let defaultModel = "gpt-5.6-luna"
    public nonisolated static let modelEnvironmentKey = "TAPQ_CODEX_MODEL"

    /// `TAPQ_CODEX_MODEL` when set and non-blank, else ``defaultModel``.
    public nonisolated static func resolvedModel(environment: [String: String]) -> String {
        let override = environment[modelEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? defaultModel : override
    }

    /// The production `spawn`: the composition passes `CodexDelegate.spawnChildProcess`.
    public static func spawnChildProcess(_ spec: CodexLaunchSpec) throws -> any LineChannel {
        try ChildProcess(executable: spec.executablePath, arguments: spec.arguments,
                         environment: spec.environment, workingDirectory: spec.workspace)
    }

    /// The streams TapQ never reads, dropped at the source (research §1.2).
    nonisolated static let optOutNotificationMethods = [
        "item/agentMessage/delta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
        "item/plan/delta", "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta", "rawResponseItem/completed", "turn/diff/updated",
    ]
    /// D2, sent on `thread/start` and `thread/resume` alike, and asserted in the response.
    static func policy(_ reviewer: CodexApprovalsReviewer) -> String {
        #""approvalPolicy":"on-request","sandbox":"workspace-write","approvalsReviewer":"\#(reviewer.rawValue)""#
    }
    static let stderrTailLimit = 20
    static let withdrawnLimit = 64

    private enum Outgoing {
        case call(String, CheckedContinuation<JSONValue, any Error>)
        case turnStart
        case steer(String)
        case interrupt

        var method: String {
            switch self {
            case .call(let method, _): return method
            case .turnStart: return "turn/start"
            case .steer: return "turn/steer"
            case .interrupt: return "turn/interrupt"
            }
        }
    }

    private enum Response {
        case result(JSONValue)
        case error(code: Int, message: String, info: String?)
    }

    public let agent = AgentID.codex
    public let events: AsyncStream<DelegateEvent>

    private let configuration: Configuration
    private let environment: [String: String]
    private let spawn: Spawn
    private let diagnostics: TapQDiagnosticEmitter
    private let continuation: AsyncStream<DelegateEvent>.Continuation

    private var channel: (any LineChannel)?
    private var reader: Task<Void, Never>?
    private var threadID = ""
    private var nextID = 1
    private var outstanding: [Int: Outgoing] = [:]
    /// The turn `turn/steer` and `turn/interrupt` address; nil between turns.
    private var activeTurn: String?
    private var lastCompletedTurn: String?
    /// A `turn/start` is out and its turn id has not arrived; input and an interrupt wait for it.
    private var startingTurn = false
    private var waitingInput: [String] = []
    private var interruptWaiting = false
    /// This turn's items by id: a file change's paths come from its `item/started`.
    private var items: [String: JSONValue] = [:]
    private var lastAgentText: String?
    /// In arrival order, so the withdrawals at a turn's end keep it.
    private var open: [OpenRequest] = []
    /// The last `withdrawnLimit` requests Codex withdrew. A decision on one is dropped: the
    /// kernel may decide on a request in the moment it is withdrawn.
    private var withdrawn: [String] = []
    private var stderrTail: [String] = []
    private var exitCode: Int32?
    private var stopping = false

    public init(configuration: Configuration,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                spawn: @escaping Spawn,
                diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.configuration = configuration
        self.environment = environment
        self.spawn = spawn
        self.diagnostics = TapQDiagnosticEmitter(category: "delegate.codex", sink: diagnostics)
        // Created here, not in `start`: the kernel subscribes before anything starts the process.
        (events, continuation) = AsyncStream<DelegateEvent>.makeStream()
    }

    // MARK: - Delegate

    public func start(_ session: DelegateSession, persist: (String) throws -> Void) async throws {
        guard channel == nil else { throw CodexDelegateError.alreadyStarted }
        let channel = try spawn(CodexLaunchSpec(executablePath: configuration.executablePath,
                                                workspace: configuration.workspace,
                                                environment: environment))
        self.channel = channel
        reader = Task { [weak self] in
            for await signal in channel.signals { self?.receive(signal) }
        }

        let server = try await call("initialize", Self.initializeParams(clientVersion: configuration.clientVersion))
        try checkVersion(userAgent: server["userAgent"]?.stringValue ?? "")
        try write(CodexRPCCodec.notification(method: "initialized"))
        let account = try await call("account/read", "{}")
        if (account["account"] ?? .null) == .null, account["requiresOpenaiAuth"]?.boolValue != false {
            throw CodexDelegateError.notLoggedIn
        }

        let cwd = JSONText.quoted(configuration.workspace.path)
        let model = configuration.model.map { ",\"model\":\(JSONText.quoted($0))" } ?? ""
        let policy = Self.policy(configuration.reviewer)
        let thread: JSONValue
        switch session {
        case .fresh:
            thread = try await call("thread/start", "{\"cwd\":\(cwd)\(model),\(policy)}")
        case .resume(let id):
            thread = try await call("thread/resume",
                                    "{\"threadId\":\(JSONText.quoted(id)),\"cwd\":\(cwd)\(model),\(policy),\"excludeTurns\":true}")
        }
        if let mismatch = CodexMapper.policyMismatch(thread, reviewer: configuration.reviewer) {
            throw CodexDelegateError.violation(mismatch)
        }
        guard let id = thread["thread"]?["id"]?.stringValue, !id.isEmpty else {
            throw CodexDelegateError.violation("Codex started a thread without an id")
        }
        if case .resume(let requested) = session, requested != id {
            throw CodexDelegateError.violation("thread/resume of \(requested) returned thread \(id)")
        }
        try persist(id)
        threadID = id
        diagnostics.record("codex.thread", fields: [
            "model": thread["model"]?.stringValue ?? "none",
            "effort": thread["reasoningEffort"]?.stringValue ?? "default",
            "reviewer": thread["approvalsReviewer"]?.stringValue ?? "none",
        ])
    }

    public func send(_ text: String) throws {
        try requireRunning()
        if let turn = activeTurn {
            try request("turn/steer", "{\"threadId\":\(JSONText.quoted(threadID)),\"input\":\(Self.input(text)),"
                            + "\"expectedTurnId\":\(JSONText.quoted(turn))}", .steer(text))
        } else {
            try startTurn(text)
        }
    }

    public func interrupt() throws {
        try requireRunning()
        if let turn = activeTurn {
            try request("turn/interrupt", "{\"threadId\":\(JSONText.quoted(threadID)),"
                            + "\"turnId\":\(JSONText.quoted(turn))}", .interrupt)
        } else if startingTurn {
            interruptWaiting = true
        } else {
            diagnostics.record("codex.interrupt_between_turns")
        }
    }

    public func resolve(permission id: String, _ decision: PermissionDecision) throws {
        guard let index = try openIndex(id) else { return }
        guard let body = CodexMapper.reply(open[index].kind, decision) else {
            throw CodexDelegateError.notAPermission(id)
        }
        let request = open.remove(at: index)
        try write(CodexRPCCodec.result(id: request.id, body))
        // T1: no Codex decision carries text, so the reason follows as the user's next words.
        // Unverified live: whether this steer lands in the turn the decline continues.
        if case .deny(let feedback?) = decision, !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try send("The user declined: \(feedback)")
        }
    }

    public func resolve(question id: String, answers: [[String]]) throws {
        guard let index = try openIndex(id) else { return }
        guard case .question(let asked, let secret) = open[index].kind else {
            throw CodexDelegateError.notAQuestion(id)
        }
        guard answers.count == asked.count else {
            throw CodexDelegateError.answerCount(id: id, expected: asked.count, got: answers.count)
        }
        let request = open.remove(at: index)
        try write(CodexRPCCodec.result(id: request.id, CodexMapper.answers(asked: asked, secret: secret, answers)))
    }

    /// D13 clean stop: close stdin, SIGTERM the group 5 s later, SIGKILL it 2 s after that.
    /// No event follows: the exit is TapQ's own doing.
    public func stop() async {
        guard let channel, !stopping else { return }
        stopping = true
        await channel.terminate(grace: .seconds(5), killAfter: .seconds(2))
        reader?.cancel()
    }

    /// The index of the open request `id`; nil when Codex already withdrew it.
    private func openIndex(_ id: String) throws -> Int? {
        if let index = open.firstIndex(where: { $0.key == id }) { return index }
        guard withdrawn.contains(id) else { throw CodexDelegateError.unknownRequest(id) }
        diagnostics.record("codex.resolve_withdrawn", fields: ["request": id])
        return nil
    }

    // MARK: - Outgoing

    nonisolated static func initializeParams(clientVersion: String) -> String {
        JSONText.object([
            ("clientInfo", JSONText.object([("name", #""tapq""#), ("title", #""TapQ""#),
                                                 ("version", JSONText.quoted(clientVersion))])),
            ("capabilities", JSONText.object([
                ("experimentalApi", "false"), ("requestAttestation", "false"),
                ("optOutNotificationMethods", JSONText.array(optOutNotificationMethods.map(JSONText.quoted))),
            ])),
        ])
    }

    static func input(_ text: String) -> String {
        #"[{"type":"text","text":\#(JSONText.quoted(text)),"text_elements":[]}]"#
    }

    private func startTurn(_ text: String) throws {
        guard !startingTurn else { return waitingInput.append(text) }
        startingTurn = true
        try request("turn/start", "{\"threadId\":\(JSONText.quoted(threadID)),\"input\":\(Self.input(text))}",
                    .turnStart)
    }

    private func call(_ method: String, _ params: String) async throws -> JSONValue {
        if let exitCode { throw CodexDelegateError.exited(exitCode) }
        let id = allocateID()
        let line = CodexRPCCodec.request(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { waiter in
            outstanding[id] = .call(method, waiter)
            do {
                try write(line)
            } catch {
                outstanding[id] = nil
                waiter.resume(throwing: error)
            }
        }
    }

    private func request(_ method: String, _ params: String, _ outgoing: Outgoing) throws {
        let id = allocateID()
        outstanding[id] = outgoing
        try write(CodexRPCCodec.request(id: id, method: method, params: params))
    }

    private func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func write(_ line: String) throws {
        guard let channel else { throw CodexDelegateError.notStarted }
        do {
            try channel.write(line: line)
        } catch {
            throw CodexDelegateError.writeFailed("\(error)")
        }
    }

    /// A write from a handler has no caller to throw to. It fails only once the channel is
    /// closed, and the `.exited` that follows is the fatal.
    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            diagnostics.record("codex.write_failed", level: .error, fields: ["error": "\(error)"])
        }
    }

    private func requireRunning() throws {
        guard !threadID.isEmpty, !stopping else { throw CodexDelegateError.notStarted }
    }

    private func checkVersion(userAgent: String) throws {
        guard let version = CodexVersions.parse(userAgent: userAgent) else {
            throw CodexDelegateError.violation("Codex's initialize response names no version")
        }
        guard !CodexVersions.supported.contains(version) else { return }
        guard configuration.allowsUnsupportedVersion else {
            throw CodexDelegateError.unsupportedVersion(CodexVersions.supported.refusal(for: .codex, found: version))
        }
        diagnostics.record("codex.version_override", level: .warning, fields: ["version": version])
    }

    // MARK: - Incoming

    private func emit(_ event: DelegateEvent) {
        continuation.yield(event)
    }

    private func receive(_ signal: ChannelSignal) {
        switch signal {
        case .stdout(let line):
            handle(line)
        case .stderr(let line):
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
        case .exited(let code):
            exitCode = code
            for case .call(_, let waiter) in outstanding.values {
                waiter.resume(throwing: CodexDelegateError.exited(code))
            }
            outstanding.removeAll()
            if !stopping { emit(.exited(code: code, stderrTail: stderrTail)) }
        }
    }

    private func handle(_ line: String) {
        guard line.first == "{" else {
            return diagnostics.record("codex.stdout_ignored", level: .warning, fields: ["chars": String(line.count)])
        }
        guard let message = CodexRPCCodec.decode(line) else {
            return emit(.violation("Codex sent a line that is not JSON-RPC (\(line.count) characters)"))
        }
        switch message {
        case .request(let id, let method, let params): serverRequest(id: id, method: method, params: params)
        case .result(let id, let result): answered(id, .result(result))
        case .error(let id, let code, let message, let info): answered(id, .error(code: code, message: message, info: info))
        case .notification(let method, let params): notification(method, params)
        }
    }

    private func answered(_ id: Int, _ response: Response) {
        guard let outgoing = outstanding.removeValue(forKey: id) else {
            return emit(.violation("Codex answered request \(id), which TapQ never sent"))
        }
        switch (outgoing, response) {
        case (.call(_, let waiter), .result(let result)):
            waiter.resume(returning: result)
        case (.call(let method, let waiter), .error(_, let message, _)):
            waiter.resume(throwing: CodexDelegateError.rejected(method: method, message: message))
        case (.turnStart, .result(let result)):
            guard let turn = result["turn"]?["id"]?.stringValue else {
                return emit(.violation("turn/start returned no turn id"))
            }
            // The returned turn is the live one, also when `turn/start` steered a turn TapQ
            // had a stale id for; one that already completed is not adopted again.
            if turn != activeTurn, turn != lastCompletedTurn { adopt(turn) } else { startingTurn = false; flush() }
        case (.turnStart, .error(let code, let message, _)):
            // D6: a refused turn is a failed one, spoken; the words that waited on it go with it.
            diagnostics.record("codex.turn_refused", level: .warning, fields: ["code": String(code)])
            startingTurn = false
            waitingInput = []
            interruptWaiting = false
            emit(.failed(reason: message))
        case (.steer(let text), .error(let code, let message, let info)):
            switch CodexMapper.race(code: code, message: message, info: info) {
            case .noActiveTurn:
                // `turn/completed` crossed the steer: the same words open the next turn, once.
                diagnostics.record("codex.steer_race")
                activeTurn = nil
                perform { try startTurn(text) }
            case .otherTurn:
                // TapQ's turn id is stale. `turn/start` steers whatever turn is live, and its
                // result names that turn.
                diagnostics.record("codex.steer_other_turn", level: .warning)
                activeTurn = nil
                perform { try startTurn(text) }
            case nil:
                // A live turn refused the words (a review turn, `activeTurnNotSteerable`). It
                // keeps working; the user hears that the words did not land.
                diagnostics.record("codex.steer_refused", level: .warning, fields: ["code": String(code)])
                emit(.notice("Codex couldn't take that while it works: \(message). Say it again when it's done."))
            }
        case (.interrupt, .error(let code, let message, let info)):
            switch CodexMapper.race(code: code, message: message, info: info) {
            case .noActiveTurn:
                // The turn ended on its own first; its `turn/completed` is the terminal event.
                diagnostics.record("codex.interrupt_race")
            case .otherTurn(let found?) where found != lastCompletedTurn && found != activeTurn:
                diagnostics.record("codex.interrupt_other_turn", level: .warning)
                activeTurn = found
                perform { try interrupt() }
            case .otherTurn:
                diagnostics.record("codex.interrupt_other_turn", level: .warning)
            case nil:
                diagnostics.record("codex.interrupt_refused", level: .warning, fields: ["code": String(code)])
                emit(.notice("Codex couldn't stop: \(message)."))
            }
        case (.steer, .result), (.interrupt, .result):
            break
        }
    }

    private func adopt(_ turn: String) {
        activeTurn = turn
        startingTurn = false
        flush()
    }

    /// The words and the interrupt that waited for a turn id, sent now.
    private func flush() {
        let input = waitingInput
        waitingInput = []
        perform {
            for text in input { try send(text) }
            if interruptWaiting {
                interruptWaiting = false
                try interrupt()
            }
        }
    }

    private func serverRequest(id: JSONValue, method: String, params: JSONValue) {
        if method == "item/fileChange/requestApproval", CodexMapper.changes(params, items) == nil {
            diagnostics.record("codex.file_change_without_item", level: .warning)
        }
        switch CodexMapper.serverRequest(id: id, method: method, params: params, items: items) {
        case .ask(let request, let event):
            open.append(request)
            emit(event)
            if case .question(_, let secret) = request.kind, !secret.isEmpty {
                // Never read aloud and answered empty; the user is told to type it in Codex.
                diagnostics.record("codex.secret_question", level: .warning, fields: ["count": String(secret.count)])
                emit(.notice(CodexMapper.secretNotice))
            }
        case .answer(let body, let diagnostic, let spoken):
            diagnostics.record(diagnostic, level: .warning,
                               fields: ["server": params["serverName"]?.stringValue ?? ""].filter { !$0.value.isEmpty })
            perform { try write(CodexRPCCodec.result(id: id, body)) }
            emit(.notice(spoken))
        case .unhandled:
            diagnostics.record("codex.unhandled_request", level: .warning, fields: ["method": method])
            perform { try write(CodexRPCCodec.error(id: id, code: -32601, message: "TapQ does not handle \(method)")) }
        case .violation(let reason):
            emit(.violation(reason))
        }
    }

    private func notification(_ method: String, _ params: JSONValue) {
        // Another thread's turns and items (a Codex subagent's) never end or answer TapQ's
        // turn. Its items are kept, so an approval it raises can still name its files; its
        // requests are TapQ's to ask, so their `serverRequest/resolved` still withdraws them.
        if method != "serverRequest/resolved", let thread = params["threadId"]?.stringValue, thread != threadID {
            if method == "item/started" || method == "item/completed",
               let item = params["item"], let id = item["id"]?.stringValue {
                items[id] = item
            }
            return diagnostics.record("codex.other_thread", fields: ["method": method])
        }
        switch method {
        case "turn/started":
            guard let turn = params["turn"]?["id"]?.stringValue else {
                return emit(.violation("turn/started without a turn id"))
            }
            if activeTurn != turn { adopt(turn) }
        case "turn/completed":
            let turn = params["turn"] ?? .null
            let id = turn["id"]?.stringValue
            if activeTurn == id { activeTurn = nil }
            lastCompletedTurn = id
            // No request outlives its turn (§3.1): withdrawals first, then the terminal event.
            open.forEach(withdraw)
            open.removeAll()
            emit(CodexMapper.terminal(turn, lastText: lastAgentText))
            lastAgentText = nil
            items.removeAll()
        case "item/started", "item/completed":
            guard let item = params["item"], let id = item["id"]?.stringValue else {
                return diagnostics.record("codex.item_without_id", level: .warning, fields: ["method": method])
            }
            items[id] = item
            if method == "item/started", let line = CodexMapper.progress(item) { emit(.progress(line, step: id)) }
            // A step it started has ended, as its own screen turns "Running" into "Ran" (2026-10-15).
            if method == "item/completed", CodexMapper.progress(item) != nil, let outcome = CodexMapper.outcome(item) {
                emit(.stepEnded(step: id, outcome))
            }
            if method == "item/completed", item["type"]?.stringValue == "agentMessage" {
                lastAgentText = item["text"]?.stringValue
                // Its words along the way (`phase` commentary), for status (2026-10-15); the
                // final answer is the reply, not more of them. Without a phase it is both.
                if item["phase"]?.stringValue != "final_answer", let text = lastAgentText,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emit(.said(text))
                }
            }
        case "serverRequest/resolved":
            // For a request TapQ answered, this is the echo of its own reply.
            let key = params["requestId"].map(CodexMapper.key)
            guard let index = open.firstIndex(where: { $0.key == key }) else { return }
            withdraw(open.remove(at: index))
        case "item/autoApprovalReview/completed":
            // `--auto-mode` (UNSTABLE in 0.161.0): Codex's reviewer decided a request without
            // the user. Only a denial is told; the turn goes on either way.
            let review = params["review"] ?? .null
            let status = review["status"]?.stringValue ?? "unknown"
            diagnostics.record("codex.auto_review", fields: [
                "status": status, "risk": review["riskLevel"]?.stringValue ?? "none",
            ])
            if status == "denied" { emit(.notice(CodexMapper.autoReviewDenied)) }
        case "guardianWarning":
            if let message = params["message"]?.stringValue, !message.isEmpty {
                diagnostics.record("codex.guardian_warning", level: .warning)
                emit(.notice(CodexMapper.guardianWarning(message)))
            }
        case "error":
            // `turn/completed` decides; a retried or terminal error is only logged.
            diagnostics.record("codex.error", level: .warning, fields: [
                "willRetry": params["willRetry"].map(JSONText.serialize) ?? "",
                "info": JSONText.serialize(params["error"]?["codexErrorInfo"] ?? .null),
            ])
        default:
            diagnostics.record("codex.notification", level: .debug, fields: ["method": method])
        }
    }

    private func withdraw(_ request: OpenRequest) {
        withdrawn.append(request.key)
        if withdrawn.count > Self.withdrawnLimit { withdrawn.removeFirst() }
        emit(.withdrawn(requestID: request.key))
    }
}
