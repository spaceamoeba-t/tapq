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
                summarize, translate, or tidy it. TapQ reads it back to them for confirmation \
                before anything is sent, so a slightly wrong capture is recoverable and a \
                rewritten one is not.
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
                nothing — whatever they were asked is still on the table afterwards.
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
    ///   here delivers through one — including `queue_instruction`, whose read-back and
    ///   fail-closed attribution check *are* the window's dictation flow. Executing one
    ///   without a window would not be a shortcut, it would be the instruction path with its
    ///   confirmation removed.
    public static func resolve(_ call: VoiceToolCall, windowOpen: Bool) -> Resolution {
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
            // the reason is that the dictation flow — read-back, fail-closed attribution,
            // confirm, unknown-agent refusal — already resolves an address out of the text
            // it is given. Composing here is the inverse of the parse that runs there, not a
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
                output: "Reading the instruction back to the wearer for confirmation.",
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
}
