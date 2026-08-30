import Foundation
import XCTest
import TapQCLI
import TapQContextBaseline
import TapQContracts
@testable import TapQInteractionBaseline

/// The other two Rung D legs, end to end over the real stack: a wearer-initiated command
/// window that structurally cannot resolve anything, and quiet mode changing the channel
/// without changing the record.
@MainActor
final class AttentionAndQuietE2ETests: XCTestCase {
    private let claude = AgentIdentity(id: "claude-code", displayName: "Claude Code")

    // MARK: - Attention (RD3)

    /// The simulated onset: nothing is waiting, the wearer speaks, a command window opens,
    /// and it answers "status" out loud. The arbiter, the pipeline, the voice grammar, and
    /// the gate are all the shipping implementations — only the motion samples and the
    /// transcript are generated.
    func testACommandWindowAnswersStatusBetweenRequests() async {
        let harness = DetectionPathHarness()
        let memory = ConversationMemory()
        // One request already served, so the standing responder has a session to read.
        await memory.withWindow(sessionID: "s1", agent: claude, summary: "run the tests") {}
        memory.record(
            approval: Self.request(), decision: .allow)
        memory.noteAutoAnswer()

        let controller = CommandWindowController(
            speech: harness.speech,
            arbiter: harness.inputArbiter,
            gate: InteractionGate(),
            recallResponder: memory.standingRecallResponder
        )
        let window = Task { await controller.run() }

        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the onset must have opened a listening window")
        harness.hear("status")

        let stillListening = await harness.waitForWindow(2)
        XCTAssertTrue(stillListening, "the window keeps listening")
        harness.timeouts.expire()
        let outcome = await window.value

        XCTAssertEqual(outcome.answers, 1)
        XCTAssertEqual(outcome.ignored, 0)
        XCTAssertTrue(harness.speech.said(CommandWindowController.defaultCue),
                      "the wearer hears the window open")
        // Not the in-prompt status line: nothing is waiting, and saying "Claude Code: run
        // the tests" here would report a request that has already been resolved.
        XCTAssertTrue(
            harness.speech.said("Nothing is waiting. Auto-answered 1 this session."),
            "\(harness.speech.spoken)"
        )
    }

    /// The structural guarantee, driven by a real nod: an attention window has no way to
    /// resolve an agent request. `run()` returns counters, not a `Decision`, and the intent
    /// that would have approved something is answered with one sentence instead.
    func testACommandWindowCannotApprove() async {
        let harness = DetectionPathHarness()
        let controller = CommandWindowController(
            speech: harness.speech,
            arbiter: harness.inputArbiter,
            gate: InteractionGate()
        )
        let window = Task { await controller.run() }

        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        harness.feed(TraceGenerators.doubleNod())

        let survived = await harness.waitForWindow(2)
        XCTAssertTrue(survived, "the window survives the nod and goes on listening")
        harness.timeouts.expire()
        let outcome = await window.value

        XCTAssertEqual(outcome.ignored, 1)
        XCTAssertEqual(outcome.answers, 0)
        XCTAssertTrue(harness.speech.said(CommandWindowController.nothingWaiting),
                      "\(harness.speech.spoken)")
        // The type-level half of the same claim: the outcome carries three counters and
        // there is no inhabitant of it a broker could act on.
        XCTAssertEqual(outcome, CommandWindowOutcome(answers: 0, ignored: 1, dictations: 0))
    }

    /// The wording a wearer hears is the same however they arrive at it — through the
    /// window's own refusal, or through recall answering "status" with nothing pending.
    func testTheTwoNothingWaitingSentencesAgree() async {
        XCTAssertEqual(CommandWindowController.nothingWaiting, SessionRecall.nothingWaiting)
    }

    // MARK: - Quiet output (RD5)

    /// The chokepoint, composed as the runtime composes it: record first and always, then
    /// ask the policy what to play. Under `--quiet` a notification is a cue and not a
    /// sentence, and the wearer can still ask what happened.
    func testQuietModeChimesWhileMemoryStillRecords() async {
        let chokepoint = NotificationChokepoint(quiet: true, announcementsEnabled: true)

        chokepoint.deliver(Self.notification(kind: .finished))

        XCTAssertEqual(chokepoint.cues, [.notification])
        XCTAssertTrue(chokepoint.spoken.isEmpty, "quiet mode speaks no announcement")
        XCTAssertEqual(chokepoint.memory.events(session: "s1").count, 1,
                       "the event is recorded whatever was played")
    }

