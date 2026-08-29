import Foundation

/// What came back when TapQ was asked a question about an agent's work.
///
/// It lives in contracts because the two halves of the answer path are in different
/// baselines and must not depend on each other: the interaction layer owns the tool call
/// and the speaking, the context layer owns the transcript and the model call, and this is
/// the only vocabulary they share.
///
/// The three cases are the whole failure posture of `ask_about_work`, ratified
/// 2026-08-28 (`docs/TRANSCRIPT_CONTEXT_PLAN.md`), and the line between the last two is
/// the load-bearing part:
///
/// - ``answered(_:)`` — spoken verbatim on the scripted channel, like every other TapQ
///   sentence.
/// - ``unavailable(_:)`` — the transcript could not be read: a missing path, a parse
///   failure, permissions. **Not** a voice break. The voice pipe is intact and killing a
///   session over a rotated file would be disproportionate, so TapQ says out loud that it
///   cannot see the session's history and the session stays alive.
/// - ``failed(_:)`` — the cloud call failed: HTTP error, timeout, refusal, a response that
///   did not decode. Same model family and endpoint as narration, so the same posture —
///   the run's voice breaks. There is deliberately no half-answer: a summary assembled
///   locally out of slices would be TapQ inventing an answer about the wearer's work.
public enum WorkQuestionOutcome: Sendable, Equatable {
    /// The answer, in the words the model wrote. Spoken word for word.
    case answered(String)
    /// Session history is not visible, and this is the sentence saying so.
    case unavailable(String)
    /// The cloud call failed. Carries an operator-facing reason — never wearer speech,
    /// never agent output, never the key — for the diagnostic and the break notice.
    case failed(String)
}
