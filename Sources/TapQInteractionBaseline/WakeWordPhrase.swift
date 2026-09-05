/// The phrase a wake-word spotter fires on, and the only place a transcript is compared
/// against it (`docs/WAKE_WORD_PLAN.md` §2).
///
/// This is the one piece of the wake word that is *not* a model's business. Everything
/// after the window opens is resolved by the realtime model's tool calls — decision 0b,
/// `tapq-voice-failure-posture` — but the window has to be opened by something that runs
/// with nothing running, and that something is a keyword match on an on-device
/// recognizer's transcript. Keeping the match here, in a pure value type, is what keeps it
/// out of the realtime path.
///
/// Deliberately free of Foundation: `lowercased()` and `isLetter` are stdlib and follow
/// Unicode's default case mapping, so a wearer whose machine is set to Turkish gets the
/// same answer as one whose machine is set to English. A locale-aware lowercasing would
/// turn `I` into `ı` and quietly stop matching a phrase containing it.
public struct WakeWordPhrase: Sendable, Equatable {
    /// The spellings an on-device recognizer produces for the name, each as the tokens it
    /// arrives in. "TapQ" is not a word, so the recognizer guesses: it hears the letter,
    /// or it hears the English word that sounds like it. All of them mean the name.
    ///
    /// `tap-q` and `tap Q` are not listed because they are not distinct: punctuation is a
    /// separator and case is folded, so both arrive here as `["tap", "q"]`.
    private static let nameSpellings: [[String]] = [
        ["tapq"], ["tap", "q"], ["tap", "queue"], ["tap", "cue"],
    ]

    /// The token every spelling folds to. Not a real word, so it cannot itself be said by
    /// accident: after folding, a match is a match on the name and nothing else.
    static let nameToken = "tapq"

    /// The spellings that are also ordinary English words. `q` is not one — nobody says
    /// "tap q" meaning anything but the name — but "queue" and "cue" are, and the second
    /// half of the fold below exists entirely for them.
    private static let ambiguousSpellings: Set<String> = ["queue", "cue"]

    /// Particles that turn an ambiguous spelling into a verb. "Queue up the list" is a
    /// thing a wearer says to a person; "hey, tap queue up the list" would otherwise fold
    /// to "hey tapq up the list" and open a window in the middle of a conversation.
    ///
    /// Narrow on purpose. This is not a parser and must not become one: it is a list of
    /// the words measured to precede a false fire, and the cost of a missing entry is one
    /// spurious window, not a wrong action — the window still needs a sentence to do
    /// anything, and an empty one closes in twenty seconds.
    private static let verbParticles: Set<String> = ["up"]

    /// The configured phrase, as the operator wrote it. Kept for diagnostics only.
    public let phrase: String

    /// The phrase after normalization. Empty means this phrase can never match, which is
    /// what an all-punctuation phrase deserves; the CLI refuses a blank one before it gets
    /// here, and `isSpoken(in:)` refuses it again rather than matching everything.
    let tokens: [String]

    public init(_ phrase: String) {
        self.phrase = phrase
        self.tokens = Self.normalize(phrase)
    }

    /// The normalized phrase, space-joined — what a diagnostic should print when it says
    /// what TapQ is listening for.
    public var normalized: String { tokens.joined(separator: " ") }

    /// Whether the phrase occurs in `transcript` as a whole-word sequence.
    ///
    /// Whole-word and contiguous, both of which matter. Substring matching would find the
    /// name inside a longer word; a gapped match would find "hey ... tapq" across half a
    /// sentence. What the wearer has to say is the phrase, said as the phrase, anywhere in
    /// what the recognizer heard.
    public func isSpoken(in transcript: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        let heard = Self.normalize(transcript)
        guard heard.count >= tokens.count else { return false }
        for start in 0...(heard.count - tokens.count)
        where Array(heard[start..<(start + tokens.count)]) == tokens {
            return true
        }
        return false
    }

    /// Lowercase, drop punctuation, collapse whitespace, fold the name.
    ///
    /// Splitting on anything that is not a letter or a digit does the first three at once:
    /// "Hey, TapQ!" and "hey    tapq" both become `["hey", "tapq"]`.
    static func normalize(_ text: String) -> [String] {
        let raw = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var folded: [String] = []
        folded.reserveCapacity(raw.count)
        var index = 0
        while index < raw.count {
            if let length = nameSpellingLength(in: raw, at: index) {
                folded.append(nameToken)
                index += length
            } else {
                folded.append(raw[index])
                index += 1
            }
        }
        return folded
    }

    /// How many tokens of `raw` at `index` spell the name, or nil for none.
    ///
    /// Longest spelling first, so `["tap", "queue"]` is never read as `["tap"]` plus a
    /// leftover. There is no such collision today; there will be the first time a spelling
    /// is a prefix of another.
    private static func nameSpellingLength(in raw: [String], at index: Int) -> Int? {
        for spelling in nameSpellings.sorted(by: { $0.count > $1.count }) {
            guard index + spelling.count <= raw.count,
                  Array(raw[index..<(index + spelling.count)]) == spelling else { continue }
            // The ambiguity guard. Only the last token of a spelling can be an English
            // word, and only then can a following particle mean the wearer was talking
            // about a queue rather than to TapQ.
            if let last = spelling.last, ambiguousSpellings.contains(last) {
                let next = index + spelling.count
                if next < raw.count, verbParticles.contains(raw[next]) { continue }
            }
            return spelling.count
        }
        return nil
    }
}
