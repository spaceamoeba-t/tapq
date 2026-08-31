import Foundation

/// Turns the durable wearer-dialogue record into the one thing milestone M1 does with it:
/// a bounded recent window joined to the realtime model's per-turn grounding.
///
/// Deterministic — same entries in, same characters out, no model in the path — for the
/// reason ``SessionRecall`` is: what the model is told about the wearer's history must be
/// reproducible, testable, and impossible to confuse with something a model invented.
/// Every field it reads is speech-safe by construction (see ``WearerDialogueEntry``), so
/// the composed block needs no redaction pass.
///
/// M2 adds per-question retrieval over the older history; this type deliberately has no
/// opinion about that. It renders a window.
public enum WearerConversationRecall {
    /// How many entries the window may carry. Twelve is roughly the last three or four
    /// exchanges — enough for "the thing I asked you earlier" to be in it, short enough
    /// that the open question stays the most prominent thing in the prompt.
    public static let windowEntryLimit = 12
    /// The whole window's character budget, applied newest-first so what survives a tight
    /// budget is always the most recent thing said.
    public static let windowCharacterLimit = 1_200

    /// The heading the window is filed under, verbatim, so a test can pin it and a reader
    /// of the log can find it.
    ///
    /// It says three things on purpose: that this is *earlier* than the window's own
    /// brief, that it is TapQ's own memory rather than an agent's transcript, and that
    /// the tail of it may repeat the sentences the grounding lists separately as "what
    /// TapQ has just said". The overlap is real and harmless — both halves are things the
    /// wearer heard — and a model told to expect it will not read the repetition as two
    /// separate events.
    public static let heading = """
        Earlier in TapQ's conversation with the wearer, oldest first. This is TapQ's own \
        memory, kept across voice sessions and restarts; the last lines may repeat what \
        TapQ has just said.
        """

    /// The grounding block for a window, or `nil` when there is no history to state.
    ///
    /// `nil` rather than an empty string or a "nothing yet" sentence: the per-turn
    /// grounding already says what TapQ has said since the last window, and adding a line
    /// announcing an empty memory would spend prompt on the absence of a fact.
    public static func grounding(for entries: [WearerDialogueEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines = [heading]
        for (offset, entry) in entries.enumerated() {
            lines.append("  \(offset + 1). \(line(for: entry))")
        }
        return lines.joined(separator: "\n")
    }

    /// One entry as the model reads it.
    ///
    /// Wearer utterances are quoted and verbatim (ratified 2026-08-29). The quotation
    /// marks are not decoration: they are what tells the model that the words inside are
    /// the wearer's own and not TapQ describing them, which is the difference between
    /// recalling a request and paraphrasing one.
    public static func line(for entry: WearerDialogueEntry) -> String {
        switch entry.kind {
        case .wearerSaid:
            return "Wearer: \"\(entry.text)\""
        case .tapqSaid:
            return "TapQ: \(entry.text)"
        case .decision:
            return "Decision: " + decisionClause(entry)
        case .instruction:
            return entry.agentDisplayName.isEmpty
                ? "TapQ delivered an instruction: \(entry.text)"
                : "TapQ told \(entry.agentDisplayName): \(entry.text)"
        default:
            // A kind this build does not know — an M3 directive read by an M1 binary. It
            // is rendered as itself rather than dropped: a line the model can read is
            // strictly better than a hole in the history, and dropping it would make the
            // numbering lie about what is in the file.
            return entry.kind.rawValue + ": " + entry.text
        }
    }

    /// "approved Bash for Claude Code: swift test" — the subject of a decision, in the
    /// order a person says it.
    private static func decisionClause(_ entry: WearerDialogueEntry) -> String {
        var clause = entry.outcome.isEmpty ? "resolved" : entry.outcome
        if !entry.toolName.isEmpty { clause += " " + entry.toolName }
        if !entry.agentDisplayName.isEmpty { clause += " for " + entry.agentDisplayName }
        if !entry.text.isEmpty { clause += ": " + entry.text }
        return clause
    }
}
