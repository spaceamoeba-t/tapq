import Foundation

/// Which parts of a session's history are handed to the answer model, and what was left
/// out.
///
/// No embeddings, deliberately (`docs/TRANSCRIPT_CONTEXT_PLAN.md` phase 1): the answer
/// model reads generous slices happily, and an index would be a second thing to keep in
/// sync with a file that rewrites itself. What is here instead is two rules —
///
/// 1. **Recency wins.** The newest entries are always taken, because the overwhelming
///    majority of what a wearer asks about is what just happened ("what did the tests
///    say?").
/// 2. **Then relevance, for the rest of the budget.** Older entries are ranked by how many
///    of the question's own words they contain, so "what did you decide about the
///    migration?" can reach back past the last twenty lines.
///
/// — and one budget, because a 100k-character answer prompt is generous and a 10MB one is a
/// timeout. Everything dropped is counted and reported; nothing dropped is ever quoted.
public enum TranscriptSliceSelection {
    /// The per-answer cap from the plan.
    public static let defaultCharacterBudget = 100_000
    /// How many of the newest entries are taken before relevance is consulted at all.
    public static let recencyFloor = 20

    /// Appended to the newest entry when it is a tool call the agent has had no result for.
    ///
    /// Live on 2026-09-04 the answer model read a session whose last line was a `Write`
    /// call parked on the wearer's approval, and answered "Claude finished writing the
    /// script" out of the script's source in that call's input. From the transcript alone
    /// a call with no result after it is indistinguishable from one whose result has not
    /// been written yet; this note is the difference, stated where the model reads it.
    public static let waitingOnToolCallNote =
        "[This call has no result yet: the agent is waiting on it — usually on the "
        + "wearer's approval — and the work it describes is not done.]"

    /// An assistant line that asked for a tool and has not heard back.
    static func isUnansweredToolCall(_ entry: TranscriptEntry) -> Bool {
        entry.role == .assistant && !(entry.toolName ?? "").isEmpty && entry.toolOutput == nil
    }
    /// The most one entry may spend. A single `cat` of a lock file must not evict the
    /// twenty lines around it; the rest of that entry is reported as dropped characters.
    public static let entryCharacterCap = 8_000
    /// Words too short or too common to say anything about relevance. Deliberately tiny:
    /// three-letter technical words ("npm", "git", "CI") are exactly what a wearer's
    /// question hangs on, so the floor is length, not a dictionary.
    static let stopWords: Set<String> = [
        "the", "and", "was", "were", "did", "does", "what", "when", "why", "how", "you",
        "your", "that", "this", "there", "with", "for", "from", "about", "into", "have",
        "has", "had", "are", "any", "all", "just", "then", "than", "them", "they", "its",
        "our", "out", "get", "got", "say", "said", "tell", "told", "can", "could", "would",
        "should", "please", "hey", "tapq",
    ]

    public struct Result: Sendable, Equatable {
        public let slices: [WorkQuestionSlice]
        /// How many entries did not fit. Counts only — the plan's diagnostics rule is that
        /// what was dropped is reported by number and length, never by content.
        public let droppedEntries: Int
        /// How many characters those entries would have contributed, plus whatever was
        /// trimmed off entries that were kept but capped.
        public let droppedCharacters: Int

        public init(slices: [WorkQuestionSlice], droppedEntries: Int, droppedCharacters: Int) {
            self.slices = slices
            self.droppedEntries = droppedEntries
            self.droppedCharacters = droppedCharacters
        }
    }

    public static func select(
        entries: [TranscriptEntry],
        question: String,
        budget: Int = TranscriptSliceSelection.defaultCharacterBudget,
        recencyFloor: Int = TranscriptSliceSelection.recencyFloor,
        entryCap: Int = TranscriptSliceSelection.entryCharacterCap
    ) -> Result {
        guard !entries.isEmpty, budget > 0 else {
            return Result(slices: [], droppedEntries: entries.count,
                          droppedCharacters: entries.reduce(0) { $0 + $1.length })
        }
        let keywords = self.keywords(in: question)
        // 1-based, so a diagnostic and the model's own "excerpt 7" agree with each other.
        let numbered = entries.enumerated().map { (index: $0.offset + 1, entry: $0.element) }

        var kept: [Int: String] = [:]
        var trimmed = 0
        var spent = 0

        let lastIndex = numbered.count
        func take(_ index: Int, _ entry: TranscriptEntry) -> Bool {
            guard kept[index] == nil else { return true }
            var (text, dropped) = cap(entry.rendered, at: entryCap)
            if index == lastIndex, Self.isUnansweredToolCall(entry) {
                text += "\n" + waitingOnToolCallNote
            }
            guard spent + text.count <= budget else { return false }
            kept[index] = text
            spent += text.count
            trimmed += dropped
            return true
        }

        // Recency first, newest backwards, so a budget that runs out loses the oldest of
        // the recent window rather than the newest.
        for (index, entry) in numbered.suffix(max(0, recencyFloor)).reversed() {
            _ = take(index, entry)
        }

        // Then relevance over everything else, best first, newer entries breaking ties.
        if !keywords.isEmpty {
            let scored = numbered
                .filter { kept[$0.index] == nil }
                .map { (index: $0.index, entry: $0.entry, score: score($0.entry, keywords)) }
                .filter { $0.score > 0 }
                .sorted { ($0.score, $0.index) > ($1.score, $1.index) }
            for candidate in scored {
                // Not `break`: a later, smaller entry may still fit where this one did not,
                // and skipping it would leave budget unspent for no reason.
                _ = take(candidate.index, candidate.entry)
            }
        }

        let slices = kept.keys.sorted().map { WorkQuestionSlice(index: $0, text: kept[$0] ?? "") }
        let droppedEntries = numbered.filter { kept[$0.index] == nil }
        return Result(
            slices: slices,
            droppedEntries: droppedEntries.count,
            droppedCharacters: droppedEntries.reduce(0) { $0 + $1.entry.length } + trimmed
        )
    }

    /// Truncates one entry, saying how much was removed. The marker is inside the text the
    /// model reads, so it cannot mistake a cut for the end of the output.
    static func cap(_ text: String, at limit: Int) -> (String, Int) {
        guard limit > 0, text.count > limit else { return (text, 0) }
        let dropped = text.count - limit
        return (String(text.prefix(limit)) + "\n…[\(dropped) characters not shown]", dropped)
    }

    static func keywords(in question: String) -> Set<String> {
        let words = question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "/" })
            .map(String.init)
        return Set(words.filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    static func score(_ entry: TranscriptEntry, _ keywords: Set<String>) -> Int {
        let haystack = entry.searchText
        return keywords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }
}
