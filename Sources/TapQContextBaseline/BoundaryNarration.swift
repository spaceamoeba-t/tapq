import Foundation
import TapQContracts

/// One thing waiting to be said to the wearer at a turn boundary.
///
/// The type is deliberately narrow, and the narrowness is the redaction rule made
/// structural: an item is a `kind` and a string that TapQ is *already* allowed to speak.
/// There is nowhere here to put a `toolInput`, a `cwd`, a `permissionMode`, a session
/// identifier, or a file the agent touched — the same absence that keeps
/// ``SessionContextEvent`` and ``QueuedInstruction`` safe to read out loud. A narration
/// model therefore cannot be shown anything a wearer could not have heard anyway.
public struct NarrationItem: Sendable, Equatable {
    /// What kind of pending thing this is. The model uses it to decide whose words these
    /// are — an agent's message may be summarized or turned into a question; a TapQ notice
    /// is TapQ's own status line and should survive close to intact.
    public enum Kind: String, Sendable, Equatable {
        /// The agent's final text reply for the turn that just ended.
        case agentMessage = "agent_message"
        /// A TapQ status line that accumulated while the wearer was not being spoken to.
        case notice
    }

    public let kind: Kind
    /// The item's text, exactly as TapQ would have been allowed to speak it.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Everything pending for the wearer at one turn boundary, in the order it arrived.
public struct NarrationRequest: Sendable, Equatable {
    /// The agent whose boundary this is, by display name only — "Claude Code", never a
    /// session identifier. The model may use it to say who is talking when more than one
    /// agent is in play; it is the same string the dictation read-back already speaks.
    public let agentDisplayName: String
    /// Pending items, in the order TapQ would have spoken them: the turn's own outcome
    /// first, then any status lines that accumulated behind it. Never empty — a boundary
    /// with nothing pending does not reach the narrator at all.
    public let items: [NarrationItem]

    public init(agentDisplayName: String, items: [NarrationItem]) {
        self.agentDisplayName = agentDisplayName
        self.items = items
    }
}

/// How the narration model chose to deliver what was pending.
///
/// The mode is advisory for everything except ``question``: TapQ speaks
/// ``NarrationUtterance/text`` verbatim whichever mode came back, and the mode is logged
/// so an operator can see what the model decided. ``question`` is the one mode that
/// changes what TapQ *does*, because it routes the utterance into the answer machinery.
public enum NarrationDeliveryMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// The item was short enough to read out word for word.
    case verbatim
    /// The item was condensed.
    case summary
    /// The utterance is a question for the wearer, and their answer goes back to the agent.
    case question
    /// Several pending items were merged into one utterance.
    case combined
}

/// The one sentence TapQ speaks at this boundary, and what the model meant by it.
public struct NarrationUtterance: Sendable, Equatable {
    /// Spoken verbatim on the scripted-speech channel. Never re-summarized, never
    /// truncated: the model was asked for an utterance and this is the utterance.
    public let text: String
    public let mode: NarrationDeliveryMode

    public init(text: String, mode: NarrationDeliveryMode) {
        self.text = text
        self.mode = mode
    }

    /// Whether the wearer's reply has to be carried back to the agent.
    public var isQuestion: Bool { mode == .question }
}

/// Why a narration call did not produce an utterance.
///
/// Every case is a voice-pipeline failure on the model-backed path. There is deliberately
/// no "unavailable, carry on" case: the heuristics this replaced are gone, so there is
/// nothing to fall back *to*, and a boundary that silently said nothing would leave the
/// wearer waiting on a pipe they have no way to know is dead.
public enum NarrationFailure: Error, Equatable, Sendable {
    /// The request could not be built or sent.
    case transport(String)
    /// The provider answered with a non-2xx status.
    case http(status: Int)
    /// The bounded wait elapsed first.
    case timedOut
    /// A well-formed response whose utterance was empty once normalized.
    case emptyOutput
    /// A response that did not decode into an utterance and a mode.
    case malformedResponse

    /// A short operator-facing reason. Carries no wearer speech and no agent output — the
    /// same rule the queue's diagnostics follow.
    public var reason: String {
        switch self {
        case let .transport(detail): return "transport: \(detail)"
        case let .http(status): return "http \(status)"
        case .timedOut: return "timeout"
        case .emptyOutput: return "empty output"
        case .malformedResponse: return "malformed response"
        }
    }
}

/// A model that decides what TapQ says at a turn boundary.
///
/// It throws rather than returning `nil`, and the difference is the whole failure posture:
/// `nil` is the vocabulary of ``SpokenSummarizing``, where "I can't answer" fell through
/// to a local heuristic. There is no such heuristic behind this protocol, so an
/// implementation that cannot answer must say so loudly enough for the caller to break
/// the run's voice pipe.
public protocol BoundaryNarrating: Sendable {
    func narrate(_ request: NarrationRequest) async throws -> NarrationUtterance
}

