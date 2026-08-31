import Foundation
import TapQContracts

/// Where a provider gets the wearer's intent from.
///
/// Two sources, and they are mutually exclusive by construction rather than by policy: a
/// provider reads one of them and never consults the other, so there is no composition in
/// which a tool-driven session can also be resolved by a word appearing in a transcript.
///
/// That exclusivity is the whole of the 2026-08-28 decision. The grammar is not "a fallback
/// for when the model is unsure" — the model being unsure is a *safe state*, and a fallback
/// that fired on ambiguity would be the guessing the decision removed, reintroduced at
/// exactly the moment it does the most damage.
public enum VoiceIntentSource: Sendable, Equatable {
    /// Transcripts are matched against a deterministic keyword grammar. The Apple path: it
    /// has no model to reason with, so words are all it has.
    case transcriptGrammar
    /// The backend's own model resolves intent and reports it as a tool call. Transcripts
    /// become logging and nothing else.
    case modelToolCalls
}

/// The actions TapQ is willing to have a model-backed backend ask for, and the rules for
/// turning one of those requests into something that happens.
///
/// ## Why these five and no more
///
/// Each one is an intent some window already consumes. Nothing here is new authority: a
/// tool call resolves exactly what a nod, a tap, or a spoken word resolved before it, and
/// the window machinery on the other side cannot tell which channel it came from. What
/// changes is only the recognizer→intent step.
///
/// ## What is deliberately absent
///
/// There is no tool that ends the voice session, stops listening, or shuts the runtime
/// down, and the absence is the mechanism rather than an omission to be fixed later. On
/// 2026-08-28 a fragment of ordinary dictation matched the word "no" and ended a live
/// session mid-test; the answer was not a better negation rule but removing the wearer's
/// voice from the set of things that can end the channel at all. A session ends when its
/// budget expires, when a gesture or a tap resolves it, or when the runtime stops. See
/// `docs/REALTIME_INTENT_PLAN.md`.
///
/// There is also no tool for "skip", "next", "previous", "details", or "repeat". Those are
/// still reachable — the model can speak an answer to a question, and the window's own
/// deadline still defers to the screen — but every one of them either resolves nothing or
/// resolves toward the screen, and a tool call is an expensive way to say something the
/// model can simply say.
public enum VoiceIntentTools {
    public static let approve = "approve"
    public static let deny = "deny"
    public static let selectItem = "select_item"
    public static let queueInstruction = "queue_instruction"
    public static let queryStatus = "query_status"
    /// The sixth, and the only conditional one: declared only where a `TranscriptStore`
    /// exists to answer from. See ``declarations(includingAskAboutWork:includingStartTask:)``.
    public static let askAboutWork = "ask_about_work"
    /// The seventh, and the deliberation tier's only door. Declared only where a
    /// `WearerTaskStarting` is composed — see
    /// ``declarations(includingAskAboutWork:includingStartTask:)``.
    public static let startTask = "start_task"

    /// The two questions `query_status` can be asked, matching the two informational intents
    /// the windows already answer. A closed set on the wire, so a third kind is refused by
    /// the service rather than arriving here as a string nothing handles.
    public static let statusKindWaiting = "waiting"
    public static let statusKindChanged = "changed"

