import Foundation

/// The one in-flight follow-up announce-grace, and the thing that decides whether a dropped
/// sentence is the one that should cancel it.
///
/// M3's firing sequence is: consume the promise, say "<agent> finished — on your follow-up:
/// …" through `NotificationPolicy`, wait a short grace so a spoken cancel can retract, then
/// act. That announcement can be *held* by the deferral and, if the window never becomes a
/// legal moment inside `NotificationPolicy.maximumDeferralSeconds`, dropped unspoken. Acting
/// on a promise the wearer never heard announced would break announce-everything, so the
/// expiry aborts the firing instead — and `onExpiredLoopSpeech` is the only hook that can
/// tell the composition it happened.
///
/// **The reason this is a type and not a stored closure.** That hook fires for *every* loop
/// sentence that waits out the bound: a review's result, a "left work running" notice, a
/// could-not-finish notice. Wired as `{ _ in abort?() }` — as it was until 2026-09-01 — any
/// one of them cancelled whatever firing happened to be in flight, silently, with the wearer
/// having heard the announcement perfectly well. The two events have nothing to do with each
/// other; the only thing that makes an expiry this firing's business is the expired text
/// being this firing's own announcement. So the announcement is recorded when the grace is
/// armed and compared here, and the box is disarmed the moment the grace settles — after
/// which the firing has been claimed and no expiry may reach it at all.
@MainActor public final class FollowupGraceAbort {
    /// The sentence whose delivery this grace is waiting on. `nil` when nothing is armed.
    private var announcement: String?
    /// What to do if that sentence is never said. `nil` when nothing is armed.
    private var abort: (@MainActor () -> Void)?

    public init() {}

    /// Arms the grace for one firing.
    ///
    /// - Parameter announcement: the exact text routed through the policy. Compared by
    ///   equality, which is the only comparison available and the right one: the policy hands
    ///   an expired sentence back verbatim, and one grace is in flight at a time.
    /// - Parameter abort: cancel this firing. Run at most once, and only for `announcement`.
    public func arm(announcement: String, abort: @escaping @MainActor () -> Void) {
        self.announcement = announcement
        self.abort = abort
    }

    /// The grace is over: the delivery was claimed, or the abort has run. Disarmed either
    /// way, so a later expiry — including one carrying this same sentence — finds nothing.
    public func settle() {
        announcement = nil
        abort = nil
    }

    /// A loop sentence waited out the deferral bound and was dropped.
    ///
    /// Aborts the firing only when the dropped sentence is this firing's own announcement.
    /// Disarms before running the abort, so an abort that routes further speech cannot
    /// re-enter this and cancel twice.
    ///
    /// - Returns: whether the firing was aborted, so the caller can say so in a log. The old
    ///   shape's worst property was that it did this silently.
    @discardableResult
    public func noteExpired(_ text: String) -> Bool {
        guard let announcement, announcement == text, let abort else { return false }
        settle()
        abort()
        return true
    }

    /// Whether a grace is armed right now. Read-only; for diagnostics and tests.
    public var isArmed: Bool { abort != nil }
}
