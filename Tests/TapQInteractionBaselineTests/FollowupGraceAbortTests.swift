import XCTest
@testable import TapQInteractionBaseline

/// The box that decides whether a dropped sentence is the one that cancels a follow-up
/// firing (M3; the defect it was written for was found reviewing the 2026-09-01 run).
///
/// `NotificationPolicy.onExpiredLoopSpeech` fires for *every* loop sentence that waits out
/// the deferral bound, and only one of them — this firing's own announcement — has anything
/// to do with this firing. Everything pinned here is about telling those apart.
///
/// Every test method is `async` for the Linux test-discovery shim, which cannot register a
/// synchronous method on a `@MainActor` suite.
@MainActor
final class FollowupGraceAbortTests: XCTestCase {
    private let announcement = "Claude Code finished — on your follow-up: rerun the tests"

    /// The reason the abort exists. The announcement never sounded, so the promise must not
    /// be acted on: a firing the wearer never heard announced breaks announce-everything.
    func testAnExpiredAnnouncementAbortsItsOwnFiring() async {
        let grace = FollowupGraceAbort()
        var aborted = 0
        grace.arm(announcement: announcement) { aborted += 1 }

        XCTAssertTrue(grace.noteExpired(announcement))
        XCTAssertEqual(aborted, 1)
        XCTAssertFalse(grace.isArmed, "an abort settles the grace")
    }

    /// The defect. A review's result, a "left work running" notice, a could-not-finish
    /// notice — any loop sentence can wait out the same bound, and under the old
    /// `{ _ in abort?() }` wiring any of them cancelled whichever firing happened to be in
    /// flight, silently, with its announcement heard perfectly well minutes earlier.
    func testAnUnrelatedExpiredSentenceLeavesTheFiringAlone() async {
        let grace = FollowupGraceAbort()
        var aborted = 0
        grace.arm(announcement: announcement) { aborted += 1 }

        XCTAssertFalse(grace.noteExpired("The nightly build went red an hour ago."))
        XCTAssertFalse(grace.noteExpired(
            "Codex left work running in the background — your follow-up is still waiting."
        ))
        XCTAssertEqual(aborted, 0, "neither sentence is this firing's business")
        XCTAssertTrue(grace.isArmed, "and the grace is still waiting on its own announcement")
    }

    /// Past the claim there is nothing to abort: the firing has already been acted on, and a
    /// sentence expiring afterwards — even the announcement's own text, routed again — must
    /// not reach into a review that is running.
    func testASettledGraceIgnoresEverythingIncludingItsOwnAnnouncement() async {
        let grace = FollowupGraceAbort()
        var aborted = 0
        grace.arm(announcement: announcement) { aborted += 1 }

        grace.settle()

        XCTAssertFalse(grace.isArmed)
        XCTAssertFalse(grace.noteExpired(announcement))
        XCTAssertEqual(aborted, 0)
    }

    /// Once, and only once. The box disarms before it runs the abort, so an abort that
    /// speaks — and so routes more loop speech that could itself expire — cannot re-enter
    /// this and cancel a promise twice.
    func testTheAbortRunsAtMostOnce() async {
        let grace = FollowupGraceAbort()
        var aborted = 0
        grace.arm(announcement: announcement) { aborted += 1 }

        XCTAssertTrue(grace.noteExpired(announcement))
        XCTAssertFalse(grace.noteExpired(announcement))
        XCTAssertEqual(aborted, 1)
    }

    /// Nothing armed is the common case — most of a run has no firing in flight — and every
    /// expiry passes through here. It answers no, and does not trap.
    func testAnExpiryWithNothingArmedIsHarmless() async {
        let grace = FollowupGraceAbort()

        XCTAssertFalse(grace.isArmed)
        XCTAssertFalse(grace.noteExpired(announcement))
    }

    /// A second firing arms over the first. One grace is in flight at a time by construction
    /// — the promise is consumed before it is announced — and the box says which one it is
    /// holding rather than keeping a stale text that could be matched later.
    func testArmingAgainReplacesWhatTheGraceIsWaitingOn() async {
        let grace = FollowupGraceAbort()
        var aborted: [String] = []
        grace.arm(announcement: announcement) { aborted.append("first") }
        grace.arm(announcement: "Codex finished — on your follow-up: review the diff") {
            aborted.append("second")
        }

        XCTAssertFalse(grace.noteExpired(announcement), "the first firing is no longer held")
        XCTAssertTrue(grace.noteExpired("Codex finished — on your follow-up: review the diff"))
        XCTAssertEqual(aborted, ["second"])
    }
}
