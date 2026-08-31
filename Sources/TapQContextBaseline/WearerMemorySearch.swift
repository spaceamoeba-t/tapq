import Foundation

/// Per-question retrieval over TapQ's own memory — the half of Pillar A that M1 deferred to
/// the loop (`docs/TAPQ_AGENT_PLAN.md`: "older history is retrieved per-question inside the
/// loop, same slicing approach as transcripts").
///
/// **Why it is not the recent window.** ``WearerConversationRecall`` renders the last dozen
/// entries into the realtime model's per-turn grounding, unranked, so that "the thing I
/// asked you earlier" resolves. That window is deliberately blind to the question — it is
/// built before anyone has asked one. This is the other direction: a query exists, and what
/// matters is the entry from three days ago, not the twelve from three minutes ago.
///
/// **Same slicing approach as transcripts, with the priorities reversed.**
/// ``TranscriptSliceSelection`` takes the newest entries *first* because a wearer asking
/// about an agent's work almost always means what just happened. Here relevance goes first
/// and recency only breaks ties, because the loop is being asked about the past — the
/// present is already in the grounding the realtime session carries. The keyword extraction
/// is literally shared, so "what did I tell Codex about the migration?" hangs on the same
/// words in both pillars.
///
/// No embeddings, for the reason phase 1 of the transcript plan gives: the answer model
/// reads generous excerpts happily, and an index would be a second thing to keep in sync
/// with a file that rewrites itself at every rotation.
///
/// Deterministic — same entries and same query in, same characters out. Nothing here calls a
/// model, so what the loop is told about the wearer's history is reproducible and cannot be
/// confused with something a model invented.
public enum WearerMemorySearch {
    /// The most entries one search may return. Twenty is a couple of screens of dialogue
    /// read aloud — far more than any answer needs, and small enough that a query matching
    /// half the file does not spend the loop's whole turn.
    public static let matchLimit = 20
    /// The whole result's character budget. Generous next to the recent window's 1,200,
    /// because this text is read once by a model rather than carried on every turn of a live
    /// conversation.
    public static let characterBudget = 6_000
    /// What comes back when nothing matched. A sentence rather than an empty string: the
    /// model has to be able to tell "TapQ has no record of that" from "the tool returned
    /// nothing", and only the first of those is an answer it can honestly speak.
    public static let noMatchesText =
        "Nothing in TapQ's memory of its conversation with the wearer matches that."
    /// What comes back when the record itself is empty — a first run, or a wearer who has
    /// just cleared it.
    public static let emptyMemoryText =
        "TapQ has no recorded conversation with the wearer yet."

    /// One retrieved entry and why it was picked, for tests and diagnostics. The loop only
    /// ever sends ``Result/text``.
    public struct Match: Sendable, Equatable {
        /// The entry's position in the record, 1-based and oldest-first, so a diagnostic can
        /// say *which* entries were used without quoting one.
        public let index: Int
        /// How many of the query's words this entry contains. Zero for a recency fallback.
        public let score: Int
        public let line: String

        public init(index: Int, score: Int, line: String) {
            self.index = index
            self.score = score
            self.line = line
        }
    }

    public struct Result: Sendable, Equatable {
        public let matches: [Match]
        /// The rendered block the loop hands the model.
        public let text: String
        /// How many retained entries were not returned. Counts only — the diagnostics rule
        /// is that what was left out is reported by number, never by content.
        public let droppedEntries: Int

        public init(matches: [Match], text: String, droppedEntries: Int) {
            self.matches = matches
            self.text = text
            self.droppedEntries = droppedEntries
        }
    }