    /// The bug this rung fixed, pinned: `--no-announcements` used to skip the recording as
    /// well as the sound, so a wearer who asked for silence could then ask "what changed?"
    /// and be told nothing had.
    func testSuppressedAnnouncementsAreStillRecorded() async {
        let chokepoint = NotificationChokepoint(quiet: false, announcementsEnabled: false)

        chokepoint.deliver(Self.notification(kind: .finished))

        XCTAssertTrue(chokepoint.cues.isEmpty)
        XCTAssertTrue(chokepoint.spoken.isEmpty)
        XCTAssertEqual(chokepoint.memory.events(session: "s1").count, 1)
        XCTAssertEqual(
            SessionRecall.whatChanged(chokepoint.memory.events(session: "s1").reversed()),
            "Claude Code reported the build finished."
        )
    }

    /// Both suppression flags at once, which is the combination the decoupling has to hold
    /// for: still silent, still recorded.
    func testQuietAndNoAnnouncementsTogetherStillRecord() async {
        let chokepoint = NotificationChokepoint(quiet: true, announcementsEnabled: false)

        chokepoint.deliver(Self.notification(kind: .finished))

        XCTAssertTrue(chokepoint.cues.isEmpty, "the flag is a hard gate, ahead of the cue")
        XCTAssertTrue(chokepoint.spoken.isEmpty)
        XCTAssertEqual(chokepoint.memory.events(session: "s1").count, 1)
    }

    /// With neither flag, the chokepoint is the one Rung C shipped: spoken, recorded, no
    /// cue engine anywhere in the composition.
    func testWithBothFlagsOffTheAnnouncementIsSpokenAsBefore() async {
        let chokepoint = NotificationChokepoint(quiet: false, announcementsEnabled: true)

        chokepoint.deliver(Self.notification(kind: .finished))

        XCTAssertTrue(chokepoint.cues.isEmpty)
        XCTAssertEqual(chokepoint.spoken.count, 1)
        XCTAssertEqual(chokepoint.memory.events(session: "s1").count, 1)
    }

    /// Dedupe survives the routing: a session already announced as waiting is not announced
    /// again, in either channel.
    func testAWaitingSessionIsAnnouncedOnceAndRecordedEveryTime() async {
        let chokepoint = NotificationChokepoint(quiet: true, announcementsEnabled: true)

        chokepoint.deliver(Self.notification(kind: .waitingForInput))
        chokepoint.deliver(Self.notification(kind: .waitingForInput))

        XCTAssertEqual(chokepoint.cues, [.notification], "the second wait is not news")
        XCTAssertEqual(chokepoint.memory.events(session: "s1").count, 2,
                       "both events are still in the record")
    }

    // MARK: - Fixtures

    private static func request() -> ApprovalRequest {
        ApprovalRequest(
            id: "r1", sessionID: "s1",
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            toolName: "Bash", summary: "run the tests", detail: "swift test"
        )
    }

    private static func notification(kind: AgentNotification.Kind) -> AgentNotification {
        AgentNotification(
            sessionID: "s1",
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            kind: kind,
            summary: "the build finished"
        )
    }
}

/// The runtime's `onNotification` closure, restated over the portable pieces.
///
/// The ordering is the point and is copied exactly: record, then route, then play. Anything
/// that reintroduces the old shape — consulting the flag before recording — fails here.
@MainActor
private final class NotificationChokepoint {
    let memory = ConversationMemory()
    private(set) var cues: [NotificationCue] = []
    private(set) var spoken: [String] = []
    private let policy: NotificationPolicy

    init(quiet: Bool, announcementsEnabled: Bool) {
        self.policy = NotificationPolicy(
            settings: .init(quiet: quiet, announcementsEnabled: announcementsEnabled),
            waits: memory.waitRegistry
        )
    }

    func deliver(_ notification: AgentNotification) {
        memory.record(notification: notification)
        switch policy.route(
            .agentNotification(kind: notification.kind, sessionID: notification.sessionID)
        ) {
        case .speak:
            spoken.append(notification.summary ?? "")
        case .chime(let cue):
            cues.append(cue)
        case .suppress, .deferred:
            // This harness composes no command-window presence, so the policy has nothing
            // to defer around and never returns `.deferred` here.
            break
        }
    }
}