    /// The declarations, in the order they are sent.
    ///
    /// Every description is written for a model that has the session's grounding and nothing
    /// else, and every one of them says what the tool is *not* for. That is not padding:
    /// the failure this path exists to prevent is a tool fired on a word rather than on a
    /// request, and the description is the only place that distinction can be made.
    public static let declarations: [VoiceToolDeclaration] = [
        VoiceToolDeclaration(
            name: approve,
            description: """
                The wearer is authorizing the request they were just read. Call this only \
                when they have clearly agreed to it. Do not call it because they said a word \
                like "yes" or "okay" inside a longer sentence that was not an answer, and do \
                not call it when no request was read to them.
                """
        ),
        VoiceToolDeclaration(
            name: deny,
            description: """
                The wearer is refusing the request they were just read. Call this only when \
                they have clearly refused it. Words like "no", "stop", or "don't" occur \
                constantly in ordinary speech and in dictation, and hearing one is not a \
                refusal. This never ends the voice session or stops TapQ listening — there is \
                no tool for that, and the wearer cannot end the session by speaking.
                """
        ),
        VoiceToolDeclaration(
            name: selectItem,
            description: """
                The wearer is choosing one entry from the numbered list TapQ just read out. \
                Call this only when a list was read and they named or described one of its \
                entries unambiguously.
                """,
            parameters: [
                VoiceToolParameter(
                    name: "index",
                    kind: .integer,
                    description: """
                        The entry's position in the list TapQ read, counting from 1. Use the \
                        numbering in the read-back, not your own.
                        """
                ),
            ]
        ),
        VoiceToolDeclaration(
            name: queueInstruction,
            description: """
                The wearer is dictating something to be sent to a coding agent rather than \
                answering a question. Pass their sentence through as they said it — do not \
                summarize, translate, or tidy it. TapQ queues it and says out loud what it \
                queued and for whom, so the wearer hears a slightly wrong capture and can say \
                it again; a rewritten one they cannot recognize is not recoverable. This sends \
                one sentence and does nothing else, so a request TapQ would first have to find \
                something out to carry out — what another agent just did, what a run produced \
                — is not this tool.
                """,
            parameters: [
                VoiceToolParameter(
                    name: "text",
                    kind: .string,
                    description: """
                        The instruction in the wearer's own words, with any "tell <agent> to" \
                        opening removed — the agent goes in the separate argument.
                        """
                ),
                VoiceToolParameter(
                    name: "agent",
                    kind: .string,
                    description: """
                        The agent's name exactly as the wearer said it, when they addressed \
                        one. Omit this when they did not name an agent; never guess one, and \
                        never substitute an agent that happens to be live.
                        """,
                    required: false
                ),
            ]
        ),
        VoiceToolDeclaration(
            name: queryStatus,
            description: """
                The wearer is asking about state rather than answering anything: which agents \
                are waiting, or what has already been decided in this session. This resolves \
                nothing — whatever they were asked is still on the table afterwards. It \
                answers from what TapQ itself has done, not from the agent's work, so a \
                question about what an agent did, said, ran, or found is not this tool.
                """,
            parameters: [
                VoiceToolParameter(
                    name: "kind",
                    kind: .string,
                    description: """
                        "waiting" for who or what is waiting on the wearer right now; \
                        "changed" for what this session has already done or decided.
                        """,
                    allowedValues: [statusKindWaiting, statusKindChanged]
                ),
            ]
        ),
    ]

    /// The transcript tool (`docs/TRANSCRIPT_CONTEXT_PLAN.md`), declared only where there is
    /// a transcript to read.
    ///
    /// Its description carries the whole of the routing decision between it and
    /// `query_status`, because a description is the only place that distinction can be
    /// drawn: both are questions, both resolve nothing, and the difference is whose history
    /// answers them — TapQ's own record of what it has been asked and told, or the agent's
    /// session.
    public static let askAboutWorkDeclaration = VoiceToolDeclaration(
        name: askAboutWork,
        description: """
            The wearer is asking about the work an agent has been doing: what it ran, what \
            a command printed, what it changed, what it found, what it decided, or what it \
            said earlier. TapQ reads that agent's session history and answers out loud. Use \
            this for anything whose answer is inside the agent's own session, and use \
            query_status instead for what is waiting on the wearer right now or what TapQ \
            has already decided. This resolves nothing: whatever the wearer was asked is \
            still on the table afterwards, and asking never approves anything. It only \
            reads and answers, so a request to go and *do* something with what is found — \
            run it, pass it on, watch for it — is not this tool, however much history TapQ \
            would have to read to carry it out.
            """,
        parameters: [
            VoiceToolParameter(
                name: "question",
                kind: .string,
                description: """
                    The wearer's question, in their own words. Pass it through as they asked \
                    it — do not narrow it to keywords and do not answer it yourself.
                    """
            ),
            VoiceToolParameter(
                name: "agent",
                kind: .string,
                description: """
                    The agent's name exactly as the wearer said it, when they named one. \
                    Omit this when they did not; never guess.
                    """,
                required: false
            ),
        ]
    )

