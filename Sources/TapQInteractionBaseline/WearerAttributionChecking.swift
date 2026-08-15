import Foundation

/// Whether the voice that just spoke can be *proved* to be the wearer's.
///
/// Deliberately not a second reading of `WearerSpeechSignaling`. That protocol reports what
/// the detector believes; this one reports what a caller is allowed to act on, and the two
/// differ in exactly one state — the one where the signal is unavailable.
///
/// TapQ answers that state twice, on purpose, because the two acts it protects fail in
/// opposite directions:
///
/// - **Authorizing** fails *open*. `WearerGatedVoice` passes commands through when the
///   analyzer is absent or degraded, because the agent's own on-screen prompt is still
///   there: the worst case is a window that resolves the way it always did before
///   attribution existed. Silently dropping approvals would invent a new way for a request
///   to hang, with nothing for the wearer to see.
/// - **Instructing** fails *closed*, which is what this protocol exists for. There is no
///   backstop on that path — a queued instruction reaches the agent's session directly —
///   so "we cannot tell who spoke" and "that was not the wearer" must have the same
///   consequence. A dictation the wearer has to repeat costs a sentence; a bystander who
///   can put work into someone else's agent costs rather more.
///
/// Implemented by `WearerGatedVoice`, which already tracks the trailing window this asks
/// about. Consumers take a closure over it rather than the object, so the controllers stay
/// ignorant of where attribution comes from.
@MainActor public protocol WearerAttributionChecking: AnyObject {
    /// True only when the attribution signal is available *and* the wearer is speaking or
    /// spoke within the trailing attribution window. False whenever either half is missing,
    /// including — especially — when the signal cannot answer at all.
    var isWearerAttributedNow: Bool { get }
}
