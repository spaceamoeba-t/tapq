import Foundation

/// Where a name-addressed instruction would go, as the host answers for it.
///
/// The three fields are everything the dictation flow is allowed to know about another
/// agent: the name it says out loud, whether that agent has a turn boundary to deliver
/// into, and one closure that can put a sentence in its queue. There is deliberately no
/// session identifier here and no `AgentIdentity` — the flow never speaks either, and a
/// field it cannot see is a field it cannot leak into a read-back.
///
/// `enqueue` is the same ``InstructionDictating`` the in-window path takes, for the same
/// reason: text in, nothing out. Routing changes which queue a sentence lands in and
/// nothing else — a routed dictation can no more allow, deny, or select than an
/// unaddressed one.
public struct InstructionAddressee {
    /// The resolved agent's display name, for the read-back and the queued notice.
    public let agentDisplayName: String
    /// Whether ``TapQContracts/AgentCapabilities`` says this agent can receive an
    /// instruction at all. Answered by the host rather than looked up here, because the
    /// controllers stay ignorant of the adapter table — the same reason
    /// ``InstructionCapabilityChecking`` is a closure.
    public let acceptsInstructions: Bool
    /// Queues the instruction for this agent's next turn boundary.
    public let enqueue: InstructionDictating

    public init(
        agentDisplayName: String,
        acceptsInstructions: Bool,
        enqueue: @escaping InstructionDictating
    ) {
        self.agentDisplayName = agentDisplayName
        self.acceptsInstructions = acceptsInstructions
        self.enqueue = enqueue
    }
}

/// What a spoken agent name resolved to.
///
/// Two cases and a `nil`, which is three answers: this agent, *which* one, and no such
/// agent. The middle case exists because the roster behind this seam assumes one live
/// session per adapter, and the honest thing to do when that assumption breaks is to say
/// so — not to pick the newer session and hope. Both non-resolutions refuse the dictation;
/// neither falls back to the window's own target, because a wearer who named an agent
/// meant that agent.
public enum InstructionAddressResolution {
    /// The name belongs to exactly one live session.
    case resolved(InstructionAddressee)
    /// The name belongs to an adapter with more than one live session, so it names no one
    /// session. Carries the display name so the refusal can say which agent is doubled.
    case ambiguous(agentDisplayName: String)
}

/// Resolves a spoken agent name to the session a dictation should be routed to, or `nil`
/// when nothing live answers to that name.
///
/// A closure for the reason every other seam on this path is one: which sessions exist is
/// something the runtime's conversation memory tracks, and the controllers must stay
/// ignorant of it. It is also the whole extension point — a future fleet roster that
/// tracks sessions properly replaces what is behind this closure without the dictation
/// flow learning a thing.
///
/// An absent resolver is not a refusal, it is the composition that predates addressing:
/// the flow never looks for an address at all, and every dictation goes to the window's
/// own target exactly as it always has.
public typealias InstructionAddressResolving =
    @MainActor (String) -> InstructionAddressResolution?

/// The leading address on a dictated sentence: "tell Codex to run the tests".
///
/// Deliberately the smallest grammar that covers what a wearer actually says, and
/// deliberately deterministic — no model, no fuzzy matching, no scoring. A dictation that
/// is misread as an address costs the wearer a refusal they can hear and repeat; one that
/// silently routed to the wrong agent would cost them a sentence in a session they were
/// not looking at.
///
/// The parse is anchored at the start of the sentence and nowhere else. "Ask Claude Code
/// to tell Codex to stop" is one instruction for one agent, and a grammar that scanned for
/// "tell" anywhere would have cut it in half.
enum InstructionAddress {
    /// A recognized address and what remained of the sentence.
    struct Parsed: Equatable {
        /// The spoken name, punctuation trimmed, in the wearer's own casing — it is read
        /// back in the refusal when nothing answers to it.
        let name: String
        /// The instruction itself, with the address removed. Never empty.
        let rest: String
    }

    /// The word that opens an address. One word, because a second phrasing is a second
    /// thing that can be misheard, and "tell ⟨agent⟩ to …" is the phrasing the dictation
    /// grammar already teaches.
    static let opener = "tell"

    /// What may separate the name from the instruction: "tell Codex **to** run the tests",
    /// or a colon the wearer's recognizer punctuated in. Neither is required — a bare
    /// "tell Codex run the tests" reads the first word as the name — but requiring one of
    /// them for a *multi-word* name is what keeps the fallback from swallowing a sentence.
    static let separator = "to"

    /// How many words an agent name may run to. Three covers every shipped display name
    /// and leaves room for one a host adds; past that, an unseparated sentence is being
    /// read as a name.
    static let maxNameWords = 3

    /// Words that follow "tell" without naming anyone.
    ///
    /// This set is what makes an unaddressed sentence stay unaddressed. "Tell it to run
    /// the tests" and "tell me what changed" both open with the address shape and neither
    /// is one, so the parse must decline them rather than refuse a dictation the wearer
    /// phrased exactly as this repo has always taught.
    ///
    /// A real agent name is deliberately *not* in here, "claude" included: a name that
    /// resolves is an address, and the one-breath forms the dictation grammar already
    /// strips ("tell claude to …") never reach this parser with their prefix intact.
    static let unaddressed: Set<String> = [
        "it", "me", "him", "her", "them", "us", "you", "the", "this", "that",
        "everyone", "somebody", "someone",
    ]

    /// The address on `text`, or `nil` when it carries none — which is every sentence the
    /// wearer has ever dictated, and is why `nil` means "behave exactly as before".
    static func parse(_ text: String) -> Parsed? {
        let words = Self.words(in: text)
        // "tell", a name, and something to say: fewer words than that is not an address.
        guard words.count >= 3, normalized(words[0].text) == opener else { return nil }
        guard !unaddressed.contains(normalized(words[1].text)) else { return nil }

        // Where the name ends and the instruction begins. The fallback — one word of name,
        // no separator — is what makes "tell Codex run the tests" work.
        var nameEnd = 2
        var restStart = 2
        for index in 1...min(maxNameWords, words.count - 1) {
            if words[index].text.hasSuffix(":") {
                nameEnd = index + 1
                restStart = index + 1
                break
            }
            if index > 1, normalized(words[index].text) == separator {
                nameEnd = index
                restStart = index + 1
                break
            }
        }
        guard restStart < words.count else { return nil }

        let name = words[1..<nameEnd]
            .map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !name.isEmpty else { return nil }

        let rest = text[words[restStart].range.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        return Parsed(name: name, rest: rest)
    }

    /// Lowercased letters and digits only, so a recognizer's punctuation cannot hide a
    /// match. The same normalization the runtime's roster compares names with.
    static func normalized<S: StringProtocol>(_ text: S) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whitespace-separated words paired with where they sit in the *original* string.
    ///
    /// The pairing is what lets the instruction be taken from `text` rather than rebuilt
    /// from the words: what the wearer said is going to a language model, and rebuilding
    /// would cost it the casing and punctuation that carry meaning ("readme" is not
    /// "README"). The same reason ``TapQDetectionBaseline/VoiceCommandMatcher`` keeps
    /// ranges into the raw transcript.
    private static func words(
        in text: String
    ) -> [(text: Substring, range: Range<String.Index>)] {
        var result: [(text: Substring, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            result.append((text: text[start..<index], range: start..<index))
        }
        return result
    }
}
