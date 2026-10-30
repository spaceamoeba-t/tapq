import Foundation
import XCTest
import TapQContracts
@testable import TapQKernel

// The doubles the loop is proved against: one per protocol the kernel consumes. Each one
// is driven by the test, so a timeline is the order the test chose, and every wait is on
// the event the test asserts.

/// One ordered list of what happened, across collaborators. Append-before-act is only
/// visible in a list that the journal store and the actors both write into.
@MainActor
final class CallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) { calls.append(call) }

    func index(of call: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let index = calls.firstIndex(of: call) else {
            XCTFail("no call \(call) in \(calls)", file: file, line: line)
            return -1
        }
        return index
    }
}

/// A value shared with tasks off the main actor.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
    private let storage = Locked<[TapQDiagnosticEvent]>([])

    func record(_ event: TapQDiagnosticEvent) { storage.withValue { $0.append(event) } }

    var events: [TapQDiagnosticEvent] { storage.withValue { $0 } }

    func named(_ name: String) -> [TapQDiagnosticEvent] { events.filter { $0.name == name } }
}

@MainActor
final class RecordingFatal: FatalHandling {
    private(set) var reasons: [FatalReason] = []

    func crash(_ reason: FatalReason) { reasons.append(reason) }
}

struct FakeError: Error, Equatable {}

@MainActor
final class RecordingJournalStore: JournalPersisting {
    private let log: CallLog
    var seed: [JournalRecord] = []
    var loadError: (any Error)?
    /// The entry name whose append throws.
    var failing: String?
    private(set) var appended: [JournalRecord] = []

    init(log: CallLog) { self.log = log }

    var entries: [JournalEntry] { appended.map(\.entry) }

    func append(_ record: JournalRecord) throws {
        if record.entry.name == failing { throw FakeError() }
        appended.append(record)
        log.record("journal.\(record.entry.name)")
    }

    func load() throws -> [JournalRecord] {
        if let loadError { throw loadError }
        return seed
    }
}

@MainActor
final class FakeDelegate: Delegate {
    struct Permission: Equatable {
        let id: String
        let decision: PermissionDecision
    }

    struct Answer: Equatable {
        let id: String
        let answers: [[String]]
    }

    let agent: AgentID
    let events: AsyncStream<DelegateEvent>
    private let continuation: AsyncStream<DelegateEvent>.Continuation
    private let log: CallLog

    /// The id `persist` gets for a fresh session.
    var freshSessionID = "session-new"
    /// `start` throws this before persisting: a spawn or handshake that fails.
    var startError: (any Error)?
    /// `start` waits for `releaseStart()`, or for `stop()`, which makes it throw: a slow spawn.
    var holdsStart = false
    private(set) var startHeld = false
    private var startRelease: CheckedContinuation<Void, any Error>?
    /// `stop` waits for `releaseStop()`: a process slow to end.
    var holdsStop = false
    private(set) var stopHeld = false
    private var stopRelease: CheckedContinuation<Void, Never>?
    private(set) var starts: [DelegateSession] = []
    private(set) var sent: [String] = []
    private(set) var interrupts = 0
    private(set) var permissions: [Permission] = []
    private(set) var answers: [Answer] = []
    private(set) var stopped = false
    private(set) var emitted = 0
    /// The chat its app shows, for a chat in the user's app (2026-10-24); nil shows none.
    var shown: String?
    private(set) var shownReads = 0

    init(agent: AgentID, log: CallLog) {
        self.agent = agent
        self.log = log
        (events, continuation) = AsyncStream<DelegateEvent>.makeStream()
    }

    func emit(_ event: DelegateEvent) {
        emitted += 1
        continuation.yield(event)
    }

    func finishEvents() { continuation.finish() }

    func start(_ session: DelegateSession, persist: (String) throws -> Void) async throws {
        if holdsStart {
            try await withCheckedThrowingContinuation { continuation in
                startRelease = continuation
                startHeld = true
            }
        }
        if let startError { throw startError }
        switch session {
        case .fresh: try persist(freshSessionID)
        case .resume(let id): try persist(id)
        }
        starts.append(session)
        log.record("\(agent.rawValue).start")
    }

    func releaseStart() {
        startRelease?.resume()
        startRelease = nil
    }

    func shownConversation() async -> String? {
        shownReads += 1
        log.record("\(agent.rawValue).shown")
        return shown
    }

