import Foundation
import TapQContracts

/// Makes one agent's delegate: once when the kernel runs, and again for a fresh process after
/// that agent failed (maintainer ruling 2026-10-12). Each delegate is used for one process.
public typealias DelegateFactory = @MainActor () -> any Delegate

/// Everything that can happen, in one ordered inbox. Every producer only yields here; the
/// `Kernel` is the one owner of agent state, the journal and the speech queue.
private enum KernelInput: Sendable {
    case speech(SpeechInputEvent)
    case output(SpeechOutputEvent)
    /// `generation`: which of the agent's delegates said it; an older one's events are dropped.
    case delegate(AgentID, generation: Int, DelegateEvent)
    case decided(itemID: String, Result<IntentDecision, TextModelError>)
    case summarized(agent: AgentID, finishedSeq: Int, Result<String, TextModelError>)
    case described(agent: AgentID, requestID: String, Result<String, TextModelError>)
    /// Where the agent is in its turn, for a status asked while it works (2026-10-15).
    case progressed(agent: AgentID, turn: Int, Result<String, TextModelError>)
    /// An agent's conversations, from its catalog; a catalog's throw arrives call-bound.
    case listed(agent: AgentID, Result<[SessionSummary], TextModelError>)
    /// Names for the conversations from `first` on, from the titler.
    case named(agent: AgentID, first: Int, Result<[String], TextModelError>)
    /// stdin EOF, SIGINT, SIGTERM.
    case shutdown
}

public struct KernelConfiguration: Sendable {
    public var workspace: URL
    /// The folder `workspace` leads to, every link on the way resolved (`/var` is
    /// `/private/var` on macOS), when that is another path: the one Claude Code works in, as
    /// Node resolves its working folder, while Codex keeps the path it was given (live
    /// 2026-10-15). `workspace` itself stays the key of TapQ's own state.
    public var workspaceRealPath: String?
    /// The folder's name in TapQ's sentences ("Start Claude in TapQ?"): `workspace`'s last
    /// component unless the host names it.
    public var folderName: String?
    /// Characters.
    public var summaryThreshold: Int = 120
    /// The user is waiting (R §5.1).
    public var intentTimeout: Duration = .seconds(5)
    public var summaryTimeout: Duration = .seconds(15)
    /// The agent waits on the request meanwhile; past it, the command itself is read.
    public var describeTimeout: Duration = .seconds(10)
    /// The user is waiting on a status; past it, TapQ says the agent is working and what it
    /// last said.
    public var progressTimeout: Duration = .seconds(8)
    /// Spawn and handshake; past it, the agent is stopped and its start told as failed.
    public var startTimeout: Duration = .seconds(30)
    /// Reading an agent's conversations (Codex starts an app-server for it); past it, told as failed.
    public var listTimeout: Duration = .seconds(15)
    /// Naming the conversations to read; past it, their titles are read as they are.
    public var nameTimeout: Duration = .seconds(10)
    /// Choosing the conversation a first instruction carries on (2026-10-24): the user is
    /// waiting, as on the intent call; past it, the last one is carried on, else a new one.
    public var pickTimeout: Duration = .seconds(5)
    /// Asking the agent which of its conversations are open elsewhere (Claude Code's `claude
    /// agents`, 2026-10-12); past it, TapQ goes on as if none were.
    public var openTimeout: Duration = .seconds(5)
    /// Conversations read at a time; the rest only when the user asks (maintainer, 2026-10-12).
    public var conversationsPerReading: Int = 5
    /// The agents this host runs, in the order the status line and the intent model list them.
    /// An agent off the roster has no state, no status entry and no place in the intent
    /// model's input.
    public var roster: [AgentID] = AgentID.mac
    /// From startup checks.
    public var installed: Set<AgentID>
    /// Chat agents the user turned on whose app is not on this Mac (2026-10-13): told so,
    /// rather than "isn't turned on".
    public var missingApps: Set<AgentID> = []
    /// How each chat agent is reached this run (2026-10-13); one absent is the app's.
    public var chatBackends: [AgentID: ChatBackend] = [:]
    /// Chat agents turned on over the API whose key TapQ was not given: told which key.
    public var missingKeys: Set<AgentID> = []
    /// Agents `--agents` leaves out: never started, and told so by name rather than "isn't
    /// installed".
    public var notOnPlan: Set<AgentID> = []

    /// How `agent` is reached, when it is a chat.
    public func backend(_ agent: AgentID) -> ChatBackend { chatBackends[agent] ?? .app }

    /// Every path that names the workspace: as the user picked it, then where it leads.
    public var workspacePaths: [String] {
        [workspace.path] + [workspaceRealPath].compactMap { $0 }.filter { $0 != workspace.path }
    }

    /// Whether `agent` keeps conversations TapQ resumes, lists and switches this run.
    public func resumes(_ agent: AgentID) -> Bool { agent.resumes(backend(agent)) }

    public init(workspace: URL,
                summaryThreshold: Int = 120,
                intentTimeout: Duration = .seconds(5),
                summaryTimeout: Duration = .seconds(15),
                describeTimeout: Duration = .seconds(10),
                startTimeout: Duration = .seconds(30),
                listTimeout: Duration = .seconds(15),
                nameTimeout: Duration = .seconds(10),
                openTimeout: Duration = .seconds(5),
                conversationsPerReading: Int = 5,
                installed: Set<AgentID>) {
        self.workspace = workspace
        self.summaryThreshold = summaryThreshold
        self.intentTimeout = intentTimeout
        self.summaryTimeout = summaryTimeout
        self.describeTimeout = describeTimeout
        self.startTimeout = startTimeout
        self.listTimeout = listTimeout
        self.nameTimeout = nameTimeout
        self.openTimeout = openTimeout
        self.conversationsPerReading = conversationsPerReading
        self.installed = installed
    }
}

/// The loop.
///
/// One owner: every producer (speech input, speech output, each delegate, every text-model
/// call) only yields into the inbox, and only the inbox's consumer touches agent state, the
/// journal and the speech queue. Every action a resume must know about is journaled first;
/// a failed append is fatal and the action does not happen. Nothing here catches an error
/// to carry on: the non-fatal outcomes are the user's own decisions, a call-bound text-model
/// failure (spoken), a delegate's failed turn (spoken, D6), and one agent failing, which
/// stops that agent alone (spoken, maintainer ruling 2026-10-12).
@MainActor
public final class Kernel {
    private typealias Subsystem = FatalReason.Subsystem

    /// An input; `pump`, the end-of-tick speech check, which a handler that awaited queues
    /// behind the events that arrived during its await (§4.4); or a producer's stream
    /// ending, queued behind that producer's last event.
    private enum Tick: Sendable {
        case input(KernelInput)
        case pump
        case ended(producer: String)
        case delegateEnded(AgentID, generation: Int)
    }

    /// One heard utterance on its way to the intent model, which picks its agent (§4.2).
    private struct Heard {
        let itemID: String
        let message: String
        /// The VAD's start of this item: gate condition (c).
        let startedAt: TimeInterval?
    }

    /// A decided utterance, for the agent the model chose.
    private struct Utterance {
        let itemID: String
        let agent: AgentID
        let message: String
        let startedAt: TimeInterval?
    }

    /// A text-model call racing its bound. Both yield into the inbox; the first result for
    /// the open call wins, and a later one finds the call closed.
    private struct Call {
        /// The diagnostic event its outcome is logged as.
        let name: String
        let tasks: [Task<Void, Never>]
        let startedAt: TimeInterval

        func cancel() { tasks.forEach { $0.cancel() } }
    }

    private let configuration: KernelConfiguration
    private let journal: Journal
    private let sessions: KernelSessionStore
    private let makeDelegate: [AgentID: DelegateFactory]
    private let input: any SpeechInput
    private let output: any SpeechOutput
    private let intent: any IntentModel
    private let summarizer: any ReplySummarizer
    private let describer: any CommandDescriber
    private let progressSummarizer: any ProgressSummarizer
    private let catalogs: [AgentID: any SessionCatalog]
    private let titler: any ConversationTitler
    private let picker: any ConversationPicker
    private let fatal: any FatalHandling
    private let diagnostics: TapQDiagnosticEmitter
    private let status: @MainActor (StatusReport) -> Void
    private let monotonicNow: @Sendable () -> TimeInterval
    /// The wall clock and calendar a conversation's age is told in.
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    private var agents: [AgentID: AgentState]
    /// Each agent's delegate now, and its generation: events of an earlier one are dropped.
    private var live: [AgentID: (delegate: any Delegate, generation: Int)] = [:]
    /// A failed agent's old delegate being stopped (D13); the agent's next start waits for it,
    /// so two processes never share a session.
    private var retiring: [AgentID: Task<Void, Never>] = [:]
    /// Agents whose start ran past `startTimeout`, whose start was then stopped.
    private var startOverran: Set<AgentID> = []
    private var queue = SpeechQueue()
    private var speaking: (id: SpeechID, item: SpeechQueue.Item)?
    private var lastSpeechID = 0
    /// Items between `speechStarted` and `speechStopped`.
    private var userSpeaking: Set<String> = []
    private var speechStarts: [String: TimeInterval?] = [:]
    /// Utterances waiting for the one intent call (invariant 4).
    private var utterances: [Heard] = []
    private var intentCall: (utterance: Heard, call: Call)?
    private var summaryCalls: [AgentID: (finishedSeq: Int, call: Call)] = [:]
    /// By `describeKey`: one per command request still waiting for its words.
    private var describeCalls: [String: Call] = [:]
    /// Per agent, the one status summary on its way, for the turn it was asked in.
    private var progressCalls: [AgentID: (turn: Int, call: Call)] = [:]
    /// Per agent, its conversations as last listed and read (2026-10-12), and the calls that
    /// list and name them: one of each at a time.
    private var conversations: [AgentID: ConversationList] = [:]
    private var listCalls: [AgentID: Call] = [:]
    private var nameCalls: [AgentID: (first: Int, call: Call)] = [:]
    /// Per agent, the ids of its conversations a process other than TapQ's had open when TapQ
    /// last looked (2026-10-12): at a listing, a status while TapQ's is off, and before a resume.
    /// Absent when that look could not tell.
    private var openElsewhere: [AgentID: Set<String>] = [:]
    private var lastHeard: StatusReport.LastHeard?
    /// The installed agent the last utterance went to: routing's "spoken to last" (§4.2).
    private var lastAgent: AgentID?
    /// The agent whose words TapQ last started reading: routing's "heard from last" (§4.2).
    private var heardFromLast: AgentID?
    /// Per agent, the last result-band sentence TapQ started reading for it: its reply as heard.
    private var lastSaid: [AgentID: String] = [:]
    private var lastReport: StatusReport?