/// The guidance prompt and the structured-output contract shared by narration providers.
public enum NarrationContract {
    /// The name of the strict JSON schema, as it appears on the wire.
    public static let schemaName = "tapq_narration"

    /// The system prompt. It is guidance rather than code: everything the removed
    /// heuristics decided by rule — is this a question, how short should it be, may two
    /// things be said in one breath — is decided here, in prose, by the model.
    public static let instructions = """
        You are the voice of TapQ, a hands-free assistant a person wears while a coding \
        agent works for them. Their hands and eyes are busy; they cannot see a screen. \
        You are given everything that is pending for them at one turn boundary and you \
        write the single utterance TapQ will speak. Your output is spoken aloud word for \
        word, so write speech, not prose: no markdown, no bullet points, no headings, no \
        emoji, no stage directions.

        Choose exactly one delivery mode and report it:

        - "verbatim": read the pending text out as it is. Prefer this whenever a single \
        agent message is already one or two spoken-length sentences. Do not paraphrase \
        something that was already short and clear; rewriting it only risks losing detail \
        the wearer needed.
        - "summary": condense a long or structured message into what the wearer actually \
        needs to hear. Lead with the outcome. Drop restated plans, apologies, preambles, \
        and lists of files the wearer did not ask for.
        - "question": the pending text is asking the wearer to decide something, or it \
        cannot proceed without an answer. Write the question you want answered, phrased so \
        it can be answered yes or no, and phrase it so a bare "yes" is unambiguous. Include \
        just enough context in the same utterance for the question to make sense on its \
        own — the wearer hears this and nothing else. Use this mode only when an answer is \
        genuinely needed to continue; a message that merely ends in a question mark while \
        reporting finished work is not a question for the wearer.
        - "combined": more than one thing is pending. Say them in one utterance, in the \
        order given, joined so it sounds like one person speaking. If one of the pending \
        items needs an answer, use "question" instead and fold the other items in as \
        context ahead of the question.

        Rules that hold in every mode:

        - Preserve technical tokens exactly as they appear: file paths, command lines, \
        flags, identifiers, error codes, version numbers, and counts. Never round a number, \
        never abbreviate a path, never "fix" a spelling inside one. If a path or command is \
        long, it is still better to say it than to describe it.
        - Never invent work, results, or reasons that the pending text does not state. If \
        the text is ambiguous, say what it says.
        - Never tell the wearer to approve, run, install, or delete anything on your own \
        initiative. TapQ has its own scripted sentences for authorizing work and you are \
        not one of them.
        - Do not add pleasantries, sign-offs, or offers to help further.
        - Speak in the first person as the agent's messenger when it reads naturally \
        ("It finished the migration"), and name the agent only when it clarifies who is \
        speaking.
        """

    /// The strict JSON schema the provider is asked to fill.
    public static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "utterance": [
                "type": "string",
                "description": "The exact words TapQ will speak. Plain spoken text.",
            ],
            "mode": [
                "type": "string",
                "enum": NarrationDeliveryMode.allCases.map(\.rawValue),
                "description": "Which delivery mode was chosen.",
            ],
        ],
        "required": ["utterance", "mode"],
        "additionalProperties": false,
    ]

    /// Renders the pending items into the model's input.
    ///
    /// Only ``NarrationItem`` content and the agent's display name cross this boundary.
    /// The rendering is here rather than in a provider so every provider sends the same
    /// bytes and a redaction test has one place to look.
    public static func input(for request: NarrationRequest) -> String {
        var lines = ["Agent: \(request.agentDisplayName)"]
        lines.append("Pending items (\(request.items.count)), oldest first:")
        for (index, item) in request.items.enumerated() {
            lines.append("\(index + 1). [\(item.kind.rawValue)] \(item.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Decodes a provider's JSON payload into an utterance.
    ///
    /// Whitespace is collapsed — a spoken line has no use for newlines — and nothing is
    /// shortened. A model that wrote a paragraph is speaking a paragraph, deliberately:
    /// the caps that used to guard this are the heuristics that were removed, and
    /// re-imposing one here would silently clip the very thing the model was asked to
    /// decide.
    public static func decode(_ text: String) throws -> NarrationUtterance {
        guard let data = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: data) else {
            throw NarrationFailure.malformedResponse
        }
        guard let mode = NarrationDeliveryMode(rawValue: extraction.mode) else {
            throw NarrationFailure.malformedResponse
        }
        let spoken = SpokenSummaryText.normalized(extraction.utterance)
        guard !spoken.isEmpty else { throw NarrationFailure.emptyOutput }
        return NarrationUtterance(text: spoken, mode: mode)
    }

    private struct Extraction: Decodable {
        let utterance: String
        let mode: String
    }
}