    func releaseStop() {
        stopRelease?.resume()
        stopRelease = nil
    }

    /// `send` throws this: a write to a process that is gone.
    var sendError: (any Error)?

    func send(_ text: String) throws {
        if let sendError { throw sendError }
        sent.append(text)
        log.record("\(agent.rawValue).send")
    }

    func interrupt() throws {
        interrupts += 1
        log.record("\(agent.rawValue).interrupt")
    }

    func resolve(permission id: String, _ decision: PermissionDecision) throws {
        permissions.append(Permission(id: id, decision: decision))
        log.record("\(agent.rawValue).resolve")
    }

    func resolve(question id: String, answers newAnswers: [[String]]) throws {
        answers.append(Answer(id: id, answers: newAnswers))
        log.record("\(agent.rawValue).resolve")
    }

    func stop() async {
        stopped = true
        log.record("\(agent.rawValue).stop")
        startRelease?.resume(throwing: FakeError())
        startRelease = nil
        if holdsStop {
            await withCheckedContinuation { continuation in
                stopRelease = continuation
                stopHeld = true
            }
        }
        log.record("\(agent.rawValue).stopped")
    }
}

@MainActor
final class FakeSpeechInput: SpeechInput {
    let events: AsyncStream<SpeechInputEvent>
    private let continuation: AsyncStream<SpeechInputEvent>.Continuation
    private(set) var opens = 0
    private(set) var reopens = 0
    private(set) var closed = false
    private(set) var emitted = 0

    init() {
        (events, continuation) = AsyncStream<SpeechInputEvent>.makeStream()
    }

    func emit(_ event: SpeechInputEvent) {
        emitted += 1
        continuation.yield(event)
    }

    func finishEvents() { continuation.finish() }

    var openError: (any Error)?

    func open() async throws {
        if let openError { throw openError }
        opens += 1
    }
    func reopen() async throws { reopens += 1 }
    func close() { closed = true }
}

@MainActor
final class FakeSpeechOutput: SpeechOutput {
    let events: AsyncStream<SpeechOutputEvent>
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation
    private let log: CallLog
    private(set) var texts: [String] = []
    /// What is playing: spoken and not yet reported played.
    private(set) var current: SpeechID?
    private(set) var cancelled = false
    private(set) var emitted = 0

    init(log: CallLog) {
        self.log = log
        (events, continuation) = AsyncStream<SpeechOutputEvent>.makeStream()
    }

    func speak(_ text: String, id: SpeechID) {
        XCTAssertNil(current, "speak while \(current.map { "\($0.raw)" } ?? "") is playing")
        texts.append(text)
        current = id
        log.record("speak")
    }

    func cancel() { cancelled = true }

    /// Reports the current item played back.
    func play(at instant: TimeInterval, verbatim: Bool) {
        guard let id = current else { return XCTFail("nothing is playing") }
        current = nil
        emitted += 1
        continuation.yield(.played(id, at: instant, verbatim: verbatim))
    }
}

/// A text-model call the test answers: every call waits until `reply` is given, in call
/// order. A call still waiting when the fake goes away is answered call-bound.
final class FakeTextModel<Value: Sendable, Input: Sendable>: @unchecked Sendable {
    private struct State {
        var inputs: [Input] = []
        var waiting: [CheckedContinuation<Result<Value, TextModelError>, Never>] = []
        var replies = 0
    }

    private let state = Locked(State())

    var inputs: [Input] { state.withValue { $0.inputs } }
    /// Each reply becomes one kernel input.
    var replies: Int { state.withValue { $0.replies } }