    /// The deliberation tier's entry point (`docs/TAPQ_AGENT_PLAN.md`, Pillar C, milestone
    /// M2), declared only where a loop exists to hand a goal to.
    ///
    /// Everything above it is the reflex tier and stays exactly as fast as it was: a spoken
    /// "approve" resolves a window in the time one tool call takes, and nothing about this
    /// seventh tool may put a loop in that path. What this one buys is the other half — a
    /// request that takes several steps, or that TapQ has to go and find something out
    /// before it can act on, which the six above can only refuse a piece at a time.
    ///
    /// Its description does the same job `ask_about_work`'s does, in the other direction,
    /// and against a harder boundary: `queue_instruction` is also "the wearer said a
    /// sentence to be acted on", and the difference is entirely whether one sentence sent
    /// verbatim is the whole of it. So the description names the reflex tools it is not,
    /// and says what the wearer gets back — an acknowledgment now, the work afterwards —
    /// because a model that expected an answer here would sit waiting for one.
    ///
    /// It names no conditional tool, deliberately. `ask_about_work` is composed on its own
    /// gate and may be absent from a run that has this one; a description that pointed at a
    /// tool the session never declared would be an invitation to call it, and a call for an
    /// undeclared name breaks the voice channel. The question boundary is therefore drawn by
    /// behavior, exactly as `query_status` draws its half.
    public static let startTaskDeclaration = VoiceToolDeclaration(
        name: startTask,
        description: """
            The wearer wants something done that takes more than one step, or that TapQ has \
            to look something up before it can do: "run the tests and let me know if \
            anything fails", "tell Codex to do what Claude just did", "find out why the \
            build broke and fix it". TapQ says out loud that it has taken the goal and \
            works on it after this call returns, so no answer or result comes back here — \
            do not wait for one and do not narrate what you think will happen. Use the \
            direct tools instead for anything that is one step and immediate: approve, \
            deny, select_item, one dictated sentence passed straight to an agent \
            (queue_instruction), or what is waiting and what has changed (query_status). A \
            question whose whole answer is already sitting in an agent's session history is \
            a question, not a task. Starting a task authorizes nothing: anything it leads \
            to still comes back to the wearer for approval.
            """,
        parameters: [
            VoiceToolParameter(
                name: "goal",
                kind: .string,
                description: """
                    What the wearer wants done, in their own words, including any agent \
                    names they said. Pass the whole request through — do not narrow it to \
                    keywords, do not break it into steps, and do not answer any part of it \
                    yourself.
                    """
            ),
        ]
    )

    /// The tool set for one composition.
    ///
    /// `ask_about_work` is present only when a `TranscriptStore` exists — that is, only on a
    /// cloud-backend run where an agent has a transcript TapQ may read. The Apple path
    /// declares five tools and has no sixth to disable, which is the same structural absence
    /// every other cloud-only pillar has: there is no flag, and a call for a tool that was
    /// never declared is a protocol failure rather than a feature that quietly worked.
    ///
    /// `start_task` is present on exactly the same terms and on its own gate: a composition
    /// with a deliberation loop declares it, and one without does not have a seventh tool to
    /// disable. The two gates are independent because the seams are — a run may be able to
    /// read a transcript and have no loop, or the reverse — and neither implies the other.
    public static func declarations(includingAskAboutWork: Bool,
                                    includingStartTask: Bool = false) -> [VoiceToolDeclaration] {
        var all = declarations
        if includingAskAboutWork { all.append(askAboutWorkDeclaration) }
        if includingStartTask { all.append(startTaskDeclaration) }
        return all
    }

