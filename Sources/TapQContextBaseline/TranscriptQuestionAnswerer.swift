import Foundation
import TapQContracts

/// The evidence half of an answer: which parts of a session's history were selected, or why
/// none could be.
///
/// It exists because milestone M2 split the one thing `ask_about_work` used to do into two.
/// The retrieval — resolve the session, read the tail, re-read the file if the tail was
/// saturated, select slices, map every way that can fail onto the sentence TapQ says — is
/// Pillar B's, and the deliberation loop needs exactly that and nothing else: it writes the
/// answer itself, out of these slices *and* whatever `search_memory` returned, which is the
/// whole point of the fold-in. The model call that used to follow immediately is now one
/// caller of this rather than the only path to it.
public enum TranscriptExcerpts: Sendable, Equatable {
    /// Slices in the order they happened, with what did not fit reported by count.
    case selected(slices: [WorkQuestionSlice], droppedEntries: Int, droppedCharacters: Int)
    /// No history to answer from, and the sentence saying so. Never a voice break.
    case unavailable(reason: TranscriptUnavailability, notice: String)

    /// Selected slices as a tool result the loop's model reads.
    ///
    /// The same excerpt framing ``WorkAnswerContract/input(for:)`` uses — numbered, oldest
    /// first, fenced, and explicit that the excerpts may not be contiguous — because a model
    /// reading history it did not fetch has to be able to tell a gap from an ending. What is
    /// left out is the question: the loop already has it, and repeating it inside a tool
    /// result would tell the model it had been asked twice.
    public static func rendered(
        slices: [WorkQuestionSlice],
        agentDisplayName: String?
    ) -> String {
        var lines: [String] = []
        if let agent = agentDisplayName, !agent.isEmpty {
            lines.append("Agent: \(agent)")
        }
        lines.append("Session history, oldest first (\(slices.count) excerpts, not "
            + "necessarily contiguous):")
        for slice in slices {
            lines.append("--- excerpt \(slice.index)")
            lines.append(slice.text)
        }
        lines.append("--- end of history")
        return lines.joined(separator: "\n")
    }
}

/// Answers `ask_about_work`: reads the session's transcript, selects slices, asks the
/// narration-family model, and hands back the sentence TapQ will speak.
///
/// It is the join between the two halves of Pillar B and holds the failure line between
/// them (`docs/TRANSCRIPT_CONTEXT_PLAN.md`):
///
/// - a transcript that cannot be read is ``WorkQuestionOutcome/unavailable(_:)`` — spoken,
///   logged at error level, and *not* a voice break. The pipe is fine; a rotated file is
///   not a reason to end the wearer's session.
/// - a cloud call that fails is ``WorkQuestionOutcome/failed(_:)`` — TapQ says nothing and
///   the caller breaks the run's voice, the same latch narration reaches. There is no
///   half-answer assembled from the slices, because that would be TapQ inventing an answer
///   about the wearer's work.
///
/// Diagnostics carry lengths and counts only: never a question, never an excerpt, never
/// agent output, never the key.
@MainActor public final class TranscriptQuestionAnswerer {
    /// Spoken when no hook has told TapQ where this session's transcript is — an agent
    /// whose shim predates the field, or a session TapQ has not seen an event from yet.
    public static let notAttachedNotice =
        "I can't see that session's history, so I can't answer that."
    /// Spoken when the path is known but the file will not open: deleted, moved, or
    /// unreadable.
    public static let unreadableNotice =
        "I can't read the session history right now, so I can't answer that."
    /// Spoken when the file opened and there was nothing legible in it.
    public static let emptyNotice =
        "There's nothing in that session's history I can read yet."

    private let store: TranscriptStore
    private let model: any WorkQuestionAnswering
    private let characterBudget: Int
    private let resolveSession: @MainActor (String?) -> String?
    private let diagnostics: TapQDiagnosticEmitter

    /// - Parameter resolveSession: turns the agent name the wearer used, if any, into the
    ///   session whose transcript answers the question. The default ignores the name and
    ///   uses the session TapQ has most recently read from, which is exact with one agent
    ///   connected — the shipping case — and is where rung F's roster will plug in when
    ///   several are. Naming an agent TapQ cannot route to therefore answers about the
    ///   active session rather than refusing; that is an M1 limitation, recorded here and
    ///   in the plan.
    public init(
        store: TranscriptStore,
        model: any WorkQuestionAnswering,
        characterBudget: Int = TranscriptSliceSelection.defaultCharacterBudget,
        resolveSession: (@MainActor (String?) -> String?)? = nil,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.store = store
        self.model = model
        self.characterBudget = characterBudget
        self.resolveSession = resolveSession ?? { [store] _ in store.mostRecentlyActiveSession() }
        self.diagnostics = TapQDiagnosticEmitter(category: "Transcript", sink: diagnosticSink)
    }