    func call(_ input: Input) async throws(TextModelError) -> Value {
        let result = await withCheckedContinuation { continuation in
            state.withValue {
                $0.inputs.append(input)
                $0.waiting.append(continuation)
            }
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func reply(_ result: Result<Value, TextModelError>) {
        let continuation = state.withValue { state -> CheckedContinuation<Result<Value, TextModelError>, Never>? in
            guard !state.waiting.isEmpty else { return nil }
            state.replies += 1
            return state.waiting.removeFirst()
        }
        continuation?.resume(returning: result)
    }

    deinit {
        state.withValue { $0.waiting }.forEach { $0.resume(returning: .failure(.callBound("test ended"))) }
    }
}

extension AgentContext {
    /// The chat agents of a harness that installs only the coding agents (2026-10-13).
    static let chatsOff = [AgentID.claudeChat, .chatgpt].map {
        AgentContext(agent: $0, phase: .notInstalled, pending: nil, hasHeldReply: false)
    }
}

/// What the intent model is asked to do with the agent (§4.2), done plainly for the fakes: the
/// agent a test's sentence names first or last, else the one whose request was heard, else the
/// one spoken to last, else Claude Code. Test-only; the kernel matches no names.
extension IntentInput {
    var namedAgent: AgentID {
        let lowered = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // "Claude chat" before the bare "Claude", which is Claude Code (2026-10-13).
        for (alias, agent) in [("claude chat", AgentID.claudeChat), ("chatgpt", .chatgpt), ("claude", .claude),
                               ("codex", .codex)] {
            if lowered.hasPrefix(alias) || lowered.hasSuffix(", \(alias)") { return agent }
        }
        let heard = agents.filter { $0.pending?.heard == true }
        if heard.count == 1 { return heard[0].agent }
        return spokenToLast ?? .claude
    }

    /// The named agent's: what the fake decisions read.
    var pending: PendingSummary? { context(namedAgent)?.pending }
}

final class FakeIntentModel: IntentModel, Sendable {
    let model = FakeTextModel<IntentDecision, IntentInput>()

    func decide(_ input: IntentInput) async throws(TextModelError) -> IntentDecision {
        try await model.call(input)
    }
}

final class FakeSummarizer: ReplySummarizer, Sendable {
    let model = FakeTextModel<String, String>()

    func summarize(_ reply: String, agent: AgentID) async throws(TextModelError) -> String {
        try await model.call(reply)
    }
}

/// Each status asked while an agent works waits for `model.reply` (2026-10-15).
final class FakeProgressSummarizer: ProgressSummarizer, Sendable {
    let model = FakeTextModel<String, TurnSoFar>()

    func summarize(_ turn: TurnSoFar, agent: AgentID) async throws(TextModelError) -> String {
        try await model.call(turn)
    }
}

/// By default every call fails call-bound at once, so a command is read as it is and a test
/// about something else need not answer it. `manual` makes each call wait for `model.reply`.
final class FakeCommandDescriber: CommandDescriber, Sendable {
    let model = FakeTextModel<String, String>()
    private let state = Locked((manual: false, immediate: 0))

    var manual: Bool {
        get { state.withValue { $0.manual } }
        set { state.withValue { $0.manual = newValue } }
    }

    /// Each reply, immediate or given, becomes one kernel input.
    var replies: Int { state.withValue { $0.immediate } + model.replies }

    /// The workspace paths each call was given, in order.
    var workspacePaths: [[String]] { paths.withValue { $0 } }
    private let paths = Locked([[String]]())

    func describe(_ command: String, agent: AgentID, workspacePaths: [String]) async throws(TextModelError) -> String {
        paths.withValue { $0.append(workspacePaths) }
        let manual = state.withValue { state -> Bool in
            if !state.manual { state.immediate += 1 }
            return state.manual
        }
        guard manual else { throw .callBound("not described in this test") }
        return try await model.call(command)
    }
}

/// An agent's conversations, when the test answers (`model.reply`). A call-bound reply is thrown
/// as the catalog's own error, whose words the kernel speaks.
final class FakeSessionCatalog: SessionCatalog, Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    let model = FakeTextModel<[SessionSummary], URL>()
    /// The conversations open elsewhere (2026-10-12): `openNow` at once, none by default, so a
    /// test about something else never waits on a look; `openManual` makes each look wait for
    /// `openModel.reply`.
    let openModel = FakeTextModel<[OpenSession], URL>()
    private let openState = Locked((manual: false, answer: [OpenSession](), looks: 0))

    var openNow: [OpenSession] {
        get { openState.withValue { $0.answer } }
        set { openState.withValue { $0.answer = newValue } }
    }

    var openManual: Bool {
        get { openState.withValue { $0.manual } }
        set { openState.withValue { $0.manual = newValue } }
    }

    /// Every look, answered at once or not.
    var looks: Int { openState.withValue { $0.looks } }

    func sessions(in workspace: URL) async throws -> [SessionSummary] {
        do {
            return try await model.call(workspace)
        } catch TextModelError.callBound(let reason) {
            throw Failure(description: reason)
        } catch {
            throw Failure(description: "\(error)")
        }
    }

    func openSessions(in workspace: URL) async throws -> [OpenSession] {
        let (manual, answer) = openState.withValue { state -> (Bool, [OpenSession]) in
            state.looks += 1
            return (state.manual, state.answer)
        }
        guard manual else { return answer }
        do {
            return try await openModel.call(workspace)
        } catch TextModelError.callBound(let reason) {
            throw Failure(description: reason)
        }
    }
}

/// By default every call answers at once with the titles as they are, so a test about something
/// else need not name them. `manual` makes each call wait for `model.reply`.
final class FakeConversationTitler: ConversationTitler, Sendable {
    let model = FakeTextModel<[String], [String]>()
    private let state = Locked((manual: false, immediate: 0))