    private var inbox: AsyncStream<Tick>.Continuation?
    private var forwarders: [Task<Void, Never>] = []
    private var deferredPump = false
    private var shutdownRequested = false
    private var stopping = false
    private var crashed = false
    /// Inputs fully handled. Tests wait on it to assert that something did not happen;
    /// nothing in the loop reads it.
    private(set) var inputsHandled = 0

    public init(configuration: KernelConfiguration,
                journal: Journal,
                sessions: KernelSessionStore,
                delegates: [AgentID: DelegateFactory],
                input: any SpeechInput,
                output: any SpeechOutput,
                intent: any IntentModel,
                summarizer: any ReplySummarizer,
                describer: any CommandDescriber,
                progressSummarizer: any ProgressSummarizer,
                catalogs: [AgentID: any SessionCatalog],
                titler: any ConversationTitler,
                picker: any ConversationPicker,
                fatal: any FatalHandling,
                diagnostics: any TapQDiagnosticSink,
                status: @escaping @MainActor (StatusReport) -> Void,
                monotonicNow: @escaping @Sendable () -> TimeInterval,
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.configuration = configuration
        self.journal = journal
        self.sessions = sessions
        self.makeDelegate = delegates
        self.input = input
        self.output = output
        self.intent = intent
        self.summarizer = summarizer
        self.describer = describer
        self.progressSummarizer = progressSummarizer
        self.catalogs = catalogs
        self.titler = titler
        self.picker = picker
        self.fatal = fatal
        self.diagnostics = TapQDiagnosticEmitter(category: "kernel", sink: diagnostics)
        self.status = status
        self.monotonicNow = monotonicNow
        self.now = now
        self.calendar = calendar
        agents = Dictionary(uniqueKeysWithValues: configuration.roster.map { agent in
            (agent, AgentState(phase: configuration.installed.contains(agent) ? .none : .notInstalled))
        })
    }

    // MARK: - Lifecycle

    /// Reconcile (§4.9), open input, then consume the inbox until shutdown or fatal.
    public func run() async {
        let (stream, inbox) = AsyncStream<Tick>.makeStream()
        self.inbox = inbox
        if resume() {
            forward(input.events, "speech-input") { .speech($0) }
            forward(output.events, "speech-output") { .output($0) }
            for agent in configuration.roster {
                if let make = makeDelegate[agent] { follow(agent, make(), generation: 0) }
            }
            if shutdownRequested { inbox.yield(.input(.shutdown)) }
            do {
                try await input.open()
            } catch {
                crash(Subsystem.speechInput, "open failed: \(error)")
            }
        }
        if !crashed {
            publish(ready: true)
            pump()
            for await tick in stream {
                await handle(tick)
                if case .input = tick { inputsHandled += 1 }
                if crashed || stopping { break }
            }
        }
        forwarders.forEach { $0.cancel() }
        intentCall?.call.cancel()
        summaryCalls.values.forEach { $0.call.cancel() }
        describeCalls.values.forEach { $0.cancel() }
        progressCalls.values.forEach { $0.call.cancel() }
        listCalls.values.forEach { $0.cancel() }
        nameCalls.values.forEach { $0.call.cancel() }
        inbox.finish()
        self.inbox = nil
    }

    public func shutdown() {
        guard let inbox else {
            shutdownRequested = true
            return
        }
        inbox.yield(.input(.shutdown))
    }

    /// A fatal the host met outside the kernel: the kernel's own door, exactly once, and the
    /// loop stops at the next tick. A host whose process ends at the fatal never needs this.
    public func fail(_ reason: FatalReason) {
        crash(reason.subsystem, reason.reason, reason.context)
    }

    /// Folds the journal, marks what was in flight lost, and queues one sentence per agent
    /// it cut off or whose reply was never spoken. Every agent starts with no process;
    /// nothing is resent (09-3). A chat in the user's app has no session to resume (2026-10-13).
    private func resume() -> Bool {
        for agent in configuration.installed where !configuration.roster.contains(agent) {
            crash(Subsystem.kernel, "\(agent.rawValue) is installed but not on this host's roster")
            return false
        }
        for agent in configuration.installed where makeDelegate[agent] == nil {
            crash(Subsystem.kernel, "no delegate for \(agent.rawValue)")
            return false
        }
        let found: Reconciliation
        do {
            found = Reconcile.fold(try journal.load(), resuming: Set(configuration.roster.filter(configuration.resumes)),
                                   chatBackends: configuration.chatBackends)
            for agent in configuration.roster where configuration.resumes(agent) {
                agents[agent]?.sessionID = try sessions.sessionID(for: agent)
            }
        } catch {
            crash(Subsystem.journal, "\(error)")
            return false
        }
        for entry in found.lost {
            guard append(entry) else { return false }
        }
        lastSpeechID = found.lastSpeechID
        for agent in configuration.roster {
            agents[agent]?.heldReply = found.heldReplies[agent]
        }
        found.sentences.forEach { queue.enqueue($0, band: .result) }
        if !found.lost.isEmpty {
            diagnostics.record("journal.reconciled", fields: ["lost": "\(found.lost.count)"])
        }
        return true
    }

    private func forward<Event: Sendable>(_ events: AsyncStream<Event>, _ producer: String,
                                          _ wrap: @escaping @Sendable (Event) -> KernelInput) {
        guard let inbox else { return }
        forwarders.append(Task {
            for await event in events { inbox.yield(.input(wrap(event))) }
            inbox.yield(.ended(producer: producer))
        })
    }

    /// Makes `delegate` the agent's live one and forwards its events, tagged with `generation`.
    private func follow(_ agent: AgentID, _ delegate: any Delegate, generation: Int) {
        live[agent] = (delegate, generation)
        guard let inbox else { return }
        let events = delegate.events
        forwarders.append(Task {
            for await event in events { inbox.yield(.input(.delegate(agent, generation: generation, event))) }
            inbox.yield(.delegateEnded(agent, generation: generation))
        })
    }

    private func handle(_ tick: Tick) async {
        guard !crashed else { return }
        switch tick {
        case .input(.speech(let event)): await heard(event)
        case .input(.output(let event)): played(event)
        case .input(.delegate(let agent, let generation, let event)):
            // A failed agent's old delegate may still report its own end: nothing to act on.
            if live[agent]?.generation == generation { received(event, from: agent) }
        case .input(.decided(let item, let result)): await decided(item, result)
        case .input(.summarized(let agent, let seq, let result)): summarized(agent, seq, result)
        case .input(.progressed(let agent, let turn, let result)): progressed(agent, turn, result)
        case .input(.described(let agent, let id, let result)): described(agent, id, result)
        case .input(.listed(let agent, let result)): await listed(agent, result)
        case .input(.named(let agent, let first, let result)): named(agent, first, result)
        case .input(.shutdown): await stop()
        case .ended(let producer) where !stopping:
            crash(Subsystem.kernel, "inbox producer ended", ["producer": producer])
        case .delegateEnded(let agent, let generation) where !stopping && live[agent]?.generation == generation:
            agentFailed(agent, .lostTrack, "its event stream ended")
        case .ended, .delegateEnded, .pump: break
        }
        if deferredPump {
            deferredPump = false
            inbox?.yield(.pump)
        } else {
            pump()
        }
        publish()
    }

    /// D13 clean stop. A stream that ends from here on is the stop, not a fault.
    private func stop() async {
        stopping = true
        output.cancel()
        input.close()
        for agent in configuration.roster { await live[agent]?.delegate.stop() }
        for agent in configuration.roster { await retiring[agent]?.value }
    }

    // MARK: - Speech input

    private func heard(_ event: SpeechInputEvent) async {
        switch event {
        case .speechStarted(let item, let at):
            speechStarts[item] = .some(at)
            userSpeaking.insert(item)
        case .speechStopped(let item):
            userSpeaking.remove(item)
        case .utterance(let item, let text):
            utterance(item, text, startedAt: speechStarts.removeValue(forKey: item) ?? nil)
        case .utteranceFailed(let item, let reason):
            speechStarts[item] = nil
            diagnostics.record("stt.segment_failed", level: .warning,
                               fields: ["item": item, "reason": reason])
        case .sessionExpired:
            diagnostics.record("stt.rollover",
                               fields: ["open_item": speechStarts.keys.sorted().joined(separator: ",")])
            userSpeaking = []
            speechStarts = [:]
            deferredPump = true
            do {
                try await input.reopen()
            } catch {
                crash(Subsystem.speechInput, "reopen failed: \(error)")
            }
        case .failed(let reason):
            crash(Subsystem.speechInput, reason)
        }
    }