    /// Searches `entries` (oldest first, as the store hands them over) for `query`.
    ///
    /// - Parameters:
    ///   - now: the clock, so each line can say how long ago it was. Injected because a
    ///     relative timestamp is the one part of this that is not a pure function of the
    ///     file, and a test that could not fix it would be a test of the calendar.
    public static func search(
        entries: [WearerDialogueEntry],
        query: String,
        now: Date,
        limit: Int = WearerMemorySearch.matchLimit,
        budget: Int = WearerMemorySearch.characterBudget
    ) -> Result {
        guard !entries.isEmpty else {
            return Result(matches: [], text: emptyMemoryText, droppedEntries: 0)
        }
        guard limit > 0, budget > 0 else {
            return Result(matches: [], text: noMatchesText, droppedEntries: entries.count)
        }

        let keywords = TranscriptSliceSelection.keywords(in: query)
        let numbered = entries.enumerated().map { (index: $0.offset + 1, entry: $0.element) }

        // A query with nothing to match *on* — "what was I doing?", or a question whose
        // every word is a stop word — is not a miss. It is a request for the recent past,
        // and answering it with "nothing matches" would be TapQ pretending not to remember a
        // conversation it has on disk.
        //
        // A query with real words that matched nothing is the opposite, and the line between
        // them is load-bearing: handing back the most recent entries for "kubernetes
        // ingress" would give the model a page of unrelated dialogue to answer from, which
        // is exactly how a loop invents a memory. Nothing matched, and that is the answer.
        let usedRecencyFallback = keywords.isEmpty
        let ranked: [(index: Int, entry: WearerDialogueEntry, score: Int)]
        if usedRecencyFallback {
            ranked = numbered.suffix(limit).reversed().map {
                (index: $0.index, entry: $0.entry, score: 0)
            }
        } else {
            // Relevance first, newest breaking ties — the mirror image of the transcript
            // selector, and the reason is in this type's doc comment.
            ranked = numbered
                .map { (index: $0.index, entry: $0.entry, score: score($0.entry, keywords)) }
                .filter { $0.score > 0 }
                .sorted { ($0.score, $0.index) > ($1.score, $1.index) }
        }

        var matches: [Match] = []
        var spent = 0
        for candidate in ranked {
            guard matches.count < limit else { break }
            let line = self.line(for: candidate.entry, index: candidate.index, now: now)
            guard spent + line.count <= budget else { continue }
            spent += line.count
            matches.append(Match(index: candidate.index, score: candidate.score, line: line))
        }

        guard !matches.isEmpty else {
            return Result(matches: [], text: noMatchesText, droppedEntries: entries.count)
        }
        // Rendered oldest first, whatever order they ranked in: the model is reading a
        // conversation, and a conversation read backwards says different things.
        let ordered = matches.sorted { $0.index < $1.index }
        var rendered = [heading(usedRecencyFallback: usedRecencyFallback, count: ordered.count)]
        rendered.append(contentsOf: ordered.map(\.line))
        return Result(
            matches: ordered,
            text: rendered.joined(separator: "\n"),
            droppedEntries: entries.count - ordered.count
        )
    }

    static func heading(usedRecencyFallback: Bool, count: Int) -> String {
        usedRecencyFallback
            ? "No word in the query matched, so here are the \(count) most recent entries "
                + "from TapQ's conversation with the wearer, oldest first:"
            : "\(count) matching entries from TapQ's conversation with the wearer, oldest "
                + "first. This is TapQ's own memory, not any agent's session:"
    }

    /// One entry as the model reads it: when, then what.
    ///
    /// The rendering itself is ``WearerConversationRecall/line(for:)`` — the same one the
    /// grounding window uses, deliberately, so an entry does not read as two different facts
    /// depending on which pillar surfaced it. What is added is the age, because a retrieved
    /// entry has been pulled out of its order in time and "you approved that" means something
    /// different at ten minutes and at ten days.
    static func line(for entry: WearerDialogueEntry, index: Int, now: Date) -> String {
        "  \(index). [\(age(of: entry.timestamp, now: now))] "
            + WearerConversationRecall.line(for: entry)
    }

    /// A spoken-shaped relative age. Coarse on purpose: the loop may read this out, and
    /// "yesterday" is what a person says where a timestamp would say 19 hours.
    static func age(of timestamp: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(timestamp)
        guard seconds >= 0 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    /// How many of the query's words this entry carries, over every field that holds
    /// language: the utterance, the decision's outcome, the agent's name, the tool's.
    ///
    /// All four, because a wearer's question routinely hangs on the one that is not the
    /// text — "what did I tell Codex?" matches on the agent, "did I approve the Bash one?"
    /// on the tool.
    static func score(_ entry: WearerDialogueEntry, _ keywords: Set<String>) -> Int {
        guard !keywords.isEmpty else { return 0 }
        let haystack = [entry.text, entry.outcome, entry.agentDisplayName, entry.toolName]
            .joined(separator: " ")
            .lowercased()
        return keywords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }
}