    var manual: Bool {
        get { state.withValue { $0.manual } }
        set { state.withValue { $0.manual = newValue } }
    }

    var replies: Int { state.withValue { $0.immediate } + model.replies }

    func names(_ titles: [String], agent: AgentID) async throws(TextModelError) -> [String] {
        let manual = state.withValue { state -> Bool in
            if !state.manual { state.immediate += 1 }
            return state.manual
        }
        guard manual else { return titles }
        return try await model.call(titles)
    }
}

/// What the kernel asked the picker (2026-10-24).
struct PickInput: Sendable, Equatable {
    let instruction: String
    let candidates: [ConversationCandidate]
    let agent: AgentID
}

/// Every pick waits for `KernelHarness.pick`: a test with conversations to carry on says where.
final class FakeConversationPicker: ConversationPicker, Sendable {
    let model = FakeTextModel<ConversationPick, PickInput>()

    func pick(_ instruction: String, among candidates: [ConversationCandidate],
              agent: AgentID) async throws(TextModelError) -> ConversationPick {
        try await model.call(PickInput(instruction: instruction, candidates: candidates, agent: agent))
    }
}

extension SessionSummary {
    /// Updated `daysAgo` days before the harness's now.
    static func made(_ id: String, _ title: String, daysAgo: Double = 0) -> SessionSummary {
        SessionSummary(id: id, title: title, updatedAt: KernelHarness.now.addingTimeInterval(-daysAgo * 86_400))
    }
}

/// Waits, bounded by wall time, until `condition` holds.
@MainActor
func waitUntil(_ description: String, timeout: Duration = .seconds(10),
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            return XCTFail("timed out waiting for \(description)", file: file, line: line)
        }
        await Task.yield()
    }
}

/// The composed loop, with every seam a double.
@MainActor
final class KernelHarness {
    static let workspace = URL(fileURLWithPath: "/tmp/projects/workspace", isDirectory: true)
    /// The wall clock conversations' ages are told against: noon UTC, Monday 2026-10-12.
    static let now = Date(timeIntervalSince1970: 1_791_806_400)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    let log = CallLog()
    let store: RecordingJournalStore
    let journal: Journal
    let sessions: KernelSessionStore
    /// Every delegate the kernel made for each agent, in order; the last is the live one.
    private(set) var delegates: [AgentID: [FakeDelegate]] = [:]
    var claudes: [FakeDelegate] { delegates[.claude] ?? [] }
    var codexes: [FakeDelegate] { delegates[.codex] ?? [] }
    var chatgpts: [FakeDelegate] { delegates[.chatgpt] ?? [] }
    var claudeChats: [FakeDelegate] { delegates[.claudeChat] ?? [] }
    var claude: FakeDelegate { delegate(.claude) }
    var codex: FakeDelegate { delegate(.codex) }
    var chatgpt: FakeDelegate { delegate(.chatgpt) }
    var claudeChat: FakeDelegate { delegate(.claudeChat) }
    /// How many delegates the kernel asked for, per agent.
    private var made: [AgentID: Int] = [:]
    let input = FakeSpeechInput()
    let output: FakeSpeechOutput
    let intent = FakeIntentModel()
    let summarizer = FakeSummarizer()
    let describer = FakeCommandDescriber()
    let progress = FakeProgressSummarizer()
    let claudeCatalog = FakeSessionCatalog()
    let codexCatalog = FakeSessionCatalog()
    /// The chat agents' (2026-10-13): a chat in the user's app never has it read; a chat over
    /// the API lists TapQ's own chats through it.
    let chatCatalog = FakeSessionCatalog()
    let titler = FakeConversationTitler()
    let picker = FakeConversationPicker()
    let fatal = RecordingFatal()
    let sink = RecordingSink()
    private(set) var reports: [StatusReport] = []
    private(set) var kernel: Kernel!
    private let directory: URL
    private var runTask: Task<Void, Never>?
    private var decisions = 0
    private var summaries = 0
    private var descriptions = 0
    private var progressSummaries = 0
    private var listings: [ObjectIdentifier: Int] = [:]
    /// Catalog reads a first instruction makes in-line: answered, they are no kernel input.
    private var offers = 0
    private var picks = 0
    private var namings = 0
    private var item = 0
    /// The capture clock: every instant the harness hands out is later than the last.
    private var clock: TimeInterval = 0

