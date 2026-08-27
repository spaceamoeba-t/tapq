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
        let tokens = Self.tokens(in: raw)
        let words = tokens.map(\.word)
        let vocabulary = Set(words)
        func token(_ candidates: String...) -> Bool {
            candidates.contains { vocabulary.contains($0) }
        }
        func phrase(_ phrases: String...) -> Bool {
            phrases.contains { Self.contains(run: $0, in: words) }
        }

        // Dictation is matched ahead of every other rule, and the position is load-bearing
        // in both directions.
        //
        // Ahead of the rest: an instruction is a whole sentence of ordinary English, and
        // the words this grammar reserves are exactly the words that sentence is likely to
        // contain. "Tell it to explain the diff" carries `explain`, "tell it to go ahead
        // and merge" carries `go ahead`, "tell it to run the tests again" carries `again`.
        // Read from any later position, a dictated sentence is heard as a command about
        // the request in front of the wearer — and one of those readings approves it.
        //
        // Guarded from behind: a negator anywhere *before* the trigger blocks the branch,
        // so "don't tell it to run the tests" falls through to `.no` instead of opening a
        // dictation the wearer was refusing. The guard deliberately stops at the trigger:
        // everything after it is the wearer's own text, and "tell it to stop the server"
        // is an instruction to stop a server, not a denial of anything.
        if let instruction = Self.beginInstruction(in: raw, tokens: tokens) { return instruction }
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

    /// Phrases that open dictation without supplying any text: the wearer has said they
    /// want to instruct the agent, and the instruction itself is dictated next.
    ///
    /// Whole runs rather than the bare word "instruction", because the bare word is also
    /// how a wearer refers to one that already exists ("repeat the instruction") and a
    /// grammar that opened dictation on it would put the window into a flow the wearer
    /// only mentioned.
    private static let instructionOpeners: [String] = [
        "new instruction", "new instructions",
        "instruction for you", "instructions for you",
        "instruction for claude", "instructions for claude",
        "instruction for the agent", "instructions for the agent",
    ]

    /// Prefixes whose remainder *is* the instruction, so the wearer can dictate in one
    /// breath. The agent is named explicitly ("it", "Claude", "the agent") — "tell me" is
    /// the details command and stays that way.
    private static let instructionPrefixes: [String] = [
        "tell it to", "tell claude to", "tell the agent to",
    ]

    /// Words that follow "tell" without naming an agent, so "tell ⟨word⟩ to …" is not an
    /// address. "me" is here because "tell me more" is the details command; the pronouns
    /// because "tell it to …" is the prefix above and must keep being stripped as one.
    ///
    /// This grammar deliberately does not know which agents exist — that is a fact about
    /// what is connected right now, which lives in the runtime and changes inside a run.
    /// All this rule decides is that a *name* was spoken; whether anything answers to it is
    /// settled later, out loud, by the dictation flow.
    private static let unaddressedFollowers: Set<String> = [
        "it", "me", "him", "her", "them", "us", "you", "the", "this", "that",
        "everyone", "somebody", "someone",
    ]

    /// The dictation branch: the earliest trigger in the transcript, if one survives the
    /// negation guard, plus whatever text follows a capturing prefix.
    ///
    /// The captured text is taken from `raw` rather than rebuilt from the matched words:
    /// what the wearer dictated is what the agent should be asked to do, in their own
    /// casing and punctuation, not in the apostrophe-stripped lowercase this grammar
    /// compares on. `nil` text means the flow opens and waits for the sentence.
    ///
    /// One trigger captures from its *own* first word rather than from the word after it:
    /// "tell ⟨name⟩ to …", where ⟨name⟩ is a word this grammar does not already handle.
    /// The address has to survive into the captured text because only the runtime knows
    /// which agents are live, and a prefix stripped here would have thrown the name away
    /// before anyone could resolve it.
    private static func beginInstruction(
        in raw: String,
        tokens: [(word: String, range: Range<String.Index>)]
    ) -> VoiceCommand? {
        let words = tokens.map(\.word)
        /// `captureFrom` is the token index the instruction text starts at, or `nil` for a
        /// trigger that opens the flow without supplying any.
        var best: (start: Int, captureFrom: Int?)?
        func consider(_ start: Int, captureFrom: Int?) {
            // Strictly earlier wins, so a tie at the same word keeps the trigger that was
            // considered first — which is what makes the addressed rule below a fallback
            // for names the explicit prefixes do not already cover.
            guard best.map({ start < $0.start }) ?? true else { return }
            best = (start, captureFrom)
        }
        func consider(_ run: String, capturing: Bool) {
            guard let start = firstIndex(ofRun: run, in: words) else { return }
            let end = start + run.split(separator: " ").count
            consider(start, captureFrom: capturing ? end : nil)
        }
        for run in instructionPrefixes { consider(run, capturing: true) }
        for run in instructionOpeners { consider(run, capturing: false) }
        if let addressed = firstAddressedInstruction(in: words) {
            consider(addressed, captureFrom: addressed)
        }
        guard let match = best else { return nil }
        guard Set(words[..<match.start]).isDisjoint(with: negationWords) else { return nil }
        guard let captureFrom = match.captureFrom, captureFrom < tokens.count else {
            return .beginInstruction(nil)
        }
        let text = raw[tokens[captureFrom].range.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .beginInstruction(text.isEmpty ? nil : text)
    }

    /// Where "tell ⟨name⟩ to ⟨something⟩" begins, or `nil` when the transcript has no such
    /// run.
    ///
    /// Three words and a fourth, all required. "Tell" alone would swallow "tell me more";
    /// the trailing "to" is what separates an address from a sentence that merely opens
    /// with the word; and the fourth word is the instruction, without which there is
    /// nothing to route.
    private static func firstAddressedInstruction(in words: [String]) -> Int? {
        guard words.count >= 4 else { return nil }
        for start in 0...(words.count - 4) where words[start] == "tell" {
            guard !unaddressedFollowers.contains(words[start + 1]) else { continue }
            guard words[start + 2] == "to" else { continue }
            return start
        }
        return nil
    }

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
    /// Lowercased words in spoken order with apostrophes removed, each paired with where
    /// it sits in the *original* string.
    ///
    /// The pairing has one caller: dictation captures the rest of the sentence after
    /// "tell it to" as instruction text, and that text is going to a language model, not
    /// to this grammar — it should be the words the wearer actually said, in their own
    /// casing and punctuation. Scanning the original rather than a lowercased copy is what
    /// keeps those ranges usable: lowercasing is not length-preserving for every scalar,
    /// so an index taken from the copy is not an index into the string the caller holds.
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
    private static func tokens(in raw: String) -> [(word: String, range: Range<String.Index>)] {
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || apostrophes.contains(character)
        }
        var result: [(word: String, range: Range<String.Index>)] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            guard isWordCharacter(raw[index]) else {
                index = raw.index(after: index)
                continue
            }
            let start = index
            while index < raw.endIndex, isWordCharacter(raw[index]) {
                index = raw.index(after: index)
            }
            let word = raw[start ..< index].lowercased().filter { !apostrophes.contains($0) }
            if !word.isEmpty { result.append((word, start ..< index)) }
        }
        return result
    }

    /// Whether `words` holds the space-separated `run` as consecutive whole words.
    private static func contains(run: String, in words: [String]) -> Bool {
        firstIndex(ofRun: run, in: words) != nil
    }

    /// Where `run` starts in `words`, as an index into `words`, or `nil` when it is absent.
    private static func firstIndex(ofRun run: String, in words: [String]) -> Int? {
        let needle = run.split(separator: " ").map(String.init)
        guard !needle.isEmpty, words.count >= needle.count else { return nil }
        return (0...(words.count - needle.count)).first { start in
            words[start ..< (start + needle.count)].elementsEqual(needle)
        }
    }
}
