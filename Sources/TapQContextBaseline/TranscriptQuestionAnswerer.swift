import Foundation
import TapQContracts

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

    /// The seam the voice provider calls. Never throws: every failure is one of the two
    /// outcomes above, because a thrown error at a tool call is a peer left parked.
    public func answer(question: String, agentDisplayName: String?) async -> WorkQuestionOutcome {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record("ask.requested", fields: [
            "question_length": "\(question.count)",
            "agent_named": "\(agentDisplayName?.isEmpty == false)",
        ])
        guard !question.isEmpty else {
            return unavailable(.empty, notice: Self.emptyNotice)
        }
        guard let session = resolveSession(agentDisplayName) else {
            return unavailable(.notAttached, notice: Self.notAttachedNotice)
        }

        var entries: [TranscriptEntry]
        switch store.entries(session: session) {
        case .success(let read):
            entries = read
        case .failure(let reason):
            return unavailable(reason, notice: Self.notice(for: reason))
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
            return unavailable(.empty, notice: Self.emptyNotice)
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