    init(installed: Set<AgentID> = [.claude, .codex],
         seed: [JournalEntry] = [],
         sessionIDs: [AgentID: String] = [:],
         intentTimeout: Duration = .seconds(3600),
         startTimeout: Duration = .seconds(3600),
         openTimeout: Duration = .seconds(3600),
         chatBackends: [AgentID: ChatBackend] = [:],
         missingKeys: Set<AgentID> = [],
         notOnPlan: Set<AgentID> = [],
         workspaceRealPath: String? = nil,
         roster: [AgentID] = AgentID.mac,
         folderName: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-kernel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessions = KernelSessionStore(directory: directory)
        for (agent, id) in sessionIDs { try sessions.save(id, for: agent) }

        store = RecordingJournalStore(log: log)
        store.seed = seed.enumerated().map { JournalRecord(seq: $0.offset + 1, atMillis: 0, entry: $0.element) }
        journal = Journal(store: store, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        output = FakeSpeechOutput(log: log)
        for agent in AgentID.allCases { delegates[agent] = [FakeDelegate(agent: agent, log: log)] }
        var configuration = KernelConfiguration(workspace: Self.workspace, intentTimeout: intentTimeout,
                                                startTimeout: startTimeout, openTimeout: openTimeout,
                                                installed: installed)
        configuration.chatBackends = chatBackends
        configuration.missingKeys = missingKeys
        configuration.notOnPlan = notOnPlan
        configuration.workspaceRealPath = workspaceRealPath
        configuration.progressTimeout = .seconds(3600)
        configuration.roster = roster
        configuration.folderName = folderName
        let factories = Dictionary(uniqueKeysWithValues: AgentID.allCases.map { agent -> (AgentID, DelegateFactory) in
            (agent, { [unowned self] in self.nextDelegate(agent) })
        })
        kernel = Kernel(configuration: configuration, journal: journal, sessions: sessions,
                        delegates: factories,
                        input: input, output: output,
                        intent: intent, summarizer: summarizer, describer: describer,
                        progressSummarizer: progress,
                        catalogs: [.claude: claudeCatalog, .codex: codexCatalog,
                                   .claudeChat: chatCatalog, .chatgpt: chatCatalog],
                        titler: titler, picker: picker, fatal: fatal,
                        diagnostics: sink,
                        status: { [unowned self] in self.reports.append($0) },
                        monotonicNow: { 0 },
                        now: { Self.now }, calendar: Self.calendar)
    }

    var entries: [JournalEntry] { store.entries }

    /// The first for each agent is made with the harness, so a test can set it up before
    /// `start()`; each later one is the fresh process after a failure.
    private func nextDelegate(_ agent: AgentID) -> FakeDelegate {
        let count = made[agent, default: 0]
        made[agent] = count + 1
        guard count > 0 else { return delegate(agent) }
        let fresh = FakeDelegate(agent: agent, log: log)
        delegates[agent, default: []].append(fresh)
        return fresh
    }

    /// The agent's live delegate: the last the kernel made.
    func delegate(_ agent: AgentID) -> FakeDelegate {
        delegates[agent]![delegates[agent]!.count - 1]
    }

    func start() async {
        runTask = Task { await kernel.run() }
        await waitUntil("the kernel to open input") { input.opens == 1 || !fatal.reasons.isEmpty }
    }

    func finish() async {
        kernel.shutdown()
        await runTask?.value
        try? FileManager.default.removeItem(at: directory)
    }

    /// Waits for the run to end on its own (a fatal).
    func ended() async {
        await runTask?.value
        try? FileManager.default.removeItem(at: directory)
    }

    func now() -> TimeInterval {
        clock += 1
        return clock
    }

    /// One utterance, start to transcript. `at` is the VAD start; `.some(nil)` is a start
    /// the service did not time.
    @discardableResult
    func say(_ text: String, at: TimeInterval?? = nil) -> String {
        item += 1
        let id = "item-\(item)"
        input.emit(.speechStarted(itemID: id, at: at ?? now()))
        input.emit(.speechStopped(itemID: id))
        input.emit(.utterance(itemID: id, text: text))
        return id
    }

    /// Answers the next intent call with what `make` builds from its input, for `agent`, or
    /// the agent the sentence names (`IntentInput.namedAgent`).
    @discardableResult
    /// `basis`: why the model says it chose the agent (2026-10-13).
    func decide(for agent: AgentID? = nil, basis: IntentDecision.Basis = .name, file: StaticString = #filePath, line: UInt = #line,
                _ make: (IntentInput) -> Intent) async -> IntentInput? {
        let index = decisions
        await waitUntil("intent call \(index + 1)", file: file, line: line) {
            intent.model.inputs.count > index
        }
        guard intent.model.inputs.count > index else { return nil }
        decisions += 1
        let input = intent.model.inputs[index]
        intent.model.reply(.success(IntentDecision(agent: agent ?? input.namedAgent, intent: make(input),
                                                   basis: basis)))
        return input
    }

    func decide(_ decision: Intent, file: StaticString = #filePath, line: UInt = #line) async {
        await decide(file: file, line: line) { _ in decision }
    }

    /// Answers the next intent call with no agent: the model could not tell which.
    @discardableResult
    func decideWithoutAgent(_ decision: Intent, file: StaticString = #filePath, line: UInt = #line) async -> IntentInput? {
        let index = decisions
        await waitUntil("intent call \(index + 1)", file: file, line: line) { intent.model.inputs.count > index }
        guard intent.model.inputs.count > index else { return nil }
        decisions += 1
        intent.model.reply(.success(IntentDecision(agent: nil, intent: decision)))
        return intent.model.inputs[index]
    }

    func failDecision(_ error: TextModelError, file: StaticString = #filePath, line: UInt = #line) async {
        let index = decisions
        await waitUntil("intent call \(index + 1)", file: file, line: line) {
            intent.model.inputs.count > index
        }
        decisions += 1
        intent.model.reply(.failure(error))
    }

    @discardableResult
    func approve(always: Bool = false) async -> IntentInput? {
        await decide { .approve(requestID: $0.pending?.requestID ?? "", always: always) }
    }

    func summarize(_ result: Result<String, TextModelError>,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let index = summaries
        await waitUntil("summary call \(index + 1)", file: file, line: line) {
            summarizer.model.inputs.count > index
        }
        summaries += 1
        summarizer.model.reply(result)
    }

    /// Answers the next description call (with `describer.manual` on); returns its command.
    @discardableResult
    func describe(_ result: Result<String, TextModelError>,
                  file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let index = descriptions
        await waitUntil("description call \(index + 1)", file: file, line: line) {
            describer.model.inputs.count > index
        }
        guard describer.model.inputs.count > index else { return nil }
        descriptions += 1
        describer.model.reply(result)
        return describer.model.inputs[index]
    }

    /// Answers the next status summary call; returns the turn it was asked about.
    @discardableResult
    func summarizeProgress(_ result: Result<String, TextModelError>,
                           file: StaticString = #filePath, line: UInt = #line) async -> TurnSoFar? {
        let index = progressSummaries
        await waitUntil("progress call \(index + 1)", file: file, line: line) {
            progress.model.inputs.count > index
        }
        guard progress.model.inputs.count > index else { return nil }
        progressSummaries += 1
        progress.model.reply(result)
        return progress.model.inputs[index]
    }

    /// The catalog the kernel reads `agent`'s conversations from.
    func catalog(_ agent: AgentID) -> FakeSessionCatalog {
        switch agent {
        case .claude: return claudeCatalog
        case .codex: return codexCatalog
        case .claudeChat, .chatgpt: return chatCatalog
        }
    }

    /// Answers the next listing of `agent`'s conversations.
    func list(_ agent: AgentID = .claude, _ result: Result<[SessionSummary], TextModelError>,
              file: StaticString = #filePath, line: UInt = #line) async {
        let catalog = catalog(agent)
        let index = listings[ObjectIdentifier(catalog), default: 0]
        await waitUntil("listing \(index + 1) of \(agent.rawValue)", file: file, line: line) {
            catalog.model.inputs.count > index
        }
        listings[ObjectIdentifier(catalog)] = index + 1
        catalog.model.reply(result)
    }

    /// Answers the catalog read a first instruction to `agent` makes (2026-10-24): the
    /// conversations it may carry on. Read in-line, so its answer is no kernel input.
    func offer(_ agent: AgentID = .claude, _ result: Result<[SessionSummary], TextModelError>,
               file: StaticString = #filePath, line: UInt = #line) async {
        offers += 1
        await list(agent, result, file: file, line: line)
    }

    /// Answers the next pick; returns what the kernel asked.
    @discardableResult
    func pick(_ result: Result<ConversationPick, TextModelError>,
              file: StaticString = #filePath, line: UInt = #line) async -> PickInput? {
        let index = picks
        await waitUntil("pick call \(index + 1)", file: file, line: line) { picker.model.inputs.count > index }
        guard picker.model.inputs.count > index else { return nil }
        picks += 1
        picker.model.reply(result)
        return picker.model.inputs[index]
    }

    /// Answers the next naming call (with `titler.manual` on); returns the titles it was given.
    @discardableResult
    func name(_ result: Result<[String], TextModelError>,
              file: StaticString = #filePath, line: UInt = #line) async -> [String]? {
        let index = namings
        await waitUntil("naming call \(index + 1)", file: file, line: line) { titler.model.inputs.count > index }
        guard titler.model.inputs.count > index else { return nil }
        namings += 1
        titler.model.reply(result)
        return titler.model.inputs[index]
    }

    /// Waits until `text` is playing.
    func speaking(_ text: String, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("TapQ to say \"\(text)\"", file: file, line: line) {
            output.current != nil && output.texts.last == text
        }
    }

    /// Waits until `text` is playing, reports it played, and waits for the kernel to take
    /// that in.
    func hear(_ text: String, verbatim: Bool = true,
              file: StaticString = #filePath, line: UInt = #line) async {
        await speaking(text, file: file, line: line)
        output.play(at: now(), verbatim: verbatim)
        await settle(file: file, line: line)
    }

    func waitForEntry(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                      _ match: (JournalEntry) -> Bool) async {
        await waitUntil("journal \(description)", file: file, line: line) { entries.contains(where: match) }
    }

    /// Every event the fakes have produced, each one kernel input.
    var emitted: Int {
        input.emitted + output.emitted + delegates.values.joined().map(\.emitted).reduce(0, +)
            + intent.model.replies + summarizer.model.replies + describer.replies + progress.model.replies
            + claudeCatalog.model.replies + codexCatalog.model.replies + chatCatalog.model.replies
            + titler.replies - offers
    }

    /// Waits until the kernel has handled every event produced so far, for the assertions
    /// that something did NOT happen.
    func settle(file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the kernel to settle", file: file, line: line) {
            kernel.inputsHandled >= emitted
        }
    }

    /// Drives `agent` from none to working on `task`: started at once (2026-10-24), with no
    /// conversation to carry on.
    func launch(_ agent: AgentID = .claude, task: String = "run the tests") async {
        say("\(agent == .claude ? "Claude" : "Codex"), \(task)")
        await decide(.instruct(text: task))
        await offer(agent, .success([]))
        await hear("Okay.")
    }

    var lastReport: StatusReport? { reports.last }

    func phase(_ agent: AgentID) -> AgentPhase? {
        agentReport(agent)?.phase
    }

    /// `agent`'s part of the last status line.
    func agentReport(_ agent: AgentID) -> StatusReport.Agent? {
        lastReport?.agents.first { $0.agent == agent }
    }
}

extension PermissionRequest {
    static func bash(_ id: String, _ command: String, reason: String? = nil) -> PermissionRequest {
        PermissionRequest(id: id, tool: "Bash", inputJSON: #"{"command":"\#(command)"}"#,
                          command: command, reason: reason)
    }
}