    /// §4.5 step 1. Everything heard is the user's (ruling 2026-10-10); only a transcript with
    /// no words at all (empty, or punctuation such as "…") is dropped. Every other one goes to
    /// the intent model whole, which picks its agent (2026-10-12): no rule routes it first.
    private func utterance(_ item: String, _ text: String, startedAt: TimeInterval?) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else {
            diagnostics.record("utterance.empty")
            return
        }
        guard append(.heard(itemID: item, agent: nil, text: message)) else { return }
        lastHeard = StatusReport.LastHeard(agent: nil, text: message, action: nil)
        utterances.append(Heard(itemID: item, message: message, startedAt: startedAt))
        decideNext()
    }

    // MARK: - Intent

    private func decideNext() {
        guard !crashed, intentCall == nil, !utterances.isEmpty else { return }
        let utterance = utterances.removeFirst()
        let request = IntentInput(
            message: utterance.message,
            agents: configuration.roster.compactMap { agent in
                agents[agent].map { state in
                    AgentContext(agent: agent, phase: state.phase, pending: state.head?.summary,
                                 hasHeldReply: state.heldReply != nil, lastSaid: lastSaid[agent],
                                 conversations: choices(agent), moreConversations: conversations[agent]?.unread ?? 0)
                }
            },
            spokenToLast: lastAgent, heardFromLast: heardFromLast)
        let model = intent
        let item = utterance.itemID
        intentCall = (utterance, call("intent.call", configuration.intentTimeout, { .decided(itemID: item, $0) }) {
            () async throws(TextModelError) in try await model.decide(request)
        })
    }

    private func decided(_ item: String, _ result: Result<IntentDecision, TextModelError>) async {
        guard let (heard, call) = intentCall, heard.itemID == item else { return }
        intentCall = nil
        close(call, result)
        switch result {
        case .failure(.callBound(let reason)):
            if append(.decisionFailed(itemID: item, reason: reason)) { ack(Sentences.missed) }
        case .failure(.contract(let reason)):
            crash(Subsystem.intent, reason)
        case .success(let decision):
            await decided(heard, decision)
        }
        decideNext()
    }

    /// The model's agent, then the action (§4.2). Without an agent, a yes, no or answer could
    /// be for any request the user heard, and TapQ asks which.
    private func decided(_ heard: Heard, _ decision: IntentDecision) async {
        // State, not words: with two or more requests read out, a yes, no or answer goes to one
        // of them only when the user named its agent or its words fit that request alone.
        // Placed by the state (who was heard or spoken to last), it is asked about: the model
        // guessed so in 6 of 450 calls on prompt v5 (2026-10-13), and a consent must never go to
        // the agent the user did not mean. Counted are the requests TapQ began to read, not only
        // those heard verbatim: one being read again, or read with a paraphrase, is still one
        // the user may be answering.
        // Also the agent TapQ read last, when it is another: its words (a chat's "Want a
        // shorter version?") came after the request, so a bare yes may be for them.
        let asked = configuration.roster.filter { agents[$0]?.head?.spoken == true || $0 == heardFromLast }
        let byState = decision.agent != nil && decision.intent.isConsent && decision.basis == .state && asked.count > 1
        if byState {
            diagnostics.record("utterance.consent_by_state", fields: ["agent": decision.agent?.rawValue ?? "none",
                                                                      "asked": "\(asked.count)"])
        }
        let routed = byState ? nil : decision.agent
        guard append(.decided(itemID: heard.itemID, agent: routed, intent: decision.intent)) else { return }
        lastHeard = StatusReport.LastHeard(agent: routed, text: heard.message, action: decision.intent.name)
        diagnostics.record("utterance.routed", fields: ["agent": routed?.rawValue ?? "none", "by": "model"])
        guard let agent = routed else {
            return refuse(heard.itemID, .agentUnclear, ack: Sentences.whichAgent(byState ? asked : unplaced))
        }
        // Off the roster is never installed here: the intent model is not offered such an agent.
        if agents[agent] == nil || agents[agent]?.phase == .notInstalled {
            return refuse(heard.itemID, .notInstalled,
                          ack: Sentences.notInstalled(agent, appMissing: configuration.missingApps.contains(agent),
                                                      keyMissing: configuration.missingKeys.contains(agent),
                                                      notOnPlan: configuration.notOnPlan.contains(agent)))
        }
        lastAgent = agent
        await act(decision.intent, for: Utterance(itemID: heard.itemID, agent: agent, message: heard.message,
                                                  startedAt: heard.startedAt))
    }

    /// The agents a yes, no or answer the model could not place may be for: those whose request
    /// the user heard (2026-10-13: the chat agents make it more than two), else every installed
    /// agent.
    private var unplaced: [AgentID] {
        let heard = configuration.roster.filter { agents[$0]?.head?.promptPlayedAt != nil }
        return heard.count > 1 ? heard : configuration.roster.filter(configuration.installed.contains)
    }

    /// §4.3, for one decided utterance.
    private func act(_ decision: Intent, for utterance: Utterance) async {
        let agent = utterance.agent
        guard let state = agents[agent] else { return }
        switch decision {
        case .instruct(let text):
            await instruct(text, for: utterance)
        case .interrupt:
            guard state.phase == .working else { return ack(Sentences.notWorking(agent)) }
            guard append(.interruptSent(agent: agent)),
                  perform(agent, "interrupt", { try $0.interrupt() }) else { return }
            ack(Sentences.stopping(agent))
        case .approve, .deny, .answer:
            await resolve(decision, for: utterance)
        case .readAll:
            ack(Sentences.readAll(agent, held: state.heldReply?.text), agent: state.heldReply == nil ? nil : agent)
        case .status:
            // At work, where it is in the whole task, in words: never its last tool line, which
            // read shell commands aloud (2026-10-15).
            if state.phase == .working, let turn = state.turn, turn.hasWork {
                return summarizeProgress(turn, of: agent)
            }
            // Off, TapQ looks whether the agent is at work elsewhere, so it does not say only
            // that it isn't running while the user watches it work in another app (2026-10-12).
            let open = runs(agent) ? nil : await lookOpen(agent)
            ack(Sentences.status(agent, agents[agent] ?? state, openElsewhere: open ?? []))
        case .unclear:
            ack(Sentences.unclear(agent))
        case .listConversations:
            listConversations(agent, more: false)
        case .moreConversations:
            listConversations(agent, more: true)
        case .switchConversation(let number, let text):
            await switchConversation(number, then: text, for: utterance)
        case .newConversation(let text):
            await startNew(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", for: utterance)
        }
    }

    private var folder: String { configuration.folderName ?? configuration.workspace.lastPathComponent }

    private func instruct(_ text: String, for utterance: Utterance) async {
        let agent = utterance.agent
        guard let state = agents[agent] else { return }
        switch state.phase {
        case .none:
            await startInferred(agent, held: text)
        case .awaitingYes:
            refuse(utterance.itemID, .notHead, reaskFor: agent)
        case .working where !agent.steers:
            // A chat app's answer cannot be steered: the words are not sent, and the user says
            // them again once it is done (2026-10-13).
            refuse(utterance.itemID, .busy, ack: Sentences.stillAnswering(agent))
        case .idle, .working:
            guard journalSent(agent, text), perform(agent, "send", { try $0.send(text) }) else { return }
            if state.phase == .working { noteTurn(agent) } else { beginTurn(agent) }
            agents[agent]?.turn?.ask(text)
            agents[agent]?.phase = .working
            ack(state.phase == .working ? Sentences.steered : Sentences.okay)
        case .notInstalled:
            break
        }
    }

    /// Approve, deny or answer: the gate against the head as it is now, which may not be
    /// the head the call was made with (§4.5 step 4).
    private func resolve(_ decision: Intent, for utterance: Utterance) async {
        let agent = utterance.agent
        guard let head = agents[agent]?.head else {
            return refuse(utterance.itemID, .nothingPending, ack: Sentences.nothingWaiting)
        }
        if let refusal = Gate.refusal(requestID: decision.requestID ?? "", head: head,
                                      speechStartedAt: utterance.startedAt) {
            return refuse(utterance.itemID, refusal, reaskFor: agent)
        }
        switch (head.kind, decision) {
        case (.launch(let launch), .approve):
            guard settle(agent, head, .launch(yes: true)) else { return }
            await self.launch(agent, launch)
        case (.launch(let launch), .deny):
            guard settle(agent, head, .launch(yes: false)) else { return }
            // The user heard it fail and keeps it off: the status stops saying so.
            agents[agent]?.failure = nil
            ack(launch.running ? Sentences.staying(agent) : Sentences.stayingOff(agent))
        case (.permission(let request), .approve(_, let asked)):
            // "Don't ask again" for a request that offers no such thing is still a yes, and
            // the user hears that it will be asked again (live 2026-10-12: it was a deny).
            let always = asked && request.alwaysAllow != nil
            guard settle(agent, head, .permission(.allow(always: always))) else { return }
            ack(Sentences.allowed(agent, always: always, askedAlways: asked))
        case (.permission, .deny(_, let feedback)):
            let feedback = feedback.flatMap { $0.isEmpty ? nil : $0 }
            guard settle(agent, head, .permission(.deny(feedback: feedback))) else { return }
            ack(Sentences.denied(agent, feedback: feedback != nil))
        case (.question(let request), .answer(_, let answers))
            where answers.count == request.questions.count && !answers.contains(where: \.isEmpty):
            guard settle(agent, head, .answers(answers)) else { return }
            ack(Sentences.answered(agent))
        default:
            refuse(utterance.itemID, .incompleteAnswer, reaskFor: agent)
        }
    }

    /// Spawns the agent, after a switch's yes or at once (2026-10-24), then sends the words held
    /// for it and says `said`. Awaited in-line, so the speech queue waits for the next tick. A
    /// failed process of this agent is gone first (D13), so two never share a session; so is the
    /// one a switch leaves (2026-10-12). A start that throws, or runs past `startTimeout` (then
    /// the delegate is stopped, which makes it throw), fails this agent alone.
    private func launch(_ agent: AgentID, _ launch: Launch, said: String = Sentences.okay) async {
        deferredPump = true
        if launch.running { retire(agent) }
        if let previous = retiring.removeValue(forKey: agent) { await previous.value }
        guard !crashed, !stopping, let delegate = live[agent]?.delegate else { return }
        let session = self.session(agent, for: launch.target)
        // A chat in the user's app carries on what its app shows, never a conversation of its
        // own that could be gone.
        let resumed = session != .fresh && configuration.resumes(agent)
        let timeout = configuration.startTimeout
        let bound = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.startOverran.insert(agent)
            await delegate.stop()
        }
        defer { bound.cancel() }
        do {
            try await delegate.start(session) { id in
                // A chat in the user's app is journaled, but it keeps no session: it never
                // resumes (2026-10-13).
                do {
                    if configuration.resumes(agent) { try sessions.save(id, for: agent) }
                    try journal.append(.started(agent: agent, sessionID: id,
                                                chats: agent.kind == .chat ? configuration.backend(agent) : nil))
                } catch {
                    crash(Subsystem.journal, "\(error)")
                    throw error
                }
                if configuration.resumes(agent) { agents[agent]?.sessionID = id }
            }
        } catch {
            // After a persist failure the journal's fatal came first, and nothing is left to tell.
            let overran = startOverran.remove(agent) != nil
            guard live[agent]?.delegate === delegate else { return }
            return agentFailed(agent, .startFailed(overran ? "it did not start in time" : "\(error)"),
                               "start failed: \(error)", resumed: resumed)
        }
        if startOverran.remove(agent) != nil {
            return agentFailed(agent, .startFailed("it did not start in time"), "start overran",
                               resumed: resumed)
        }
        agents[agent]?.failure = nil
        // A chat in the user's app keeps no reply across starts: TapQ cannot tell that the chat
        // its app shows is the one the last reply came from (2026-10-13).
        if launch.target != .saved || !configuration.resumes(agent) { leftConversation(agent) }
        // A chat over the API loaded its chat at start, or the start failed: only a coding
        // agent's resume is proven by what it says next.
        agents[agent]?.resumeUnproven = session != .fresh && agent.kind == .coding
        guard !launch.held.isEmpty else {
            return ack(Sentences.switched(agent, number: launch.target == .new ? nil : launch.number))
        }
        guard !crashed, journalSent(agent, launch.held), perform(agent, "send", { try $0.send(launch.held) }) else {
            return
        }
        beginTurn(agent)
        agents[agent]?.turn?.ask(launch.held)
        agents[agent]?.phase = .working
        ack(said)
    }

    // MARK: - Starts (maintainer, 2026-10-24)

    /// An instruction to an agent that is off starts it at once, with no yes (the launch prompt
    /// of 2026-10-08 is gone), in the conversation the picker infers from the words: one of its
    /// conversations here, the chat its app shows, or a new one ("infer which conversation to
    /// proceed with or start a new conversation"). The user hears which. Awaited in-line, as a
    /// launch is: every look and the pick are bounded.
    private func startInferred(_ agent: AgentID, held text: String) async {
        deferredPump = true
        guard let found = await pickable(agent) else {
            return await start(agent, Launch(folder: folder, target: .new, held: text),
                               said: Sentences.unreadConversations(agent))
        }
        guard !found.candidates.isEmpty else {
            return await start(agent, Launch(folder: folder, target: .new, held: text),
                               said: found.lastOpen ? Sentences.startingNew(agent, lastOpenElsewhere: true)
                                   : Sentences.okay)
        }
        switch await pick(agent, text, among: found.candidates) {
        case .success(let pick):
            guard let number = pick.number else {
                return await start(agent, Launch(folder: folder, target: .new, held: text),
                                   said: Sentences.startingNew(agent, lastOpenElsewhere: found.lastOpen))
            }
            guard let index = found.candidates.firstIndex(where: { $0.number == number }) else {
                return crash(Subsystem.picker, "picked \(number) of \(found.candidates.count) conversations")
            }
            let name = SpokenText.plain(pick.name).trimmingCharacters(in: .whitespacesAndNewlines)
            await start(agent, Launch(folder: folder, target: found.targets[index], held: text),
                        said: Sentences.continuing(agent, name: name.isEmpty ? nil : name,
                                                   last: found.candidates[index].last))
        case .failure(.contract(let reason)):
            crash(Subsystem.picker, reason)
        case .failure(.callBound):
            // As before 2026-10-24: the conversation it was last in, else a new one; and told so.
            let last = found.candidates.firstIndex(where: \.last)
            await start(agent, Launch(folder: folder, target: last.map { found.targets[$0] } ?? .new, held: text),
                        said: Sentences.pickFailed(agent, continued: last != nil))
        }
    }

    /// What a first instruction to `agent` may carry on, newest first and numbered from 1, with
    /// what starting each takes: its conversations here (the newest few, and the one it was last
    /// in), never one open elsewhere (2026-10-12); or, for a chat in the user's app, the chat its
    /// app shows. `lastOpen`: the one it was last in is open elsewhere, so it is not offered.
    /// nil: its conversations could not be read.
    private func pickable(_ agent: AgentID) async
        -> (candidates: [ConversationCandidate], targets: [LaunchTarget], lastOpen: Bool)? {
        guard configuration.resumes(agent) else {
            // Bounded by the delegate, which only reads.
            guard let title = await live[agent]?.delegate.shownConversation() else { return ([], [], false) }
            return ([ConversationCandidate(number: 1, title: title, age: "", last: true)], [.shown], false)
        }
        guard let catalog = catalogs[agent] else { return ([], [], false) }
        let workspace = configuration.workspace
        let listed = await Self.bounded(configuration.listTimeout) { try await catalog.sessions(in: workspace) }
        guard case .value(let sessions) = listed else {
            let reason: String
            if case .failed(let why) = listed { reason = why } else { reason = "timeout" }
            diagnostics.record("conversations.pickable", level: .warning,
                               fields: ["agent": agent.rawValue, "outcome": reason])
            return nil
        }
        let saved = agents[agent]?.sessionID
        let open = sessions.isEmpty ? [] : Set((await lookOpen(agent) ?? []).map(\.id))
        let free = sessions.filter { !open.contains($0.id) }
        var offered = Array(free.prefix(configuration.conversationsPerReading))
        if let saved, !offered.contains(where: { $0.id == saved }), let last = free.first(where: { $0.id == saved }) {
            offered.append(last)
        }
        let today = now()
        let candidates = offered.enumerated().map { offset, session in
            ConversationCandidate(number: offset + 1, title: session.title,
                                  age: Sentences.age(of: session.updatedAt, now: today, calendar: calendar),
                                  last: session.id == saved)
        }
        return (candidates, offered.map { $0.id == saved ? .saved : .conversation(id: $0.id) },
                saved.map { open.contains($0) } ?? false)
    }

    /// The picker's choice, bounded by `pickTimeout` and logged as a call is.
    private func pick(_ agent: AgentID, _ text: String,
                      among candidates: [ConversationCandidate]) async -> Result<ConversationPick, TextModelError> {
        let model = picker
        let started = monotonicNow()
        let outcome = await Self.bounded(configuration.pickTimeout) { () async -> Result<ConversationPick, TextModelError> in
            do throws(TextModelError) {
                return .success(try await model.pick(text, among: candidates, agent: agent))
            } catch {
                return .failure(error)
            }
        }
        let result: Result<ConversationPick, TextModelError>
        switch outcome {
        case .value(let value): result = value
        case .failed(let reason): result = .failure(.callBound(reason))
        case .timedOut: result = .failure(.callBound("timeout"))
        }
        let ms = Int(((monotonicNow() - started) * 1000).rounded())
        var fields = ["ms": "\(ms)", "outcome": Self.outcome(result), "candidates": "\(candidates.count)"]
        if case .success(let pick) = result { fields["picked"] = pick.number.map { "\($0)" } ?? "new" }
        diagnostics.record("picker.call", fields: fields)
        return result
    }

    /// A start without a yes (2026-10-24), journaled first, so a restart tells its words as lost.
    private func start(_ agent: AgentID, _ launch: Launch, said: String) async {
        guard append(.launching(agent: agent, target: launch.target, held: launch.held)) else { return }
        agents[agent]?.phase = .idle
        if !launch.held.isEmpty { agents[agent]?.openTurn = .launched }
        await self.launch(agent, launch, said: said)
    }

    /// "New conversation" starts one at once (maintainer, 2026-10-24: "when it heard the command
    /// open a new conversation, it just do it"). An agent at work is not switched (the user
    /// stops it first); one asked to switch hears that question again.
    private func startNew(_ text: String, for utterance: Utterance) async {
        let agent = utterance.agent
        guard let state = agents[agent] else { return }
        switch state.phase {
        case .working: return refuse(utterance.itemID, .busy, ack: Sentences.busy(agent))
        case .awaitingYes: return refuse(utterance.itemID, .notHead, reaskFor: agent)
        case .notInstalled: return
        case .none, .idle: break
        }
        await start(agent, Launch(folder: folder, target: .new, held: text, running: state.phase == .idle),
                    said: Sentences.okay)
    }

    // MARK: - Conversations (maintainer, 2026-10-12)

    /// The yes or no that switches `agent` into a conversation the user chose from those TapQ
    /// read, asked and gated like every request: the one start that still asks (2026-10-24). An
    /// agent at work is not switched (the user stops it first); one already waiting on a switch
    /// hears that again.
    private func askSwitch(_ asked: Launch, for utterance: Utterance) async {
        let agent = utterance.agent
        guard let state = agents[agent] else { return }
        switch state.phase {
        case .working: return refuse(utterance.itemID, .busy, ack: Sentences.busy(agent))
        case .awaitingYes: return refuse(utterance.itemID, .notHead, reaskFor: agent)
        case .notInstalled: return
        case .none, .idle: break
        }
        // Never a second process in a conversation one already has open (2026-10-12): it is
        // looked up first. Asked, not guarded at the yes: one opened elsewhere between the two
        // is not caught.
        let session = self.session(agent, for: asked.target)
        if case .resume(let resumed) = session, let open = await lookOpen(agent),
           open.contains(where: { $0.id == resumed }) {
            return refuse(utterance.itemID, .openElsewhere,
                          ack: Sentences.openElsewhere(agent, number: asked.number ?? 0))
        }
        let launch = Launch(folder: asked.folder, target: asked.target, held: asked.held,
                            running: state.phase == .idle, number: asked.number, title: asked.title)
        let id = "launch-\(journal.lastSeq + 1)"
        guard append(.launchAsked(agent: agent, requestID: id, folder: launch.folder, resume: session != .fresh,
                                  held: launch.held, target: launch.target)) else { return }
        agents[agent]?.phase = .awaitingYes
        push(PendingRequest(id: id, kind: .launch(launch),
                            prompt: Sentences.switchConversation(agent, number: launch.number ?? 0,
                                                                  title: launch.title ?? "")),
             to: agent)
    }

    /// What a start opens. A chat in the user's app carries on the chat its app shows, or opens
    /// a new one (2026-10-24): it has no conversation of its own to resume.
    private func session(_ agent: AgentID, for target: LaunchTarget) -> DelegateSession {
        guard configuration.resumes(agent) else {
            // The id is never read: the chat is the one the app shows.
            return target == .shown ? .resume(id: "shown") : .fresh
        }
        switch target {
        case .saved: return agents[agent]?.sessionID.map { .resume(id: $0) } ?? .fresh
        case .conversation(let id): return .resume(id: id)
        case .new, .shown: return .fresh
        }
    }

    /// Only a conversation TapQ read out can be chosen, by the number it was read with. The one
    /// the agent is in needs no switch: any words go to it as they would anyway. A chat in the
    /// user's app has none read, so none can be chosen (2026-10-13).
    private func switchConversation(_ number: Int, then text: String?, for utterance: Utterance) async {
        let agent = utterance.agent
        guard configuration.resumes(agent) else {
            return refuse(utterance.itemID, .noSuchConversation, ack: Sentences.cannotListChats(agent))
        }
        guard let list = conversations[agent], let chosen = list.read.first(where: { $0.number == number }) else {
            let listed = conversations[agent]?.read.isEmpty == false
            return refuse(utterance.itemID, .noSuchConversation,
                          ack: Sentences.noSuchConversation(agent, number: number, listed: listed))
        }
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if chosen.id == agents[agent]?.sessionID {
            if words.isEmpty { return ack(Sentences.alreadyIn(agent, number: number)) }
            // The user chose it: an agent that is off starts in it, with no pick (2026-10-24).
            guard agents[agent]?.phase == .none else { return await instruct(words, for: utterance) }
            return await start(agent, Launch(folder: folder, target: .saved, held: words), said: Sentences.okay)
        }
        await askSwitch(Launch(folder: folder, target: .conversation(id: chosen.id), held: words,
                               number: chosen.number, title: chosen.title),
                        for: utterance)
    }

    /// The first five, newest first, from the agent's own store; or, with `more`, the next five
    /// of the list already read. One listing per agent at a time. A chat in the user's app has
    /// its chats in the app, and they are not read (2026-10-13).
    private func listConversations(_ agent: AgentID, more: Bool) {
        guard configuration.resumes(agent) else { return ack(Sentences.cannotListChats(agent)) }
        guard listCalls[agent] == nil, nameCalls[agent] == nil else {
            return diagnostics.record("conversations.already_listing", fields: ["agent": agent.rawValue])
        }
        if more, let list = conversations[agent], !list.read.isEmpty {
            return list.unread == 0 ? ack(Sentences.allConversationsRead(agent), agent: agent) : nameNext(agent)
        }
        guard let catalog = catalogs[agent] else {
            return ack(Sentences.listFailed(agent, reason: "TapQ has no way to read them"), agent: agent)
        }
        let workspace = configuration.workspace
        listCalls[agent] = call("conversations.list", configuration.listTimeout, { .listed(agent: agent, $0) }) {
            () async throws(TextModelError) in
            do {
                return try await catalog.sessions(in: workspace)
            } catch {
                throw .callBound("\(error)")
            }
        }
    }

    /// The titler names the first five while TapQ looks which are open elsewhere, so the
    /// reading waits on the slower of the two.
    private func listed(_ agent: AgentID, _ result: Result<[SessionSummary], TextModelError>) async {
        guard let open = listCalls.removeValue(forKey: agent) else { return }
        close(open, result)
        switch result {
        case .failure(.callBound(let reason)), .failure(.contract(let reason)):
            ack(Sentences.listFailed(agent, reason: reason == "timeout" ? "it took too long" : reason), agent: agent)
        case .success(let sessions):
            conversations[agent] = ConversationList(sessions: sessions)
            guard !sessions.isEmpty else { return ack(Sentences.noConversations(agent, folder: folder), agent: agent) }
            nameNext(agent)
            await lookOpen(agent)
        }
    }

    /// The next five unread are named by the titler, then read.
    private func nameNext(_ agent: AgentID) {
        guard let list = conversations[agent], list.unread > 0 else { return }
        let first = list.read.count
        let titles = page(of: list, from: first).map { SpokenText.plain($0.title) }
        let model = titler
        let deliver: @Sendable (Result<[String], TextModelError>) -> KernelInput = {
            .named(agent: agent, first: first, $0)
        }
        nameCalls[agent] = (first, call("titler.call", configuration.nameTimeout, deliver) {
            () async throws(TextModelError) in try await model.names(titles, agent: agent)
        })
    }

    private func page(of list: ConversationList, from first: Int) -> ArraySlice<SessionSummary> {
        list.sessions[first..<min(first + configuration.conversationsPerReading, list.sessions.count)]
    }

    /// A name with no words, or a call-bound failure, reads the agent's own title.
    private func named(_ agent: AgentID, _ first: Int, _ result: Result<[String], TextModelError>) {
        guard let open = nameCalls[agent], open.first == first else { return }
        nameCalls[agent] = nil
        close(open.call, result)
        guard var list = conversations[agent], list.read.count == first else { return }
        let sessions = page(of: list, from: first)
        let names: [String]
        switch result {
        case .success(let given):
            guard given.count == sessions.count else {
                return crash(Subsystem.titler, "\(given.count) names for \(sessions.count) conversations")
            }
            names = zip(given, sessions).map { name, session in
                let spoken = SpokenText.plain(name).trimmingCharacters(in: .whitespacesAndNewlines)
                return spoken.isEmpty ? SpokenText.plain(session.title) : spoken
            }
        case .failure(.callBound):
            names = sessions.map { SpokenText.plain($0.title) }
        case .failure(.contract(let reason)):
            return crash(Subsystem.titler, reason)
        }
        let today = now()
        let read = zip(sessions, names).enumerated().map { offset, pair in
            ConversationList.Read(number: first + offset + 1, id: pair.0.id, title: pair.1,
                                  age: Sentences.age(of: pair.0.updatedAt, now: today, calendar: calendar))
        }
        list.read += read
        conversations[agent] = list
        let heard = choices(agent).suffix(read.count)
        let openNumbers = Set(read.filter { isOpenElsewhere($0.id, agent) }.map(\.number))
        ack(Sentences.conversations(agent, folder: folder, read: Array(heard), total: list.sessions.count,
                                    left: list.unread, open: openNumbers),
            agent: agent)
    }

    /// The conversations read for `agent`, as the intent model and the list sentence see them.
    private func choices(_ agent: AgentID) -> [ConversationChoice] {
        let current = agents[agent]?.sessionID
        return conversations[agent]?.read.map {
            ConversationChoice(number: $0.number, title: $0.title, age: $0.age, current: $0.id == current)
        } ?? []
    }

    /// The same, for the status channel. Absent until some were read: a listing still being
    /// named has read none, and writes no line of its own.
    private func conversationsRead(_ agent: AgentID) -> StatusReport.Conversations? {
        guard let list = conversations[agent], !list.read.isEmpty else { return nil }
        return StatusReport.Conversations(
            read: zip(list.read, choices(agent)).map { read, choice in
                StatusReport.Conversations.Conversation(number: choice.number, title: choice.title, age: choice.age,
                                                        current: choice.current,
                                                        openElsewhere: isOpenElsewhere(read.id, agent) ? true : nil)
            },
            more: list.unread)
    }

    /// As TapQ last looked; never the conversation TapQ's own process is in.
    private func isOpenElsewhere(_ id: String, _ agent: AgentID) -> Bool {
        openElsewhere[agent]?.contains(id) == true && !(runs(agent) && agents[agent]?.sessionID == id)
    }

    /// TapQ's own process for `agent` is up: idle, at work, or asked to switch while it runs.
    private func runs(_ agent: AgentID) -> Bool {
        guard let state = agents[agent] else { return false }
        switch state.phase {
        case .idle, .working: return true
        case .awaitingYes:
            if case .launch(let launch)? = state.head?.kind { return launch.running }
            return true
        case .none, .notInstalled: return false
        }
    }

    /// Which of `agent`'s conversations here a process other than TapQ's has open now, as the
    /// agent reports it (2026-10-12). Awaited in-line, as a launch is, and bounded by
    /// `openTimeout`; nil when the agent cannot tell, and TapQ goes on as before. TapQ's own
    /// process is listed too, under the session it is in, and is left out here. The answer is
    /// kept for the reading and the status channel. A chat in the user's app is open there by
    /// nature: never looked up (2026-10-13).
    @discardableResult
    private func lookOpen(_ agent: AgentID) async -> [OpenSession]? {
        guard configuration.resumes(agent), let catalog = catalogs[agent] else { return nil }
        deferredPump = true
        let workspace = configuration.workspace
        let started = monotonicNow()
        let outcome = await Self.bounded(configuration.openTimeout) {
            try await catalog.openSessions(in: workspace)
        }
        let ms = Int(((monotonicNow() - started) * 1000).rounded())
        guard case .value(let sessions) = outcome else {
            openElsewhere[agent] = nil
            let reason: String
            if case .failed(let why) = outcome { reason = why } else { reason = "timeout" }
            diagnostics.record("conversations.open", level: .warning,
                               fields: ["agent": agent.rawValue, "ms": "\(ms)", "outcome": reason])
            return nil
        }
        let own = runs(agent) ? agents[agent]?.sessionID : nil
        let elsewhere = sessions.filter { $0.id != own }
        openElsewhere[agent] = Set(elsewhere.map(\.id))
        diagnostics.record("conversations.open", fields: ["agent": agent.rawValue, "ms": "\(ms)", "outcome": "ok",
                                                          "open": "\(elsewhere.count)"])
        return elsewhere
    }

    private enum Bounded<Value: Sendable>: Sendable {
        case value(Value), failed(String), timedOut
    }

    /// `operation`'s answer, or how it failed; past `timeout`, `.timedOut`. The two race as a
    /// call's do (`call`), so an operation that ignores its cancellation never holds the loop.
    private static func bounded<Value: Sendable>(_ timeout: Duration,
                                                 _ operation: @escaping @Sendable () async throws -> Value) async -> Bounded<Value> {
        let (outcomes, racer) = AsyncStream<Bounded<Value>>.makeStream()
        let worker = Task {
            do { racer.yield(.value(try await operation())) } catch { racer.yield(.failed("\(error)")) }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            racer.yield(.timedOut)
        }
        var first = outcomes.makeAsyncIterator()
        let outcome = await first.next() ?? .timedOut
        racer.finish()
        worker.cancel()
        timer.cancel()
        return outcome
    }

    /// The old conversation's process began work while TapQ asked to switch it: the switch is
    /// withdrawn, since that conversation is live again, and the user hears so.
    private func workBegan(_ agent: AgentID) {
        guard let head = agents[agent]?.head, case .launch(let launch) = head.kind, launch.running else { return }
        guard append(.withdrawn(agent: agent, requestID: head.id)) else { return }
        agents[agent]?.pending.removeFirst()
        agents[agent]?.phase = .idle
        queue.removePrompt(of: agent)
        queue.enqueue(Sentences.switchWithdrawn(agent), band: .request, agent: agent)
    }

    /// Started in another conversation: the last reply, and what TapQ last read of it, were the
    /// old one's. The restart fold does the same at a `started` with another id.
    private func leftConversation(_ agent: AgentID) {
        agents[agent]?.heldReply = nil
        summaryCalls.removeValue(forKey: agent)?.call.cancel()
        lastSaid[agent] = nil
    }

    // MARK: - Requests

    private func push(_ request: PendingRequest, to agent: AgentID) {
        agents[agent]?.pending.append(request)
        if agents[agent]?.pending.count == 1 { offerHead(agent) }
    }

    /// Queues `agent`'s head prompt, unless the head still waits for its description, whose
    /// arrival queues it. Every place that makes a head goes through here.
    private func offerHead(_ agent: AgentID, first: Bool = false) {
        guard let head = agents[agent]?.head, !head.describing else { return }
        queue.enqueuePrompt(head.prompt, agent: agent, requestID: head.id, first: first)
    }

    /// Journals the resolution, delivers it, and lets the next request be asked.
    private func settle(_ agent: AgentID, _ request: PendingRequest, _ resolution: Resolution) -> Bool {
        guard append(.resolved(agent: agent, requestID: request.id, decision: resolution)) else {
            return false
        }
        switch resolution {
        case .launch(let yes):
            guard case .launch(let launch) = request.kind else { break }
            agents[agent]?.phase = yes || launch.running ? .idle : .none
            if yes, !launch.held.isEmpty { agents[agent]?.openTurn = .launched }
        case .permission(let decision):
            guard perform(agent, "resolve", { try $0.resolve(permission: request.id, decision) }) else {
                return false
            }
            if case .allow = decision, case .permission(let asked) = request.kind, let step = asked.step {
                agents[agent]?.turn?.resume(step)
            }
        case .answers(let answers):
            guard perform(agent, "resolve", { try $0.resolve(question: request.id, answers: answers) }) else {
                return false
            }
        }
        agents[agent]?.pending.removeFirst()
        queue.removePrompt(of: agent)
        offerHead(agent)
        return true
    }

    /// "I'll ask again." and the head's prompt as a new reading; the gate stays closed until
    /// that reading plays.
    private func reask(_ agent: AgentID) {
        guard var head = agents[agent]?.head else { return }
        head.promptID = nil
        head.promptPlayedAt = nil
        agents[agent]?.pending[0] = head
        ack(Sentences.reask)
        offerHead(agent, first: true)
    }

    private func refuse(_ item: String, _ reason: RefusalReason, ack text: String) {
        if append(.refused(itemID: item, reason: reason)) { ack(text) }
    }

    private func refuse(_ item: String, _ reason: RefusalReason, reaskFor agent: AgentID) {
        if append(.refused(itemID: item, reason: reason)) { reask(agent) }
    }

    /// The lead's paraphrase ruling (§4.4): a request read non-verbatim twice is refused out
    /// loud, so nothing the user did not hear verbatim is ever approved. The refusal is
    /// journaled under the request id; there is no utterance to carry it.
    private func refuseUnreadable(_ agent: AgentID, _ request: PendingRequest) {
        guard append(.refused(itemID: request.id, reason: .unreadable)) else { return }
        let resolution: Resolution
        switch request.kind {
        case .launch:
            resolution = .launch(yes: false)
        case .permission:
            resolution = .permission(.deny(feedback: Sentences.unreadableFeedback))
        case .question(let question):
            resolution = .answers(question.questions.map { _ in [Sentences.unreadableFeedback] })
        }
        if settle(agent, request, resolution) { ack(Sentences.unreadable(agent)) }
    }

    // MARK: - Delegate events

    private func received(_ event: DelegateEvent, from agent: AgentID) {
        switch event {
        case .progress, .said, .permission, .question, .finished, .stopped:
            agents[agent]?.resumeUnproven = false
            workBegan(agent)
        case .stepEnded:
            // For status only, and no proof of a live turn: a command can end after the turn
            // it ran in (Codex's background terminal, Claude Code's background tasks).
            break
        case .failed:
            // A failed turn is no proof the resumed conversation is there: it may be why.
            workBegan(agent)
        case .withdrawn, .notice:
            agents[agent]?.resumeUnproven = false
        case .exited, .violation:
            break
        }
        switch event {
        case .progress(let line, let step):
            agents[agent]?.progress = line
            agents[agent]?.progressStep = step
            noteTurn(agent)
            agents[agent]?.turn?.step(line, id: step)
            if agents[agent]?.phase == .idle { agents[agent]?.phase = .working }
        case .stepEnded(let step, let outcome):
            // The status channel's tool line stays the last one started; its state moves on.
            agents[agent]?.turn?.end(step, outcome)
        case .said(let text):
            noteTurn(agent)
            agents[agent]?.turn?.say(text)
            if agents[agent]?.phase == .idle { agents[agent]?.phase = .working }
        case .permission(let request):
            // A shell command is described before it is asked (ruling 2026-10-12); until then
            // its prompt is the command read whole, which is also what a failed call leaves.
            let pending = PendingRequest(id: request.id, kind: .permission(request),
                                         prompt: Sentences.permission(agent, request),
                                         describing: request.command != nil)
            if let step = request.step { agents[agent]?.turn?.wait(step) }
            if accept(pending, journaled: .permission(agent: agent, request), from: agent), pending.describing {
                describe(request, for: agent)
            }
        case .question(let request):
            guard !request.questions.isEmpty else {
                return agentFailed(agent, .lostTrack, "a question request with no questions")
            }
            accept(PendingRequest(id: request.id, kind: .question(request),
                                  prompt: Sentences.question(agent, request)),
                   journaled: .question(agent: agent, request), from: agent)
        case .withdrawn(let id):
            withdraw(id, from: agent)
        case .finished(let text):
            guard turnMayEnd(agent), let record = record(.finished(agent: agent, text: text)) else { return }
            endTurn(agent)
            agents[agent]?.heldReply = HeldReply(seq: record.seq, text: text)
            summaryCalls.removeValue(forKey: agent)?.call.cancel()
            // Measured as it would be spoken; a reply that marks a name (code, a link) is
            // summarized whatever its length, so the name is described, not read (2026-10-16).
            if SpokenText.plain(text).count > configuration.summaryThreshold || SpokenText.marksNames(text) {
                summarize(text, from: agent, finishedSeq: record.seq)
            } else {
                queue.enqueue(Sentences.finished(agent, text), band: .result, agent: agent)
            }
        case .stopped:
            guard turnMayEnd(agent), append(.stopped(agent: agent)) else { return }
            endTurn(agent)
            queue.enqueue(Sentences.stopped(agent), band: .result, agent: agent)
        case .failed(let reason):
            guard turnMayEnd(agent), append(.failed(agent: agent, reason: reason)) else { return }
            let resumed = agents[agent]?.resumeUnproven == true
            agents[agent]?.resumeUnproven = false
            endTurn(agent)
            queue.enqueue(Sentences.failed(agent, reason: reason, resumed: resumed), band: .result, agent: agent)
        case .notice(let sentence):
            queue.enqueue(sentence, band: .result, agent: agent)
        case .exited(let code, let stderrTail):
            agentFailed(agent, .exited, "exited with code \(code)", ["stderr": stderrTail.joined(separator: " | ")])
        case .violation(let detail):
            agentFailed(agent, .lostTrack, detail)
        }
    }

    /// A new request joins the agent's FIFO. One in `idle` moves the agent to working:
    /// Codex can ask during `turn/start`.
    @discardableResult
    private func accept(_ request: PendingRequest, journaled entry: JournalEntry, from agent: AgentID) -> Bool {
        if agents[agent]?.pending.contains(where: { $0.id == request.id }) == true {
            agentFailed(agent, .lostTrack, "request \(request.id) asked twice")
            return false
        }
        guard append(entry) else { return false }
        if agents[agent]?.phase == .idle { agents[agent]?.phase = .working }
        push(request, to: agent)
        return true
    }

    /// The delegate contract withdraws every open request before a turn's terminal event,
    /// so a turn that ends with one open is a violation, and that agent is stopped.
    private func turnMayEnd(_ agent: AgentID) -> Bool {
        if agents[agent]?.pending.isEmpty == false {
            agentFailed(agent, .lostTrack, "the turn ended with requests open")
            return false
        }
        return true
    }

    /// Also from idle: a delegate may run a turn TapQ did not start (Codex sends a deny's
    /// feedback as a steer, which becomes `turn/start` once the turn has ended).
    private func endTurn(_ agent: AgentID) {
        agents[agent]?.phase = .idle
        agents[agent]?.progress = nil
        agents[agent]?.openTurn = nil
        let steers = Array(agents[agent]?.turn?.asked.dropFirst() ?? [])
        agents[agent]?.carriedAsks = steers
        forgetTurn(agent)
    }

    // MARK: - Agent failure

    /// One agent failed; TapQ and the other agent go on (maintainer ruling 2026-10-12). What
    /// was in flight is journaled lost, as a restart would (§4.9), so a later restart says
    /// nothing more about it. The agent is off with its session kept: the next instruction
    /// starts it again, on a fresh delegate, where the picker infers. The old one is stopped
    /// (D13) meanwhile.
    private func agentFailed(_ agent: AgentID, _ failure: AgentFailure, _ reason: String,
                             _ context: [String: String] = [:], resumed: Bool = false) {
        guard !crashed, !stopping, let state = agents[agent] else { return }
        var fields = context
        fields["agent"] = agent.rawValue
        fields["reason"] = reason
        diagnostics.record("delegate.failed", level: .error, fields: fields)
        if state.openTurn != nil {
            guard append(.lost(agent: agent, .turn)) else { return }
        }
        for request in state.pending {
            guard append(.lost(agent: agent, .request(id: request.id))) else { return }
            describeCalls.removeValue(forKey: describeKey(agent, request.id))?.cancel()
        }
        queue.removePrompt(of: agent)
        agents[agent]?.pending = []
        agents[agent]?.phase = .none
        agents[agent]?.progress = nil
        agents[agent]?.openTurn = nil
        forgetTurn(agent)
        agents[agent]?.carriedAsks = []
        retire(agent)
        agents[agent]?.resumeUnproven = false
        let lostWork = state.openTurn == .delivered || !state.pending.isEmpty
        let requests = state.pending.filter { if case .launch = $0.kind { return false } else { return true } }
        let sentence = Sentences.agentFailed(agent, failure, openRequests: lostWork ? requests.count : nil,
                                             taskDelivered: state.openTurn == .delivered,
                                             resumed: resumed || state.resumeUnproven,
                                             chats: configuration.backend(agent))
        agents[agent]?.failure = StatusReport.Failure(kind: failure.kind, sentence: sentence)
        queue.enqueue(sentence, band: .result, agent: agent)
    }

    /// The agent gets a fresh delegate; the old one is stopped in the background, after any
    /// earlier one still stopping.
    private func retire(_ agent: AgentID) {
        guard let old = live[agent], let make = makeDelegate[agent] else { return }
        follow(agent, make(), generation: old.generation + 1)
        let previous = retiring[agent]
        retiring[agent] = Task {
            await previous?.value
            await old.delegate.stop()
        }
    }

    private func withdraw(_ id: String, from agent: AgentID) {
        guard let index = agents[agent]?.pending.firstIndex(where: { $0.id == id }) else {
            // Answered by TapQ while the delegate was cancelling it: nothing is open.
            diagnostics.record("delegate.withdrawn_unknown", level: .warning,
                               fields: ["agent": agent.rawValue, "request": id])
            return
        }
        guard append(.withdrawn(agent: agent, requestID: id)),
              let request = agents[agent]?.pending.remove(at: index) else { return }
        describeCalls.removeValue(forKey: describeKey(agent, id))?.cancel()
        // Its step no longer waits on the user: the agent may run it (a hook of the user's
        // allowed it) or end it, which its result says.
        if case .permission(let asked) = request.kind, let step = asked.step { agents[agent]?.turn?.resume(step) }
        guard index == 0 else { return }
        queue.removePrompt(of: agent)
        if request.spoken { queue.enqueue(Sentences.withdrew(agent), band: .request, agent: agent) }
        offerHead(agent)
    }

    // MARK: - Summaries

    private func summarize(_ text: String, from agent: AgentID, finishedSeq: Int) {
        let model = summarizer
        let deliver: @Sendable (Result<String, TextModelError>) -> KernelInput = {
            .summarized(agent: agent, finishedSeq: finishedSeq, $0)
        }
        summaryCalls[agent] = (finishedSeq, call("summarizer.call", configuration.summaryTimeout, deliver) {
            () async throws(TextModelError) in try await model.summarize(text, agent: agent)
        })
    }

    /// Relayed only for the reply still held: a newer `finished` supersedes it (§4.6).
    private func summarized(_ agent: AgentID, _ finishedSeq: Int, _ result: Result<String, TextModelError>) {
        guard let open = summaryCalls[agent], open.finishedSeq == finishedSeq else { return }
        summaryCalls[agent] = nil
        close(open.call, result)
        switch result {
        case .success(let summary) where SpokenText.plain(summary).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // No words once plain: told out loud, as any call that gave nothing (2026-10-16).
            queue.enqueue(Sentences.summaryFailed(agent), band: .result, agent: agent)
        case .success(let summary):
            guard append(.summarized(agent: agent, finishedSeq: finishedSeq, summary: summary)) else {
                return
            }
            queue.enqueue(Sentences.summary(agent, summary), band: .result, agent: agent)
        case .failure(.callBound):
            queue.enqueue(Sentences.summaryFailed(agent), band: .result, agent: agent)
        case .failure(.contract(let reason)):
            crash(Subsystem.summarizer, reason)
        }
    }

    // MARK: - Progress (2026-10-15)

    /// A new turn's record: the one before it, if any, is gone with its status call. A turn
    /// TapQ starts (`carrying` false) drops the steers the last turn left.
    private func beginTurn(_ agent: AgentID, carrying: Bool = false) {
        forgetTurn(agent)
        agents[agent]?.turnNumber += 1
        let carried = carrying ? agents[agent]?.carriedAsks ?? [] : []
        agents[agent]?.turn = TurnSoFar(asked: carried)
        agents[agent]?.carriedAsks = []
    }

    /// The turn under way; one TapQ did not start (a steer Codex turned into a new turn, a turn
    /// Claude Code starts on its own) gets a record at its first event, asked what the last
    /// turn's steers asked: a steer that crossed that turn's end runs as this one.
    private func noteTurn(_ agent: AgentID) {
        if agents[agent]?.turn == nil { beginTurn(agent, carrying: true) }
    }

    private func forgetTurn(_ agent: AgentID) {
        agents[agent]?.turn = nil
        progressCalls.removeValue(forKey: agent)?.call.cancel()
    }

    /// One summary at a time per agent: a second status while one is on its way is answered
    /// by that one.
    private func summarizeProgress(_ turn: TurnSoFar, of agent: AgentID) {
        guard progressCalls[agent] == nil, let number = agents[agent]?.turnNumber else { return }
        // Counts only: what the summarizer was told of each step's state, never the steps.
        let states = turn.steps.map { $0.state?.rawValue ?? "unknown" }
        diagnostics.record("progress.steps", fields: Dictionary(states.map { ($0, 1) }, uniquingKeysWith: +)
            .mapValues { "\($0)" }.merging(["agent": agent.rawValue]) { $1 })
        let model = progressSummarizer
        let deliver: @Sendable (Result<String, TextModelError>) -> KernelInput = {
            .progressed(agent: agent, turn: number, $0)
        }
        progressCalls[agent] = (number, call("progress.call", configuration.progressTimeout, deliver) {
            () async throws(TextModelError) in try await model.summarize(turn, agent: agent)
        })
    }

    /// Said only while that turn is still under way: once it has ended, its reply or its end is
    /// what the user hears next, and the summary is dropped. A failed or wordless summary is
    /// told as one (2026-10-16).
    private func progressed(_ agent: AgentID, _ turn: Int, _ result: Result<String, TextModelError>) {
        guard let open = progressCalls[agent], open.turn == turn else { return }
        progressCalls[agent] = nil
        close(open.call, result)
        guard let state = agents[agent], state.phase == .working, state.turnNumber == turn else { return }
        switch result {
        case .success(let summary):
            ack(Sentences.progress(agent, summary, state) ?? Sentences.progressFailed(agent, state))
        case .failure(.callBound):
            ack(Sentences.progressFailed(agent, state))
        case .failure(.contract(let reason)):
            crash(Subsystem.progress, reason)
        }
    }

    // MARK: - Command descriptions

    private func describeKey(_ agent: AgentID, _ requestID: String) -> String {
        "\(agent.rawValue) \(requestID)"
    }

    private func describe(_ request: PermissionRequest, for agent: AgentID) {
        guard let command = request.command else { return }
        let model = describer
        let workspace = configuration.workspacePaths
        let id = request.id
        let deliver: @Sendable (Result<String, TextModelError>) -> KernelInput = {
            .described(agent: agent, requestID: id, $0)
        }
        describeCalls[describeKey(agent, id)] = call("describer.call", configuration.describeTimeout, deliver) {
            () async throws(TextModelError) in try await model.describe(command, agent: agent, workspacePaths: workspace)
        }
    }

    /// The request is asked with its description; on a call-bound failure, or words that say
    /// nothing, with the command itself. A request withdrawn or answered meanwhile is gone.
    private func described(_ agent: AgentID, _ id: String, _ result: Result<String, TextModelError>) {
        guard let open = describeCalls.removeValue(forKey: describeKey(agent, id)) else { return }
        close(open, result)
        guard let index = agents[agent]?.pending.firstIndex(where: { $0.id == id }),
              case .permission(let request)? = agents[agent]?.pending[index].kind else { return }
        switch result {
        case .success(let phrase):
            if let prompt = Sentences.permission(agent, request, described: phrase) {
                agents[agent]?.pending[index].prompt = prompt
            } else {
                diagnostics.record("describer.empty", level: .warning, fields: ["agent": agent.rawValue])
            }
        case .failure(.callBound):
            break
        case .failure(.contract(let reason)):
            return crash(Subsystem.describer, reason)
        }
        agents[agent]?.pending[index].describing = false
        if index == 0 { offerHead(agent) }
    }

    private func call<Value: Sendable>(
        _ name: String, _ bound: Duration,
        _ deliver: @escaping @Sendable (Result<Value, TextModelError>) -> KernelInput,
        _ work: @escaping @Sendable () async throws(TextModelError) -> Value
    ) -> Call {
        let inbox = self.inbox
        let worker = Task {
            let result: Result<Value, TextModelError>
            do throws(TextModelError) {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            inbox?.yield(.input(deliver(result)))
        }
        let timer = Task {
            try? await Task.sleep(for: bound)
            guard !Task.isCancelled else { return }
            inbox?.yield(.input(deliver(.failure(.callBound("timeout")))))
        }
        return Call(name: name, tasks: [worker, timer], startedAt: monotonicNow())
    }

    /// Ends an open call: cancels whichever racer is left and logs the outcome.
    private func close<Value>(_ call: Call, _ result: Result<Value, TextModelError>) {
        call.cancel()
        let ms = Int(((monotonicNow() - call.startedAt) * 1000).rounded())
        diagnostics.record(call.name, fields: ["ms": "\(ms)", "outcome": Self.outcome(result)])
    }

    /// A call's outcome as its diagnostic logs it.
    private static func outcome<Value>(_ result: Result<Value, TextModelError>) -> String {
        switch result {
        case .success: return "ok"
        case .failure(.callBound(let reason)): return "callBound: \(reason)"
        case .failure(.contract(let reason)): return "contract: \(reason)"
        }
    }

    // MARK: - Speech output

    private func ack(_ text: String, agent: AgentID? = nil) {
        queue.enqueue(text, band: .ack, agent: agent)
    }

    /// Starts the next item when nothing is playing and the user is not speaking
    /// (invariant 7). Runs at the end of a tick, never inside a handler that awaited.
    private func pump() {
        guard !crashed, !stopping, speaking == nil, userSpeaking.isEmpty else { return }
        while let item = queue.next() {
            if let prompt = item.prompt, agents[prompt.agent]?.head?.id != prompt.requestID { continue }
            let id = SpeechID(raw: lastSpeechID + 1)
            guard append(.spoke(id: id, text: item.text)) else { return }
            lastSpeechID = id.raw
            if let prompt = item.prompt {
                agents[prompt.agent]?.pending[0].promptID = id
                agents[prompt.agent]?.pending[0].spoken = true
            }
            speaking = (id, item)
            if let agent = item.agent {
                heardFromLast = agent
                // The reply as heard; a read-all re-reads it whole, and is no newer reply.
                if item.band == .result { lastSaid[agent] = item.text }
            }
            output.speak(item.text, id: id)
            return
        }
    }

    private func played(_ event: SpeechOutputEvent) {
        switch event {
        case .started:
            break
        case .played(let id, let at, let verbatim):
            guard let current = speaking, current.id == id else {
                return crash(Subsystem.speechOutput, "played speech \(id.raw), which is not playing")
            }
            speaking = nil
            if let prompt = current.item.prompt {
                promptPlayed(prompt, id: id, at: at, verbatim: verbatim)
            } else if !verbatim {
                diagnostics.record("tts.paraphrase",
                                   fields: ["id": "\(id.raw)", "kind": current.item.band.rawValue])
            }
        case .failed(let id, let reason):
            crash(Subsystem.speechOutput, reason, ["speech": "\(id.raw)"])
        }
    }

    /// Gate condition (b) opens only on a verbatim reading. A paraphrase is re-asked once,
    /// and a second one refuses the request out loud (§4.4).
    private func promptPlayed(_ prompt: SpeechQueue.Prompt, id: SpeechID, at: TimeInterval,
                              verbatim: Bool) {
        let agent = prompt.agent
        // Withdrawn, resolved or re-asked while it played: this reading no longer counts.
        guard var head = agents[agent]?.head, head.id == prompt.requestID, head.promptID == id else {
            return
        }
        if verbatim {
            agents[agent]?.pending[0].promptPlayedAt = at
            return
        }
        diagnostics.record("tts.paraphrase", fields: ["id": "\(id.raw)", "kind": "request"])
        head.misreadings += 1
        agents[agent]?.pending[0] = head
        if head.misreadings == 1 {
            reask(agent)
        } else {
            refuseUnreadable(agent, head)
        }
    }

    // MARK: - Status, journal, fatal

    /// One status line per change of any field (§8). `ready` once, when input is open.
    private func publish(ready: Bool = false) {
        var report = StatusReport(
            type: "status", speaking: speaking != nil, userSpeaking: !userSpeaking.isEmpty,
            agents: configuration.roster.compactMap { agent in
                agents[agent].map { state in
                    StatusReport.Agent(agent: agent, phase: state.phase, progress: state.progress,
                                       progressState: state.progressState,
                                       heldReply: state.heldReply != nil,
                                       pending: state.pending.map(\.status),
                                       failure: state.failure, conversations: conversationsRead(agent),
                                       reply: state.heldReply?.text)
                }
            },
            lastHeard: lastHeard)
        guard ready || report != lastReport else { return }
        lastReport = report
        if ready { report.type = "ready" }
        status(report)
    }

    private func record(_ entry: JournalEntry) -> JournalRecord? {
        do {
            return try journal.append(entry)
        } catch {
            crash(Subsystem.journal, "append failed: \(error)", ["entry": entry.name])
            return nil
        }
    }

    private func append(_ entry: JournalEntry) -> Bool {
        record(entry) != nil
    }

    /// A delegate call; a throw fails that agent, and the caller stops.
    private func perform(_ agent: AgentID, _ action: String, _ body: (any Delegate) throws -> Void) -> Bool {
        guard let delegate = live[agent]?.delegate else { return false }
        do {
            try body(delegate)
            return true
        } catch {
            agentFailed(agent, .lostTrack, "\(action) failed: \(error)")
            return false
        }
    }

    /// Journals words sent to the agent, which delivers its turn (§4.9).
    private func journalSent(_ agent: AgentID, _ text: String) -> Bool {
        guard append(.sent(agent: agent, text: text)) else { return false }
        agents[agent]?.openTurn = .delivered
        return true
    }

    /// Exactly once (invariant 8). The loop stops at the next tick boundary.
    private func crash(_ subsystem: String, _ reason: String, _ context: [String: String] = [:]) {
        guard !crashed else { return }
        crashed = true
        fatal.crash(FatalReason(subsystem: subsystem, reason: reason, context: context))
        inbox?.finish()
    }
}

private extension PendingRequest {
    var status: StatusReport.Pending {
        var request: PermissionRequest?
        if case .permission(let permission) = kind { request = permission }
        return StatusReport.Pending(id: id, kind: summary.kind, prompt: prompt, inputJSON: request?.inputJSON,
                                    command: request?.command, played: promptPlayedAt != nil,
                                    describing: describing)
    }
}
