import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Quiet-mode routing and per-session dedupe: the two decisions that stand between an
/// agent event and a sound, and neither of which may stand between an event and the
/// record of it.
@MainActor
final class NotificationPolicyTests: XCTestCase {
    private func policy(quiet: Bool = false,
                        announcements: Bool = true,
                        waits: SessionWaitRegistry? = nil) -> NotificationPolicy {
        NotificationPolicy(
            settings: .init(quiet: quiet, announcementsEnabled: announcements),
            waits: waits ?? SessionWaitRegistry()
        )
    }

    private let everyCategory: [Announcement] = [
        .agentNotification(kind: .waitingForInput, sessionID: "a"),
        .agentNotification(kind: .permissionWaiting, sessionID: "b"),
        .agentNotification(kind: .finished, sessionID: "c"),
        .requestPrompt(sessionID: "d"),
        .deferToScreen,
        .motionLost,
        .wearerInitiated,
    ]

    // MARK: - Routing table

    /// Default settings are the behavior that shipped before this type existed: TapQ says
    /// everything out loud.
    func testEveryCategoryIsSpokenByDefault() async {
        let policy = policy()
        for announcement in everyCategory {
            XCTAssertEqual(policy.route(announcement), .speak, "\(announcement)")
        }
    }

    /// The quiet routing table in one place. Attention-seeking utterances become a cue;
    /// the two cues are distinct so the wearer can tell "answer me" from "this happened".
    func testQuietModeRoutingTable() async {
        let policy = policy(quiet: true)
        let expected: [(Announcement, NotificationPolicy.Verdict)] = [
            (.agentNotification(kind: .waitingForInput, sessionID: "a"), .chime(.notification)),
            (.agentNotification(kind: .permissionWaiting, sessionID: "b"), .chime(.notification)),
            (.agentNotification(kind: .finished, sessionID: "c"), .chime(.notification)),
            (.requestPrompt(sessionID: "d"), .chime(.prompt)),
            (.deferToScreen, .chime(.notification)),
            (.motionLost, .chime(.notification)),
            (.wearerInitiated, .speak),
        ]
        for (announcement, verdict) in expected {
            XCTAssertEqual(policy.route(announcement), verdict, "\(announcement)")
        }
    }

    /// A wearer who asks a question out loud and gets a chime back has been given a worse
    /// answer than silence — they cannot tell it from a misheard question.
    func testWearerInitiatedSpeechIsNeverReducedToACue() async {
        XCTAssertEqual(policy(quiet: true).route(.wearerInitiated), .speak)
        XCTAssertEqual(policy(quiet: true, announcements: false).route(.wearerInitiated), .speak)
    }

    /// `--no-announcements` covers agent state changes, and covers exactly what it covered
    /// before: a prompt, a deferral, or a motion loss silenced by it would leave a request
    /// unanswerable.
    func testNoAnnouncementsCoversAgentStateOnly() async {
        let policy = policy(announcements: false)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "a")),
                       .suppress)
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "c")),
                       .suppress)
        XCTAssertEqual(policy.route(.requestPrompt(sessionID: "d")), .speak)
        XCTAssertEqual(policy.route(.deferToScreen), .speak)
        XCTAssertEqual(policy.route(.motionLost), .speak)
    }

    /// Both flags: silence beats a cue. The stricter instruction wins.
    func testQuietAndNoAnnouncementsSuppressAgentState() async {
        let policy = policy(quiet: true, announcements: false)
        XCTAssertEqual(policy.route(.agentNotification(kind: .permissionWaiting, sessionID: "a")),
                       .suppress)
        XCTAssertEqual(policy.route(.requestPrompt(sessionID: "a")), .chime(.prompt))
        XCTAssertEqual(policy.route(.motionLost), .chime(.notification))
    }

    // MARK: - Dedupe matrix

    func testAWaitIsAnnouncedOncePerSession() async {
        let policy = policy()
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .suppress)
        XCTAssertEqual(policy.route(.agentNotification(kind: .permissionWaiting, sessionID: "s1")),
                       .suppress, "the two waiting kinds share one slot — they are one state")
    }

    func testSessionsAreDedupedIndependently() async {
        let policy = policy()
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s2")),
                       .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s2")),
                       .suppress)
        XCTAssertTrue(policy.hasAnnounced(sessionID: "s1"))
    }

    /// A session queued at the gate is about to be spoken to directly. Announcing that it
    /// is waiting says nothing the prompt will not.
    func testASessionWaitingAtTheGateIsNotAnnounced() async {
        let waits = SessionWaitRegistry()
        let policy = policy(waits: waits)
        let token = waits.begin(sessionID: "s1", agent: .claudeCode)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .suppress)
        XCTAssertFalse(policy.hasAnnounced(sessionID: "s1"),
                       "the registry answered — nothing was announced, so nothing is marked")
        waits.end(token: token)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .speak, "the wait outlived the window that would have spoken to it")
    }

    /// Finishing ends the wait, so the next one is news again. Finishes are not themselves
    /// deduped: two finishes are two turns.
    func testFinishClearsTheMarkAndIsNeverDeduped() async {
        let policy = policy()
        _ = policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1"))
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1")), .speak)
        XCTAssertFalse(policy.hasAnnounced(sessionID: "s1"))
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1")), .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .speak)
    }

    /// Being asked is the strongest form of "already announced".
    func testAPromptSilencesTheWaitNoticeBehindIt() async {
        let policy = policy()
        XCTAssertEqual(policy.route(.requestPrompt(sessionID: "s1")), .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .suppress)
    }

    func testForgetAndResetReopenTheSlot() async {
        let policy = policy()
        _ = policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1"))
        _ = policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s2"))
        policy.forget(sessionID: "s1")
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s2")),
                       .suppress)
        policy.reset()
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s2")),
                       .speak)
    }

    /// Dedupe under quiet mode is the same dedupe: a second wait is silent, not a second
    /// chime.
    func testDedupeAppliesToChimesToo() async {
        let policy = policy(quiet: true)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .chime(.notification))
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .suppress)
    }

    // MARK: - Audio only

    /// The verdict decides what is played and nothing else. Exhaustive by the compiler: a
    /// fourth case — anything shaped like "and do not record it" — would fail to build
    /// here, which is the point of writing the switch out.
    func testEveryVerdictIsAnAudioDecision() async {
        let all: [NotificationPolicy.Verdict] = [
            .speak, .chime(.prompt), .chime(.notification), .suppress,
        ]
        var played: [String] = []
        for verdict in all {
            switch verdict {
            case .speak: played.append("speech")
            case .chime(let cue): played.append(cue.rawValue)
            case .suppress: played.append("nothing")
            }
        }
        XCTAssertEqual(played, ["speech", "prompt", "notification", "nothing"])
    }

    /// Suppressing a sound touches nothing a caller would record from, and does not
    /// disturb the wait record the status line reads.
    func testSuppressionLeavesTheWaitRecordAlone() async {
        let waits = SessionWaitRegistry()
        let policy = policy(quiet: true, announcements: false, waits: waits)
        _ = waits.begin(sessionID: "s1", agent: .codex)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput, sessionID: "s1")),
                       .suppress)
        XCTAssertEqual(waits.waitingCount, 1)
        XCTAssertEqual(waits.waitingAgentNames, ["Codex"])
    }
}