    /// What a provider should do about one tool call.
    public enum Resolution: Equatable {
        /// Deliver `command` to the open window, then answer the model with `output`.
        case command(VoiceCommand, output: String)
        /// Nothing happens. Answer the model with `output`, and say `speak` out loud.
        ///
        /// Both, always, and the `speak` is not optional any more (audible-refusal decision,
        /// 2026-08-28). Until then `approve`, `deny`, and `select_item` refused a call that
        /// arrived with no open window in silence, on the reasoning that the window had
        /// probably just resolved by nod and announcing the race would report it to somebody
        /// who never saw one. The wearer this path exists for has no screen and often no
        /// nod: from their side, saying "approve" into a quiet room and hearing nothing is
        /// indistinguishable from TapQ being broken. The race is rare and costs one short
        /// sentence; the silence cost the wearer their only signal.
        ///
        /// The two halves are not the same sentence and neither can stand in for the other.
        /// `output` is for the model — it is the conversation's record of what happened, and
        /// it is *not* spoken. `speak` is the wearer's, sent verbatim on the scripted
        /// channel. TapQ never asks the model to say a refusal, because a tool result starts
        /// no response: nothing follows `sendToolResult`, so a refusal that lived only in
        /// `output` would be a refusal nobody ever hears.
        case refused(output: String, speak: String)
        /// The wearer asked about an agent's work. Nothing is resolved and no window is
        /// touched; the caller reads the transcript, asks the answer model, and speaks what
        /// comes back on the scripted channel.
        ///
        /// It is its own case rather than a `command` because there is no window intent it
        /// could carry: the five above all end in something a window consumes, and this one
        /// ends in a sentence. Keeping it separate is also what keeps a question from
        /// resolving an approval by accident — the window this call arrived inside is left
        /// exactly as it was found.
        case answerWorkQuestion(question: String, agent: String?)
        /// The wearer asked for something that takes deliberation. Nothing is resolved and no
        /// window is touched; the caller hands the goal to the loop and speaks the sentence
        /// the loop hands back.
        ///
        /// It is a sibling of `answerWorkQuestion` for the same reason that one is not a
        /// `command`: there is no window intent it could carry. The five above all end in
        /// something a window consumes, and these two end in a sentence. The difference
        /// between the two of them is what happens after the sentence — a question is over,
        /// and a task has only just started.
        case startTask(goal: String)
        /// The call names a tool TapQ never declared, or its arguments cannot be read.
        ///
        /// Not a refusal: a refusal is a legal call that could not run, and this is the tool
        /// protocol being wrong. It is a pipeline failure, and the caller breaks the voice
        /// channel on it rather than continuing with a session that is inventing actions.
        case malformed(String)
    }

    /// Spoken when a wearer-initiated tool arrives with nothing listening for its result.
    ///
    /// Says what happened and what to do about it, and does not name the tool: from the
    /// wearer's side there is one situation — they spoke into a gap — and one remedy.
    public static let notListeningNotice = "I wasn't listening just then — say it again."

    /// Spoken when the wearer answers a question that is no longer on the table: an
    /// approval, a refusal, or a pick, with no window open to receive it.
    ///
    /// A different sentence from ``notListeningNotice`` because it is a different situation
    /// and has a different remedy. Repeating a dictation is useful; repeating "yes" into the
    /// same silence is not, and the wearer needs to know there is nothing to say yes *to*
    /// rather than to be invited to try again. Short on purpose — it is most often heard a
    /// beat after a window the wearer resolved some other way.
    public static let nothingWaitingNotice = "Nothing is waiting."

    /// Spoken when the model picked an entry off the end of the list TapQ read.
    ///
    /// TapQ genuinely does not know which entry was meant — the numbering it read is the
    /// only one that exists, and the model produced one outside it — so the sentence asks
    /// rather than guessing. It cannot be left to the model to ask: no response follows a
    /// tool result.
    public static let unnumberedEntryNotice = "I didn't catch which one — say the number."

    /// Spoken when `queue_instruction` arrives carrying nothing to queue.
    ///
    /// The wearer dictated and there is no sentence to send, so this says what a dictation
    /// that captured silence has always said on the Apple path: nothing was queued, say it
    /// again.
    public static let emptyInstructionNotice = "I didn't catch that — say it again."

    /// Spoken when `ask_about_work` arrives with nothing to answer.
    ///
    /// The same sentence a dictation that captured silence gets, and for the same reason:
    /// from the wearer's side one situation happened — they spoke and nothing was heard —
    /// and the remedy is to say it again.
    public static let emptyQuestionNotice = emptyInstructionNotice

