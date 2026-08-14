import Foundation

/// Turns recorded session events into the two things Rung B says out loud: the
/// "what changed" answer, and the context digest that grounds a spoken question.
///
/// Every composition here is deterministic — same events in, same characters out, no
/// model in the path — so the wearer's recall is reproducible and testable, and so a
/// digest can be shown to a model without any risk that the *recall* invented state.
/// Both compositions read only ``SessionContextEvent`` fields, which are speech-safe
/// by construction, so neither can leak `toolInput`, `cwd`, or `permissionMode`.
public enum SessionRecall {
    /// How many events "what changed" speaks (RB2). Three is what a wearer can hold
    /// in one listen.
    public static let recalledEventLimit = 3
    /// How many events the grounding digest carries. Larger than the spoken limit
    /// because the model reads it rather than hearing it.
    public static let digestEventLimit = 5
    /// Spoken budget for the whole "what changed" answer.
    public static let proseCharacterLimit = 320
    /// Budget for the whole grounding digest.
    public static let digestCharacterLimit = 600
    /// What recall says when a session has no history yet (RB2).
    public static let nothingRecorded = "Nothing recorded yet."

    /// The spoken answer to "what changed?".
    ///
    /// - Parameter events: the session's events, newest first — exactly what
    ///   ``SessionContextStore/recent(session:limit:)`` returns.
    /// - Returns: at most ``recalledEventLimit`` sentences within
    ///   ``proseCharacterLimit`` characters, or ``nothingRecorded`` when there is no
    ///   history to speak.
    public static func whatChanged(_ events: [SessionContextEvent]) -> String {
        var sentences: [String] = []
        var spokenName: String?
        for event in events.prefix(recalledEventLimit) {
            let name = displayName(of: event)
            // The agent's name is repeated only when it changes, so a single-agent
            // session reads as one voice while a shared one still says who did what.
            let clause = name == spokenName
                ? clauseSentence(for: event)
                : name + " " + clauseSentence(for: event)
            sentences.append(sentences.isEmpty ? clause : "Before that, " + clause)
            spokenName = name
        }
        guard let first = sentences.first else { return nothingRecorded }
        return joined(
            first: SpokenSummaryText.truncated(first, limit: proseCharacterLimit),
            rest: sentences.dropFirst(),
            limit: proseCharacterLimit
        )
    }

    /// The grounding context handed to the realtime model with a wearer's question.
    ///
    /// It carries only what TapQ would say out loud anyway: the open request's spoken
    /// summary and detail, plus recent resolved events. There is nothing here for the
    /// model to answer from beyond that, which is the point — an ungrounded answer
    /// about agent state is worse than no answer.
    ///
    /// - Returns: a digest within ``digestCharacterLimit`` characters, or an empty
    ///   string when there is nothing speech-safe to say.
    public static func digest(
        events: [SessionContextEvent],
        currentSummary: String? = nil,
        currentDetail: String? = nil
    ) -> String {
        var lines: [String] = []
        if let summary = normalizedLine(
            currentSummary, limit: SpokenSummary.sentenceCharacterLimit
        ) {
            lines.append("Open request: " + summary)
        }
        if let detail = normalizedLine(
            currentDetail, limit: SpokenSummary.detailCharacterLimit
        ) {
            lines.append("Request detail: " + detail)
        }

        let sentences = events.prefix(digestEventLimit).map(sentence(for:))
        if !sentences.isEmpty {
            lines.append("Recent activity, newest first: " + sentences.joined(separator: " "))
        }

        guard let first = lines.first else { return "" }
        return joined(
            first: SpokenSummaryText.truncated(first, limit: digestCharacterLimit),
            rest: lines.dropFirst(),
            separator: "\n",
            limit: digestCharacterLimit
        )
    }

    // MARK: - Composition

    /// One event as a full sentence: "Claude Code approved run npm test."
    static func sentence(for event: SessionContextEvent) -> String {
        displayName(of: event) + " " + clauseSentence(for: event)
    }

    /// The agent's spoken name, falling back to the wording every presenter already
    /// uses for an agent that never identified itself.
    private static func displayName(of event: SessionContextEvent) -> String {
        event.agentDisplayName.isEmpty ? "The agent" : event.agentDisplayName
    }

    /// The same sentence without the leading agent name, for continuation phrasing.
    private static func clauseSentence(for event: SessionContextEvent) -> String {
        clause(for: event) + "."
    }

    private static func clause(for event: SessionContextEvent) -> String {
        let subject = object(of: event)
        switch event.outcome {
        case .allowed:
            return "approved " + subject
        case .denied:
            return "denied " + subject
        case .deferred:
            return "deferred " + subject
        case let .chose(labels):
            return "chose " + list(labels) + " for " + subject
        case let .answered(text):
            return "answered " + trimmed(text) + " to " + subject
        case .noted:
            return "reported " + subject
        }
    }

    /// What the event was about, with sentence-ending punctuation removed so the
    /// composed sentence never ends "…?.".
    private static func object(of event: SessionContextEvent) -> String {
        let summary = trimmed(event.summary)
        if !summary.isEmpty { return summary }
        let tool = trimmed(event.toolName)
        return tool.isEmpty ? "a request" : tool
    }

    /// "A", "A and B", "A, B and C" — deterministic for any label count.
    private static func list(_ labels: [String]) -> String {
        let cleaned = labels.map(trimmed).filter { !$0.isEmpty }
        guard let last = cleaned.last else { return "nothing" }
        guard cleaned.count > 1 else { return last }
        return cleaned.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func trimmed(_ text: String) -> String {
        SpokenSummaryText.normalized(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:"))
    }

    /// One digest line's worth of caller-supplied text: whitespace-normalized, capped
    /// to its own budget so a single long request detail cannot crowd out the rest of
    /// the digest, and `nil` when nothing survives.
    private static func normalizedLine(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let normalized = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(text), limit: limit
        )
        return normalized.isEmpty ? nil : normalized
    }

    /// Appends whole pieces while they fit. The first piece is always kept (already
    /// truncated to the limit by the caller) so recall never answers with silence.
    private static func joined(
        first: String,
        rest: some Sequence<String>,
        separator: String = " ",
        limit: Int
    ) -> String {
        var result = first
        for piece in rest {
            let candidate = result + separator + piece
            if candidate.count > limit { break }
            result = candidate
        }
        return result
    }
}