    /// Pillar B retrieval on its own: session resolution, the tail, the on-demand re-read,
    /// slice selection, and the three unavailability sentences — everything except the model
    /// call.
    ///
    /// Its own method because M2's deliberation loop needs exactly this and writes the answer
    /// itself. Extracted rather than reimplemented, so the loop's `read_transcript` and the
    /// direct path below cannot drift on which session a question is about or on what a
    /// rotated file sounds like.
    public func excerpts(question: String, agentDisplayName: String?) -> TranscriptExcerpts {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return .unavailable(reason: .empty, notice: Self.emptyNotice)
        }
        guard let session = resolveSession(agentDisplayName) else {
            return .unavailable(reason: .notAttached, notice: Self.notAttachedNotice)
        }

        var entries: [TranscriptEntry]
        switch store.entries(session: session) {
        case .success(let read):
            entries = read
        case .failure(let reason):
            return .unavailable(reason: reason, notice: Self.notice(for: reason))
        }
        // A saturated tail means there is older history on disk, and the wearer may be
        // asking about it. This is the on-demand re-read: one bounded pass over the file,
        // taken only when the bound was actually reached, so an ordinary session pays
        // nothing for it.
        if entries.count >= store.tailLimit,
           case .success(let wider) = store.reread(session: session),
           wider.count > entries.count {
            entries = wider
        }

        let selection = TranscriptSliceSelection.select(
            entries: entries, question: question, budget: characterBudget
        )
        guard !selection.slices.isEmpty else {
            return .unavailable(reason: .empty, notice: Self.emptyNotice)
        }
        return .selected(
            slices: selection.slices,
            droppedEntries: selection.droppedEntries,
            droppedCharacters: selection.droppedCharacters
        )
    }

    /// The direct M1 answer path: retrieve, ask the model, hand back a sentence.
    ///
    /// Never throws: every failure is one of the two outcomes above, because a thrown error
    /// at a tool call is a peer left parked.
    ///
    /// Composed on the `.openaiRealtime` branch through M1; from M2 the composition routes
    /// `ask_about_work` through ``WearerTaskLoop/answerWorkQuestion(question:agentDisplayName:)``
    /// instead, which reaches the same store through ``excerpts(question:agentDisplayName:)``.
    /// Kept, not deleted: it is the one-call shape of this question, it is what the
    /// composition falls back to if the loop is ever unwired, and its tests are the
    /// specification of the three outcomes.
    public func answer(question: String, agentDisplayName: String?) async -> WorkQuestionOutcome {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record("ask.requested", fields: [
            "question_length": "\(question.count)",
            "agent_named": "\(agentDisplayName?.isEmpty == false)",
        ])
        let selection: TranscriptSliceSelection.Result
        switch excerpts(question: question, agentDisplayName: agentDisplayName) {
        case let .unavailable(reason, notice):
            return unavailable(reason, notice: notice)
        case let .selected(slices, droppedEntries, droppedCharacters):
            selection = TranscriptSliceSelection.Result(
                slices: slices,
                droppedEntries: droppedEntries,
                droppedCharacters: droppedCharacters
            )
        }
        if selection.droppedEntries > 0 || selection.droppedCharacters > 0 {
            diagnostics.record("ask.dropped", fields: [
                "entries": "\(selection.droppedEntries)",
                "chars": "\(selection.droppedCharacters)",
            ])
        }

        let started = ContinuousClock.now
        do {
            let answer = try await model.answer(WorkQuestionRequest(
                question: question,
                agentDisplayName: agentDisplayName,
                slices: selection.slices
            ))
            diagnostics.record("ask.answered", fields: [
                "latency_ms": Self.milliseconds(from: started),
                "slices": "\(selection.slices.count)",
                "length": "\(answer.count)",
            ])
            return .answered(answer)
        } catch {
            let reason = (error as? NarrationFailure)?.reason ?? "unknown"
            // Error, not warning: the wearer asked a question and is going to be told the
            // voice channel is broken instead of hearing an answer.
            diagnostics.record("ask.failed", level: .error, fields: [
                "latency_ms": Self.milliseconds(from: started),
                "slices": "\(selection.slices.count)",
                "reason": reason,
            ])
            return .failed(reason)
        }
    }

    private func unavailable(
        _ reason: TranscriptUnavailability, notice: String
    ) -> WorkQuestionOutcome {
        // The store records this too, where it can say which session; recorded again here
        // because this is the one that corresponds to a wearer standing there having asked.
        diagnostics.record("transcript.unavailable", level: .error,
                           fields: ["reason": reason.rawValue])
        return .unavailable(notice)
    }

    private static func notice(for reason: TranscriptUnavailability) -> String {
        switch reason {
        case .notAttached: return notAttachedNotice
        case .unreadable: return unreadableNotice
        case .empty: return emptyNotice
        }
    }

    private static func milliseconds(from start: ContinuousClock.Instant) -> String {
        let components = start.duration(to: .now).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        return String(format: "%.0f", milliseconds)
    }
}
