import TapQContracts

/// Deterministic, hardware-independent keyword grammar for short voice commands.
/// Speech-to-text acquisition remains the responsibility of a platform adapter.
///
/// Every rule matches at word granularity: the transcript is split into letter-only
/// words and a rule matches either one word or a run of adjacent words. Raw substring
/// containment is deliberately absent — it is what let "don't do it" approve (the text
/// contains "do it"), and the same leak reads "undo items" as "do it", "cannot" as
/// "not", and "notify" as "not".
///
/// The two answers are not symmetric. A missed `.no` costs the user one repeat; a wrong
/// `.yes` runs an agent action nobody authorized. Approval therefore carries a structural
/// guard rather than an ordering assumption: `.yes` is unreachable for any transcript
/// containing a negator — `negationWords`, which covers the "no" family, bare "not", and
/// the contracted forms — however the words are arranged around it. Ordering the `.no`
/// branch first would fix the reported phrases and leave "not okay" approving; the guard
/// closes the class instead of the instances.
///
/// A transcript that is negated but carries no outright denial ("not okay", "sure, why
/// not") resolves to `nil` rather than guess a side. TapQ fails open: an unmatched
/// transcript leaves the request to the agent's on-screen prompt, which the user can
/// still answer, so silence is recoverable in a way a wrong approval is not.
public enum VoiceCommandMatcher {
    public static func match(_ raw: String) -> VoiceCommand? {
        let words = Self.words(in: raw)
        let vocabulary = Set(words)
        func token(_ candidates: String...) -> Bool {
            candidates.contains { vocabulary.contains($0) }
        }
        func phrase(_ phrases: String...) -> Bool {
            phrases.contains { Self.contains(run: $0, in: words) }
        }

        if token("repeat", "again") || phrase("say again", "one more time") { return .repeatRequest }
        if token("details", "detail", "explain") || phrase("more info", "tell me more") { return .details }
        if token("skip", "later", "unsure") || phrase("ask later", "not sure") { return .skip }
        if token("next") || phrase("next option", "move on") { return .next }
        if token("previous", "back") || phrase("go back", "last one") { return .previous }
        if token("select", "choose", "pick") || phrase("pick this", "this one", "go with this") { return .select }
        if token("one", "first") { return .number(1) }
        if token("two", "second") { return .number(2) }
        if token("three", "third") { return .number(3) }
        if token("four", "fourth") { return .number(4) }
        // Recall questions are matched ahead of the affirmative guard so an interrogative
        // can never be read as an answer. "What did you do?" ends in a word the yes branch
        // does not know, but "status" and "waiting" sit in sentences that also carry
        // "okay" and "sure" often enough that ordering is the only structural defence:
        // whatever else a transcript contains, if it asks one of these questions it
        // resolves to the question. Both commands are informational at every call site,
        // so losing an approval to one costs the user a repeat and nothing more.
        //
        // Contractions are written apostrophe-free ("whos") because `words(in:)` elides
        // apostrophes before a phrase is ever compared.
        if token("status") || phrase("whos waiting", "who is waiting") { return .status }
        // The "just" variants are listed because runs match adjacent words only: "what
        // did you just do" is what a wearer actually says, and without them it is the one
        // phrasing of the question that the grammar hears as nothing at all.
        if phrase("what changed", "what has changed", "what did you change",
                  "what did you do", "what did you just do",
                  "what have you done", "what have you just done") { return .whatChanged }
        // Negation is read from the whole transcript rather than from the words adjacent
        // to the affirmative: this grammar sees partial transcriptions in arbitrary states
        // of completeness, so a negator can land on either side of the word it governs,
        // and no reading of a negated sentence is worth approving on.
        if vocabulary.isDisjoint(with: Self.negationWords),
           token("yes", "yeah", "yep", "yup", "approve", "approved", "sure", "okay", "ok", "confirm")
            || phrase("do it", "go ahead", "go for it") { return .yes }
        if !vocabulary.isDisjoint(with: Self.denialWords) || phrase("do not") { return .no }
        return nil
    }

    /// Words that deny on their own, so reaching one is an answer and not merely a doubt.
    /// "dont" covers every apostrophe spelling of "don't" once `words(in:)` has run.
    private static let denialWords: Set<String> = [
        "no", "nope", "nah", "deny", "denied", "cancel", "stop", "reject", "dont",
    ]

    /// Words that forbid an approval. Every denial word negates; the rest negate without
    /// deciding anything, because a grammar this small cannot separate "not okay" (a
    /// refusal) from "sure, why not" (an approval). Both stop short of `.yes` and fall
    /// through to `nil` unless a denial word is present too.
    ///
    /// Contractions appear in their apostrophe-stripped form for the same reason as
    /// "dont", and "cannot" is listed explicitly because word-level matching — correctly —
    /// does not see the "not" inside it.
    private static let negationWords: Set<String> = denialWords.union([
        "not", "never", "cannot", "cant", "wont", "isnt", "arent", "wasnt",
        "doesnt", "didnt", "couldnt", "wouldnt", "shouldnt", "aint",
    ])

    /// The apostrophe spellings a transcript can carry. Recognizers emit the typographic
    /// U+2019 far more often than the ASCII U+0027 this grammar is written with, so a
    /// literal-only comparison would never see a spoken "don't" at all.
    private static let apostrophes: Set<Character> = [
        "\u{0027}", // ' apostrophe
        "\u{2019}", // ’ right single quotation mark
        "\u{02BC}", // ʼ modifier letter apostrophe
        "\u{2018}", // ‘ left single quotation mark, from pair-matching engines
        "\u{FF07}", // ＇ fullwidth apostrophe
    ]

    /// Lowercased words in spoken order, apostrophes removed.
    ///
    /// Apostrophes are elided instead of separating words, so every spelling of "don't"
    /// — ASCII, typographic, or the apostrophe-free "dont" a recognizer also produces —
    /// yields the single word "dont". Splitting on them instead yields "don" and "t",
    /// neither of which is a negator, which is how a curly-quoted denial used to reach
    /// the affirmative branch.
    ///
    /// The elision is by explicit apostrophe set, not by keeping letters: U+02BC is a
    /// Unicode letter (modifier letter, category Lm), so a letters-only filter would
    /// leave it inside the word and "donʼt" would again miss "dont".
    private static func words(in raw: String) -> [String] {
        raw.lowercased()
            .split { !$0.isLetter && !apostrophes.contains($0) }
            .map { String($0.filter { !apostrophes.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    /// Whether `words` holds the space-separated `run` as consecutive whole words.
    private static func contains(run: String, in words: [String]) -> Bool {
        let needle = run.split(separator: " ").map(String.init)
        guard !needle.isEmpty, words.count >= needle.count else { return false }
        return (0...(words.count - needle.count)).contains { start in
            words[start ..< (start + needle.count)].elementsEqual(needle)
        }
    }
}
