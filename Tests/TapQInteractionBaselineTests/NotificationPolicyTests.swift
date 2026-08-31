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
            .speak, .chime(.prompt), .chime(.notification), .suppress, .deferred,
        ]
        var played: [String] = []
        for verdict in all {
            switch verdict {
            case .speak: played.append("speech")
            case .chime(let cue): played.append(cue.rawValue)
            case .suppress: played.append("nothing")
            // Still an audio decision, and still nothing about recording: "not now" is a
            // statement about when a sound is made, not about whether an event happened.
            case .deferred: played.append("nothing yet")
            }
        }
        XCTAssertEqual(played,
                       ["speech", "prompt", "notification", "nothing", "nothing yet"])
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

    // MARK: - Deferral around a command window (F10)

    /// A test double for the window: open until the test closes it.
    @MainActor
    private final class Window {
        var isOpen = false
    }

    /// Records what a diagnostic sink was told. The same double the other interaction suites
    /// use.
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }

        func fields(of name: String) -> [[String: String]] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.name == name }.map(\.fields)
        }
    }

    /// A virtual clock, so the deferral's own timing is driven rather than waited out.
    @MainActor
    private final class VirtualClock {
        private(set) var now: ContinuousClock.Instant = .now
        func advance(by seconds: TimeInterval) { now = now.advanced(by: .seconds(seconds)) }
    }

    /// Builds a policy whose deferral is fully under the test's control: the window is a
    /// flag, the clock is virtual, and every poll yields so the drain task can be stepped
    /// with `Task.yield()` instead of a real quarter-second.
    @MainActor
    private func deferringPolicy(
        window: Window,
        clock: VirtualClock,
        sink: RecordingSink,
        quiet: Bool = false,
        announcements: Bool = true,
        onExpiredLoopSpeech: NotificationPolicy.ExpiredLoopSpeechHandler? = nil
    ) -> NotificationPolicy {
        let policy = NotificationPolicy(
            settings: .init(quiet: quiet, announcementsEnabled: announcements),
            waits: SessionWaitRegistry(),
            commandWindowOpen: { window.isOpen },
            onExpiredLoopSpeech: onExpiredLoopSpeech,
            diagnosticSink: sink
        )
        policy.now = { clock.now }
        policy.sleep = { _ in await Task.yield() }
        return policy
    }

    /// Lets the drain task run until it settles. The poll sleep is a yield, so a handful of
    /// turns is more than the loop needs.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// F10(5). A `.finished` arriving during an open command window is held, not spoken into
    /// it, and it is delivered once the window closes.
    ///
    /// Spoken into the window it would be spoken at `.notification` priority: the speech gate
    /// tears the recognizer down for its playback while the window's own timer keeps running,
    /// so up to seven of eight seconds go on a sentence about a different agent and the
    /// wearer is recorded as having said nothing.
    func testAFinishDuringACommandWindowIsDeferredNotSpokenIntoIt() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)
        var played: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        let verdict = policy.route(
            .agentNotification(kind: .finished, sessionID: "s1"),
            whenDeferred: { played.append($0) }
        )

        XCTAssertEqual(verdict, .deferred)
        XCTAssertEqual(policy.deferredCount, 1)
        XCTAssertTrue(played.isEmpty, "nothing may be played into the open window")
        XCTAssertEqual(sink.fields(of: "notification.deferred").count, 1)

        window.isOpen = false
        await settle()

        XCTAssertEqual(played, [.speak], "and it is said at the next legal moment")
        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertEqual(sink.fields(of: "notification.delivered").count, 1)
    }

    /// The held verdict is the verdict that was computed, not a fresh one: under `--quiet` a
    /// deferred notification comes back as the cue it would have been.
    func testTheHeldVerdictIsTheOneThatWasComputed() async {
        let window = Window()
        let clock = VirtualClock()
        let policy = deferringPolicy(window: window, clock: clock, sink: RecordingSink(),
                                     quiet: true)
        var played: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { played.append($0) })
        window.isOpen = false
        await settle()

        XCTAssertEqual(played, [.chime(.notification)])
    }

    /// F10(6). Two finishes for the same session, both waiting out the same window, are one
    /// sentence — and the collapse is *counted*, never silent. Two finishes separated by real
    /// time are still two pieces of news; that rule is untouched, and the test above it holds.
    func testADeferredNoticeThatWentStaleIsDedupedWithADiagnostic() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)
        var played: [NotificationPolicy.Verdict] = []
        let hold: @MainActor (NotificationPolicy.Verdict) -> Void = { played.append($0) }

        window.isOpen = true
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                    whenDeferred: hold), .deferred)
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                    whenDeferred: hold), .deferred)
        XCTAssertEqual(policy.deferredCount, 1, "the stutter is collapsed")

        window.isOpen = false
        await settle()

        XCTAssertEqual(played.count, 1)
        XCTAssertEqual(sink.fields(of: "notification.dropped_stale").map { $0["reason"] },
                       ["duplicate"],
                       "dropped, and said so — a count, never a vanishing")
    }

    /// The other staleness: the wearer is now being asked a fresh question about the very
    /// session the held notice is about. A prompt is never deferred, so it overtakes the
    /// notice — which is then a sentence about the past arriving after the present.
    func testAHeldNoticeIsDroppedWhenAFreshPromptOvertakesIt() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)
        var played: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { played.append($0) })
        XCTAssertEqual(policy.route(.requestPrompt(sessionID: "s1")), .speak,
                       "a prompt is never held: the wearer has to hear it to answer it")
        XCTAssertEqual(policy.deferredCount, 0)

        window.isOpen = false
        await settle()

        XCTAssertTrue(played.isEmpty)
        XCTAssertEqual(sink.fields(of: "notification.dropped_stale").map { $0["reason"] },
                       ["superseded"])
    }

    /// A window that never closes must not hold a notice for ever, and must not eventually
    /// speak it into the window either — that is the race, only later. Dropped at the bound,
    /// counted, and the caller's own record of the event is untouched.
    func testANoticeHeldPastTheBoundIsDroppedLoudlyRatherThanSpokenLate() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)
        var played: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { played.append($0) })
        clock.advance(by: 61)
        await settle()

        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertTrue(played.isEmpty, "never spoken into the window it was held for")
        XCTAssertEqual(sink.fields(of: "notification.dropped_expired").count, 1)
    }

    /// F10(7). Outside a window nothing changes: same verdicts, same dedupe, no queue, and
    /// no diagnostics about deferral at all.
    func testNotificationsOutsideAWindowBehaveExactlyAsBefore() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)
        var played: [NotificationPolicy.Verdict] = []
        let hold: @MainActor (NotificationPolicy.Verdict) -> Void = { played.append($0) }

        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput,
                                                       sessionID: "s1"),
                                    whenDeferred: hold), .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .waitingForInput,
                                                       sessionID: "s1"),
                                    whenDeferred: hold), .suppress)
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                    whenDeferred: hold), .speak)
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                    whenDeferred: hold), .speak,
                       "two finishes apart in time are two pieces of news, as they always were")

        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertTrue(played.isEmpty, "nothing was held, so nothing is replayed")
        XCTAssertFalse(sink.names.contains { $0.hasPrefix("notification.") },
                       "no deferral bookkeeping happens outside a window: \(sink.names)")
    }

    /// A caller that offers no way to replay is not told "later": there would be no later,
    /// and losing an event quietly is the one thing this type may not do. It routes as it
    /// always did, and the compromise is recorded.
    func testACallerWithNoReplayIsNeverHandedADeferral() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: clock, sink: sink)

        window.isOpen = true
        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1")),
                       .speak)
        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertEqual(sink.fields(of: "notification.deferral_unavailable").count, 1)
    }

    /// A policy composed without a window presence — every host that has no command windows,
    /// and every test written before they existed — never defers.
    func testAPolicyWithNoWindowPresenceNeverDefers() async {
        var played: [NotificationPolicy.Verdict] = []
        let windowless = policy()
        XCTAssertEqual(windowless.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                        whenDeferred: { played.append($0) }), .speak)
        XCTAssertTrue(played.isEmpty)
    }

    /// Suppressed announcements are not held: there is no sound to keep out of the window.
    func testASuppressedNotificationIsNotDeferred() async {
        let window = Window()
        let clock = VirtualClock()
        let policy = NotificationPolicy(
            settings: .init(quiet: false, announcementsEnabled: false),
            waits: SessionWaitRegistry(),
            commandWindowOpen: { window.isOpen }
        )
        policy.now = { clock.now }
        window.isOpen = true

        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                                    whenDeferred: { _ in }), .suppress)
        XCTAssertEqual(policy.deferredCount, 0)
    }

    // MARK: - Loop speech (M3 leg 2)

    /// Nothing open, nothing to protect: a loop sentence is spoken at once and the deferral
    /// machinery is not involved at all.
    func testLoopSpeechOutsideAWindowIsSpokenImmediately() async {
        let window = Window()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: VirtualClock(), sink: sink)
        var replayed: [NotificationPolicy.Verdict] = []

        XCTAssertEqual(policy.routeLoopSpeech("The build failed on the second suite.",
                                              whenDeferred: { replayed.append($0) }), .speak)
        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertTrue(replayed.isEmpty, "nothing was held, so nothing is replayed")
        XCTAssertFalse(sink.names.contains { $0.hasPrefix("notification.") },
                       "no deferral bookkeeping outside a window: \(sink.names)")
    }

    /// The defect this entry point exists for. The loop speaks at a run-finished boundary
    /// with nobody having spoken to it — which is exactly when a command window may be open.
    /// Through its old direct path that sentence went into the window at `.notification`
    /// priority and ate the wearer's turn; through here it waits, like every other producer
    /// of unprompted speech.
    func testLoopSpeechDuringACommandWindowIsDeferredNotSpokenIntoIt() async {
        let window = Window()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: VirtualClock(), sink: sink)
        var replayed: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        let verdict = policy.routeLoopSpeech("Claude Code finished the rerun; two tests fail.",
                                             whenDeferred: { replayed.append($0) })

        XCTAssertEqual(verdict, .deferred)
        XCTAssertEqual(policy.deferredCount, 1)
        XCTAssertTrue(replayed.isEmpty, "nothing may be said into the open window")
        XCTAssertEqual(sink.fields(of: "notification.deferred").map { $0["kind"] },
                       ["loop_speech"], "one queue, and the log still says who queued")

        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, [.speak], "said at the next legal moment")
        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertEqual(sink.fields(of: "notification.delivered").count, 1)
    }

    /// One queue, because the wearer hears one sequence. A reply and the news it is about
    /// come back in the order they arrived, whichever kind each one was — two queues drained
    /// by kind would let TapQ answer a question before the question was announced.
    func testLoopSpeechAndNotificationsReplayInArrivalOrder() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink())
        var replayed: [String] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { _ in replayed.append("notice s1") })
        _ = policy.routeLoopSpeech("first loop sentence",
                                   whenDeferred: { _ in replayed.append("loop 1") })
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s2"),
                         whenDeferred: { _ in replayed.append("notice s2") })
        _ = policy.routeLoopSpeech("second loop sentence",
                                   whenDeferred: { _ in replayed.append("loop 2") })
        XCTAssertEqual(policy.deferredCount, 4)

        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, ["notice s1", "loop 1", "notice s2", "loop 2"])
    }

    /// A window that never closes must not hold a loop sentence for ever, and must not
    /// eventually say it into the window either. Dropped at the same bound as a notice — and
    /// under the same requirement, which is why it is safe: the caller recorded the outcome
    /// before routing it, so the wearer loses the sentence and not the event.
    ///
    /// The diagnostic is its own name and the drop has its own hook: "the review TapQ decided
    /// to make was never said" is a different thing to find in a log, and a different thing to
    /// act on, than a stale notice about an agent.
    func testLoopSpeechHeldPastTheBoundIsDroppedWithItsOwnDiagnosticAndHook() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        var expired: [String] = []
        let policy = deferringPolicy(window: window, clock: clock, sink: sink,
                                     onExpiredLoopSpeech: { expired.append($0) })
        var replayed: [NotificationPolicy.Verdict] = []

        window.isOpen = true
        _ = policy.routeLoopSpeech("The nightly build went red an hour ago.",
                                   whenDeferred: { replayed.append($0) })
        clock.advance(by: 61)
        await settle()

        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertTrue(replayed.isEmpty, "never said into the window it was held for")
        XCTAssertEqual(expired, ["The nightly build went red an hour ago."],
                       "handed back, so composition can record or escalate it")
        XCTAssertEqual(sink.fields(of: "notification.loop_speech_expired").count, 1)
        XCTAssertEqual(sink.fields(of: "notification.dropped_expired").count, 0,
                       "a dropped review is not filed under stale notices")
        XCTAssertFalse(sink.fields(of: "notification.loop_speech_expired")
                           .contains { $0.values.contains { $0.contains("nightly") } },
                       "the sentence goes to the hook, not into a log line")
    }

    /// The two expiries are one bound and two events. A notice and a loop sentence held out
    /// of the same never-closing window are each dropped under their own name, and only the
    /// loop sentence reaches the hook.
    func testTheTwoExpiriesAreCountedSeparately() async {
        let window = Window()
        let clock = VirtualClock()
        let sink = RecordingSink()
        var expired: [String] = []
        let policy = deferringPolicy(window: window, clock: clock, sink: sink,
                                     onExpiredLoopSpeech: { expired.append($0) })

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { _ in XCTFail("expired notices are never replayed") })
        _ = policy.routeLoopSpeech("a review nobody heard",
                                   whenDeferred: { _ in XCTFail("nor expired reviews") })
        clock.advance(by: 61)
        await settle()

        XCTAssertEqual(policy.deferredCount, 0)
        XCTAssertEqual(sink.fields(of: "notification.dropped_expired").map { $0["count"] },
                       ["1"])
        XCTAssertEqual(sink.fields(of: "notification.loop_speech_expired").count, 1)
        XCTAssertEqual(expired, ["a review nobody heard"])
    }

    /// Loop sentences are not deduped by session — there is no session, and two of them are
    /// two things TapQ decided to say. The one collapse is the literal stutter: the identical
    /// sentence already waiting out the same window. Counted, never silent.
    func testAnIdenticalLoopSentenceWaitingOutTheSameWindowIsCollapsed() async {
        let window = Window()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: VirtualClock(), sink: sink)
        var replayed: [String] = []

        window.isOpen = true
        XCTAssertEqual(policy.routeLoopSpeech("The build failed.",
                                              whenDeferred: { _ in replayed.append("a") }),
                       .deferred)
        XCTAssertEqual(policy.routeLoopSpeech("The build failed.",
                                              whenDeferred: { _ in replayed.append("b") }),
                       .deferred)
        XCTAssertEqual(policy.routeLoopSpeech("The build failed again.",
                                              whenDeferred: { _ in replayed.append("c") }),
                       .deferred)
        XCTAssertEqual(policy.deferredCount, 2, "the stutter is collapsed, the second fact is not")

        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, ["a", "c"])
        XCTAssertEqual(sink.fields(of: "notification.dropped_stale")
                           .map { "\($0["reason"] ?? "")/\($0["kind"] ?? "")" },
                       ["duplicate/loop_speech"])
    }

    /// Two identical sentences separated by real time are two things said, exactly as two
    /// finishes apart in time are two pieces of news: the collapse above is about one window,
    /// not about the words.
    func testTheSameLoopSentenceSaidAgainLaterIsNotDeduped() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink())

        XCTAssertEqual(policy.routeLoopSpeech("The build failed.", whenDeferred: { _ in }),
                       .speak)
        XCTAssertEqual(policy.routeLoopSpeech("The build failed.", whenDeferred: { _ in }),
                       .speak)
        XCTAssertEqual(policy.deferredCount, 0)
    }

    /// `--no-announcements` silences agent state changes and nothing else. A loop sentence is
    /// not an ambient announcement — it is the output of work the wearer asked for, and a
    /// wearer who set a directive and hears nothing cannot tell that from a directive that
    /// never fired. The flag reaches exactly one function, and this is the test that says so.
    func testNoAnnouncementsSilencesTheAgentButNotTheLoop() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink(), announcements: false)
        var replayed: [NotificationPolicy.Verdict] = []

        XCTAssertEqual(policy.route(.agentNotification(kind: .finished, sessionID: "s1")),
                       .suppress)
        XCTAssertEqual(policy.routeLoopSpeech("Two tests still fail.",
                                              whenDeferred: { replayed.append($0) }), .speak)

        // And the deferral still applies to it: silenced is not what the loop is, held is.
        window.isOpen = true
        XCTAssertEqual(policy.routeLoopSpeech("I reran the failing suite.",
                                              whenDeferred: { replayed.append($0) }), .deferred)
        window.isOpen = false
        await settle()
        XCTAssertEqual(replayed, [.speak])
    }

    /// Quiet mode does not turn a loop sentence into a cue either: the run's loop speech
    /// bypasses the quiet decorator on purpose ("answers are still spoken"), and a routing hop
    /// is not the place to reverse that quietly.
    func testQuietModeDoesNotReduceLoopSpeechToACue() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink(), quiet: true)
        var replayed: [NotificationPolicy.Verdict] = []

        XCTAssertEqual(policy.routeLoopSpeech("done", whenDeferred: { _ in }), .speak)

        window.isOpen = true
        _ = policy.routeLoopSpeech("held", whenDeferred: { replayed.append($0) })
        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, [.speak], "the held verdict is the one that was computed")
    }

    /// A prompt overtakes held news about its own session. It does not overtake held loop
    /// speech, which is about no session: a review is something TapQ decided to say, not a
    /// reading of a session's state that a newer reading replaces.
    func testAFreshPromptDoesNotDropHeldLoopSpeech() async {
        let window = Window()
        let sink = RecordingSink()
        let policy = deferringPolicy(window: window, clock: VirtualClock(), sink: sink)
        var replayed: [String] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { _ in replayed.append("notice") })
        _ = policy.routeLoopSpeech("I told Claude Code to rerun the failing suite.",
                                   whenDeferred: { _ in replayed.append("loop") })
        _ = policy.route(.requestPrompt(sessionID: "s1"))
        XCTAssertEqual(policy.deferredCount, 1, "the notice went stale; the sentence did not")

        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, ["loop"])
    }

    /// Replay re-entrancy. A replay closure speaks, and the loop can compose a sentence off
    /// the back of it — so `routeLoopSpeech` is called from inside the drain. The queue is
    /// emptied before anything is played, so the arriving sentence joins nothing and is said
    /// once, after the entry that provoked it.
    func testLoopSpeechArrivingDuringAReplayIsSaidOnceAndInOrder() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink())
        var replayed: [String] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { _ in
                             replayed.append("notice")
                             let verdict = policy.routeLoopSpeech(
                                 "and here is what that means",
                                 whenDeferred: { _ in replayed.append("loop (deferred)") }
                             )
                             XCTAssertEqual(verdict, .speak,
                                            "the window is closed — that is why this is replaying")
                             replayed.append("loop")
                         })

        window.isOpen = false
        await settle()

        XCTAssertEqual(replayed, ["notice", "loop"])
        XCTAssertEqual(policy.deferredCount, 0)
    }

    /// The other half of re-entrancy: a replay whose speech re-opens a window. The sentence
    /// routed from inside it is held — and it is held by the drain that is already running,
    /// which had declined to start a second one. It still has to come out when that window
    /// closes, without waiting for an unrelated notification to come along and notice it.
    func testSpeechHeldFromInsideAReplayIsStillDrained() async {
        let window = Window()
        let policy = deferringPolicy(window: window, clock: VirtualClock(),
                                     sink: RecordingSink())
        var replayed: [String] = []

        window.isOpen = true
        _ = policy.route(.agentNotification(kind: .finished, sessionID: "s1"),
                         whenDeferred: { _ in
                             replayed.append("notice")
                             window.isOpen = true
                             XCTAssertEqual(
                                 policy.routeLoopSpeech(
                                     "and here is what that means",
                                     whenDeferred: { _ in replayed.append("loop") }
                                 ),
                                 .deferred
                             )
                         })

        window.isOpen = false
        await settle()
        XCTAssertEqual(replayed, ["notice"], "the re-opened window still holds it back")
        XCTAssertEqual(policy.deferredCount, 1)

        window.isOpen = false
        await settle()
        XCTAssertEqual(replayed, ["notice", "loop"])
        XCTAssertEqual(policy.deferredCount, 0)
    }
}