    /// Spoken when `start_task` arrives carrying no goal.
    ///
    /// The third of the same sentence, and it stays the same sentence on purpose. The wearer
    /// does not know which of the seven tools the model reached for; what happened to them is
    /// that they spoke and nothing was heard, and the remedy has been "say it again" since the
    /// Apple path. A distinct sentence here would be TapQ describing its own tool routing to
    /// somebody who has no screen to see it on.
    public static let emptyGoalNotice = emptyInstructionNotice

    /// Spoken when the model asks for a status TapQ does not keep.
    ///
    /// Names the two that exist, because unlike the entry above the remedy is a closed
    /// choice the wearer can act on immediately.
    public static let unknownStatusNotice =
        "I can't answer that — ask what's waiting, or what's changed."

    /// Turns one tool call into an outcome, without touching anything.
    ///
    /// Pure, and deliberately so: everything about which action a call means, whether it may
    /// run right now, and what the model should be told is decided here, where it can be
    /// tested exhaustively against strings a model might actually produce.
    ///
    /// - Parameter windowOpen: whether a window is armed to receive a command. Every tool
    ///   that resolves *something* delivers through one — including `queue_instruction`,
    ///   whose attribution check, addressing, mailbox, and spoken outcome *are* the window's
    ///   dictation flow. Executing one without a window would not be a shortcut: it would be
    ///   the instruction path with everything that makes it honest — the fail-closed check,
    ///   the refusals, the sentence that tells the wearer what was queued — removed.
    ///   `ask_about_work` and `start_task`
    ///   are the exceptions, and deliberately: neither resolves anything, so there is nothing
    ///   for a window to receive, and a sentence TapQ can speak on its own channel is not
    ///   made safer by refusing it because a prompt happened to have closed a beat earlier.
    /// - Parameter askAboutWorkDeclared: whether this composition declared the transcript
    ///   tool. `false` — every Apple-path composition, and every cloud run with no
    ///   transcript attached — makes a call for it a protocol failure, exactly as any other
    ///   undeclared name is. That is the gate: not a disabled feature, an undeclared one.
    /// - Parameter startTaskDeclared: whether this composition declared the deliberation
    ///   tool. Its own gate, read exactly as the one above: `false` is every Apple-path
    ///   composition and every cloud run with no loop, and a call for it there is the tool
    ///   protocol being wrong rather than a loop that quietly did not run. `start_task` needs
    ///   no window for the same reason `ask_about_work` does not — it resolves nothing, it
    ///   delivers no command, and the sentence it produces goes out on TapQ's own channel.
    public static func resolve(_ call: VoiceToolCall, windowOpen: Bool,
                               askAboutWorkDeclared: Bool = false,
                               startTaskDeclared: Bool = false) -> Resolution {
        switch call.name {
        case approve:
            return windowed(.yes, output: "Approved.", windowOpen: windowOpen,
                            speak: nothingWaitingNotice)
        case deny:
            return windowed(.no, output: "Denied.", windowOpen: windowOpen,
                            speak: nothingWaitingNotice)
        case selectItem:
            guard let arguments = decode(SelectItemArguments.self, from: call) else {
                return .malformed("select_item arguments could not be read")
            }
            // One-based because that is how the list was read out loud. A zero or a negative
            // index is a model counting from somewhere TapQ never numbered, and picking the
            // "closest" entry would be choosing on the wearer's behalf.
            guard arguments.index >= 1 else {
                return .refused(
                    output: "There is no entry \(arguments.index); entries are numbered "
                        + "from 1. TapQ has asked the wearer which one they meant.",
                    speak: unnumberedEntryNotice
                )
            }
            return windowed(.number(arguments.index), output: "Selected entry \(arguments.index).",
                            windowOpen: windowOpen, speak: nothingWaitingNotice)
        case queueInstruction:
            guard let arguments = decode(QueueInstructionArguments.self, from: call) else {
                return .malformed("queue_instruction arguments could not be read")
            }
            let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .refused(
                    output: "No instruction text was supplied, so nothing was queued.",
                    speak: emptyInstructionNotice
                )
            }
            // The address is re-attached to the sentence rather than carried beside it, and
            // the reason is that the dictation flow — fail-closed attribution, routing,
            // the spoken outcome, the unknown-agent refusal — already resolves an address
            // out of the text it is given. Composing here is the inverse of the parse that runs there, not a
            // new grammar: nothing about it reads the wearer's transcript, and the name it
            // encodes came from the model as a structured argument. Rung E's fail-closed
            // semantics then apply unchanged, including the spoken refusal for a name
            // nothing answers to.
            let addressed = arguments.agent
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { InstructionAddress.compose(name: $0, rest: text) }
            return windowed(
                .beginInstruction(addressed ?? text),
                output: "Queueing the instruction and telling the wearer out loud what was "
                    + "queued and for whom.",
                windowOpen: windowOpen,
                speak: notListeningNotice
            )
        case queryStatus:
            guard let arguments = decode(QueryStatusArguments.self, from: call) else {
                return .malformed("query_status arguments could not be read")
            }
            let command: VoiceCommand
            switch arguments.kind {
            case statusKindWaiting: command = .status
            case statusKindChanged: command = .whatChanged
            default:
                return .refused(
                    output: "\"\(arguments.kind)\" is not a status TapQ tracks; the only two "
                        + "are \"\(statusKindWaiting)\" and \"\(statusKindChanged)\", and "
                        + "TapQ has told the wearer so.",
                    speak: unknownStatusNotice
                )
            }
            return windowed(command, output: "TapQ is answering the wearer out loud.",
                            windowOpen: windowOpen, speak: notListeningNotice)
        case askAboutWork:
            // Undeclared here means undeclared on the wire: this composition never sent the
            // tool, so a call for it is the protocol not being the one TapQ configured.
            guard askAboutWorkDeclared else {
                return .malformed("the backend called an undeclared tool \"\(call.name)\"")
            }
            guard let arguments = decode(AskAboutWorkArguments.self, from: call) else {
                return .malformed("ask_about_work arguments could not be read")
            }
            let question = arguments.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                return .refused(
                    output: "No question was supplied, so nothing was looked up.",
                    speak: emptyQuestionNotice
                )
            }
            let agent = arguments.agent
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return .answerWorkQuestion(question: question, agent: agent)
        case startTask:
            // Same gate, same reading as above: undeclared here means this composition never
            // put the tool on the wire, so a call for it is the protocol not being the one
            // TapQ configured. A run with no loop has no deliberation tier to route into and
            // must not pretend otherwise.
            guard startTaskDeclared else {
                return .malformed("the backend called an undeclared tool \"\(call.name)\"")
            }
            guard let arguments = decode(StartTaskArguments.self, from: call) else {
                return .malformed("start_task arguments could not be read")
            }
            let goal = arguments.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            // A legal call that could not run, exactly like an empty dictation: refused out
            // loud, and the session survives it. Nothing reaches the loop — a task with no
            // goal is a loop spending its step budget on silence.
            guard !goal.isEmpty else {
                return .refused(
                    output: "No goal was supplied, so no task was started.",
                    speak: emptyGoalNotice
                )
            }
            return .startTask(goal: goal)
        default:
            // A name TapQ never declared. The service refuses unknown tools before they are
            // sent, so reaching here means the tool protocol is not the one TapQ configured.
            return .malformed("the backend called an undeclared tool \"\(call.name)\"")
        }
    }

    private static func windowed(_ command: VoiceCommand, output: String,
                                 windowOpen: Bool, speak: String) -> Resolution {
        guard windowOpen else {
            return .refused(
                output: "Nothing is listening for that right now, so it was not carried out.",
                speak: speak
            )
        }
        return .command(command, output: output)
    }

    /// Reads a tool's arguments, or `nil` when they are not the shape TapQ declared.
    ///
    /// A missing-arguments string is treated as an empty object so a parameterless tool
    /// decodes cleanly whichever way the service spells "no arguments".
    private static func decode<T: Decodable>(_ type: T.Type,
                                             from call: VoiceToolCall) -> T? {
        let json = call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private struct SelectItemArguments: Decodable {
        let index: Int
    }

    private struct QueueInstructionArguments: Decodable {
        let text: String
        let agent: String?
    }

    private struct QueryStatusArguments: Decodable {
        let kind: String
    }

    private struct AskAboutWorkArguments: Decodable {
        let question: String
        let agent: String?
    }

    private struct StartTaskArguments: Decodable {
        let goal: String
    }
}
