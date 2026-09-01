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
    /// Spoken budget for the whole fleet status line.
    public static let statusCharacterLimit = 240
    /// Budget for a wearer's question as it is handed to the model. Long enough for
    /// anything a person says in one breath, short enough that a recognizer that has
    /// run away with a nearby conversation cannot turn one question into a prompt.
    public static let questionCharacterLimit = 240
    /// What recall says when a session has no history yet (RB2).
    public static let nothingRecorded = "Nothing recorded yet."
    /// The whole of what the realtime model is told to do with a wearer's question.
    ///
    /// Deliberately narrow: answer from the given context, admit ignorance otherwise,
    /// and decide nothing. The last sentence is not decoration — the question is asked
    /// *inside* an open approval window, and a model that answered "yes, go ahead"
    /// would be speaking a sentence the wearer could mistake for TapQ's own.
    public static let answeringPreamble = """
        Answer the wearer's question in one short spoken sentence, using only the \
        context below. If the context does not answer it, say you do not know. Never \
        invent agent activity, and never approve, deny, or choose anything.
        """

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

    /// The spoken answer to "who's waiting?" (RB4).
    ///
    /// Two facts and nothing else: what the wearer is being asked right now, and how many
    /// other requests are queued behind it. Counts and display names only — a session
    /// identifier is opaque to the wearer and is never spoken.
    ///
    /// - Parameters:
    /// A third fact joins it in Rung C, and only when there is one: instructions this
    /// session has dictated but the agent has not yet reached a turn boundary to receive.
    /// They are waiting in the same sense the queued requests are — nothing has happened
    /// yet — and a wearer who dictated one and then heard a status line that did not
    /// mention it would have no way to tell it had been kept.
    ///
    /// - Parameters:
    ///   - agentDisplayName: the agent whose request is in hand.
    ///   - summary: that request's spoken summary.
    ///   - othersWaiting: requests queued behind it, never counting the one in hand. Zero
    ///     says nothing: the head has just named what is waiting, and a trailing "nothing
    ///     else waiting" was heard as contradicting it.
    ///   - instructionsQueued: instructions dictated into this session and not yet
    ///     delivered. Zero — every run without `--voice-instructions`, and every session
    ///     nobody has dictated into — says nothing at all, so the sentence is the one
    ///     Rung B pinned, word for word.
    ///   - autoAnswered: approvals the delegation filter answered on the wearer's behalf
    ///     this run (Rung D). Counted across the whole run rather than per session,
    ///     because the number answers "what has TapQ been doing while I wasn't asked?",
    ///     which is not a question about the session the wearer happens to be standing
    ///     in. Zero — every run without `--auto-answer routine` — says nothing.
    public static func status(
        agentDisplayName: String?,
        summary: String?,
        othersWaiting: Int,
        instructionsQueued: Int = 0,
        autoAnswered: Int = 0
    ) -> String {
        let name = normalizedLine(
            agentDisplayName, limit: SpokenSummary.sentenceCharacterLimit
        ) ?? "The agent"
        let head: String
        if let summary = normalizedLine(summary, limit: SpokenSummary.sentenceCharacterLimit) {
            head = name + ": " + trimmed(summary) + "."
        } else {
            head = name + " is waiting."
        }
        // The queue behind the request in hand, spoken only when there is one. The
        // original tail for an empty queue was "Nothing else waiting.", and on hardware
        // (2026-09-01) it was heard as "nothing is waiting" — the opposite of the sentence
        // it followed, which had just read out a pending approval. The head already says
        // what is waiting; an empty queue adds nothing worth a clause.
        let others = max(0, othersWaiting)
        var rest: [String] = []
        switch others {
        case 0: break
        case 1: rest.append("1 more waiting.")
        default: rest.append("\(others) more waiting.")
        }
        let queued = max(0, instructionsQueued)
        switch queued {
        case 0: break
        case 1: rest.append("1 instruction queued.")
        default: rest.append("\(queued) instructions queued.")
        }
        // Last, and only when there is something to say. An auto-answer is the one thing
        // TapQ does that the wearer was not present for, so the status line is where they
        // find out it happened at all — but it is a footnote to the request in hand, not
        // the headline, and a run with the filter off must speak Rung B's sentence exactly.
        let answered = max(0, autoAnswered)
        if answered > 0 { rest.append("Auto-answered \(answered) this session.") }
        return joined(
            first: SpokenSummaryText.truncated(head, limit: statusCharacterLimit),
            rest: rest,
            limit: statusCharacterLimit
        )
    }

    /// What recall says when the wearer opened the window themselves (RD3).
    ///
    /// A different sentence from ``status(agentDisplayName:summary:othersWaiting:)`` and not
    /// a special case of it, because the fact it leads with is the opposite one. The
    /// in-prompt line names the request in hand; there is no request in hand here — an
    /// attention window opens only when the gate is empty — so leading with the last
    /// request's summary would tell the wearer something is waiting that is not.
    ///
    /// - Parameters:
    ///   - instructionsQueued: dictations the last-served session has not received yet.
    ///   - autoAnswered: approvals the filter answered this run.
    /// - Returns: "Nothing is waiting." plus whichever of the two counts is non-zero.
    public static func standingStatus(
        instructionsQueued: Int = 0,
        autoAnswered: Int = 0
    ) -> String {
        var rest: [String] = []
        switch max(0, instructionsQueued) {
        case 0: break
        case 1: rest.append("1 instruction queued.")
        case let queued: rest.append("\(queued) instructions queued.")
        }
        let answered = max(0, autoAnswered)
        if answered > 0 { rest.append("Auto-answered \(answered) this session.") }
        return joined(first: nothingWaiting, rest: rest, limit: statusCharacterLimit)
    }

    /// What a wearer-initiated window says when nothing is pending.
    ///
    /// Deliberately the same words as `CommandWindowController.nothingWaiting`, which the
    /// window speaks when the wearer tries to answer a request that does not exist: one
    /// situation, one sentence, however the wearer arrived at it. It is restated rather
    /// than shared because that type lives in the interaction layer, which does not — and
    /// should not — depend on this one; a test in each target pins the wording.
    public static let nothingWaiting = "Nothing is waiting."

    /// The whole instruction handed to the realtime model for one grounded answer: what
    /// to do, what is known, and what was asked — in that order.
    ///
    /// Composed here rather than at the call site so the one place that decides what a
    /// model is told about a session is the same place that decides what recall says out
    /// loud, and so both are pinned by the same tests.
    ///
    /// - Returns: `nil` when the question is empty after normalization, which is the
    ///   signal to leave the transcript unanswered rather than ask a model to respond to
    ///   nothing.
    public static func groundedAnswer(question: String, digest: String) -> String? {
        guard let question = normalizedLine(question, limit: questionCharacterLimit) else {
            return nil
        }
        let context = digest.isEmpty
            ? "Context: nothing has been recorded for this session yet."
            : "Context:\n" + digest
        return [answeringPreamble, context, "Question: " + question].joined(separator: "\n")
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
        case .instructed:
            // "You told it to" and not "it did": an instruction is work handed over,
            // and recall must not imply the agent has finished — or started — it.
            return "was told to " + subject
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
