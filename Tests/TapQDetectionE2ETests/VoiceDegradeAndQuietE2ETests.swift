import Foundation
import XCTest
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

/// The two ways a voice session stops looking like the happy path: the motion half of it is
/// missing or dies, and the speech half of it is turned down to cues.
///
/// Both are host decisions in production — `AppleTapQRuntimeService` branches on the motion
/// loss reason and composes `QuietSpeech` — and neither is reachable from a portable target
/// as written. So the degrade *ordering* is restated here the way `FilterPath` restates
/// `runApproval` (R8: no macOS-only type is imported, and `MotionLoss` below is this file's
/// own copy of the reason vocabulary), while every layer it drives — `NotificationPolicy`,
/// the arbiters, the controllers, `MotionGatedSwipes`, `QuietSpeech` — is the shipping one.
///
/// What that pins is the thing a unit test of any single layer cannot: that a stream which
/// was never there is *not* treated as a stream that broke, and that turning the wearer's
/// output down to a chime changes which channel they hear on and nothing about what they can
/// answer.
@MainActor
final class VoiceDegradeAndQuietE2ETests: XCTestCase {
    // MARK: - Degrade: the stream that was never there

    /// `never_streamed` is the no-AirPods session — including AirPods that are paired but
    /// sitting in their case, where the availability flag lies and only the sampleless
    /// watchdog tells the truth — and the whole point of the reason having its own case is
    /// that it must not be treated as a disconnection: no outage notice, no cue, no
    /// cancellation. What it may do, exactly once per run, is say why the run is
    /// voice-only, because when startup's availability poll was lied to, this branch is
    /// the first place the run knows.
    ///
    /// What the wearer gets is a window that knows it is voice-only — the prompt
    /// teaches controls that can actually resolve it, and the swipe channel refuses to
    /// attach to a built-in speaker's volume — and that window then answers a spoken
    /// "select" exactly as it always did. Announcing a disconnect here would name hardware
    /// the wearer never put in; cancelling would take the live voice window down with it.
    func testNeverStreamedSpeaksTheVoiceOnlyNoticeOnceAndCancelsNothing() async throws {
        let harness = DetectionPathHarness(motionAvailable: false)
        let degrade = DegradePath(harness: harness)

        let result = Task { await harness.selection.resolve(Self.selection) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the selection opened no input window")

        let prompt = try XCTUnwrap(harness.speech.spoken.first?.text)
        XCTAssertTrue(prompt.hasSuffix(SelectionController.voiceOnlyControlsHint),
                      "the prompt taught controls that cannot resolve it: \(prompt)")
        let suppressed = try XCTUnwrap(
            harness.diagnostics.events.first { $0.name == "swipes.suppressed" },
            "the swipe channel attached without a motion device"
        )
        XCTAssertEqual(suppressed.fields["reason"], "motion_unavailable")

        // The bounded availability retry (or the sampleless startup watchdog, when the
        // availability flag lied) expires. The host's first act is a guard, and this is
        // the assertion that the guard is still first — and that the only thing inside it
        // is the once-per-run voice-only notice. A second window's `.neverStreamed`
        // repeats the reason and must not repeat the sentence.
        degrade.motionLost(.neverStreamed)
        degrade.motionLost(.neverStreamed)
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(degrade.verdicts.isEmpty,
                      "nothing was lost, so the policy must never be asked")
        XCTAssertFalse(degrade.cues.played)
        XCTAssertFalse(harness.speech.said(DegradePath.notice))
        XCTAssertEqual(
            harness.speech.spoken.filter { $0.text == DegradePath.voiceOnlyNotice }.count,
            1,
            "the wearer is told once why the run is voice-only, and never twice: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertFalse(harness.diagnostics.events.contains { $0.name == "listen.cancelled" },
                       "a session that never had motion must not lose its voice window")

        // And the window it left alone still resolves, by the one channel it has.
        harness.hear("select")
        let selected = await result.value
        harness.assertWatchdogDidNotFire()
        XCTAssertFalse(selected.timedOut)
        XCTAssertEqual(selected.choices.map(\.index), [0])
    }

    // MARK: - Degrade: the stream that broke

    /// `silent_stream` is a real mid-window outage: the device is present and mute, on a
    /// run that has streamed samples before — the detector reserves the reason for
    /// sources that have proved they were worn. The wearer is told, and the approval they
    /// were being asked about goes to the screen rather than sitting out a window nothing
    /// can answer.
    ///
    /// The route is the assertion — `.speak`, then a cancel that the controller turns into
    /// `.ask` — because the sentence itself is the host's and is restated in this file.
    func testSilentStreamAnnouncesTheOutageAndDefersTheApproval() async throws {
        let harness = DetectionPathHarness()
        let degrade = DegradePath(harness: harness)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        degrade.motionLost(.silentStream)

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(degrade.verdicts, [.speak],
                       "a real outage is never suppressed outright")
        XCTAssertEqual(
            harness.speech.spoken.first(where: { $0.text == DegradePath.notice })?.priority,
            .notification,
            "the outage notice rides the notification channel: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertTrue(harness.diagnostics.events.contains { $0.name == "listen.cancelled" },
                      "the window must not wait out a timeout nothing can answer")
        XCTAssertEqual(outcome, .ask, "an unanswerable window belongs on the screen")
        XCTAssertTrue(harness.speech.said(Self.deferral),
                      "the wearer must be told where the question went: "
                          + "\(harness.speech.spoken.map(\.text))")
    }

    /// `lost_while_streaming` on the other controller, which has its own deferral path and
    /// its own sentinel: a cancelled selection is `.noSelection`, which the broker reads as
    /// fail-open. Same host ordering, same notice, different window.
    func testLostWhileStreamingDefersTheSelectionToTheScreen() async throws {
        let harness = DetectionPathHarness()
        let degrade = DegradePath(harness: harness)

        let result = Task { await harness.selection.resolve(Self.selection) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        degrade.motionLost(.lostWhileStreaming)

        let selected = await result.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(degrade.verdicts, [.speak])
        XCTAssertTrue(harness.speech.said(DegradePath.notice))
        XCTAssertEqual(selected, .noSelection)
        // The selection controller writes the deferral out itself rather than reading a
        // presenter; the two must go on saying the same words, because a wearer cannot tell
        // which controller they are standing in.
        XCTAssertTrue(harness.speech.said(Self.deferral),
                      "\(harness.speech.spoken.map(\.text))")
    }

    // MARK: - Degrade meets quiet

    /// The crossover the host comments on and nothing tested: under `--quiet` the outage
    /// notice is not suppressed, it changes channel. The cue player is the same one
    /// `QuietSpeech` holds — one sound source per run — so the wearer hears the prompt, the
    /// outage, and the deferral as three tones, in that order, and not one word.
    func testUnderQuietTheOutageNoticeBecomesACueAndStillCancels() async throws {
        let cues = CueRecorder()
        let quiet = QuietBox()
        let harness = DetectionPathHarness(speechDecorator: { inner in
            let presenter = QuietSpeech(wrapping: inner) { cues.record($0) }
            quiet.presenter = presenter
            return presenter
        })
        let presenter = try XCTUnwrap(quiet.presenter)
        presenter.armPrompt()
        let degrade = DegradePath(harness: harness, cues: cues, quiet: true)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        XCTAssertEqual(cues.cues, [.prompt])

        degrade.motionLost(.silentStream)

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(degrade.verdicts, [.chime(.notification)],
                       "quiet mode must route the outage, never swallow it")
        XCTAssertEqual(cues.cues, [.prompt, .notification, .notification],
                       "prompt, outage, deferral — all three still reach the wearer")
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "quiet mode spoke: \(harness.speech.spoken.map(\.text))")
        XCTAssertEqual(outcome, .ask)
    }

    // MARK: - Quiet: the prompt, and the way back to the words

    /// Quiet mode's bargain, end to end: the request arrives as a tone instead of a
    /// sentence, and the wearer who wants the sentence asks for it out loud.
    ///
    /// "status" is answered by the real `ConversationMemory` recall responder over the
    /// window the request is standing in, and it is spoken — because it answers something
    /// the wearer said, and a chime in reply to a question cannot be told from a misheard
    /// one. Then the same window resolves on a spoken "yes": what quiet mode changed is the
    /// channel, never what can answer.
    func testQuietChimesThePromptAndStatusSpeaksTheRequestInFull() async throws {
        let memory = ConversationMemory()
        let cues = CueRecorder()
        let quiet = QuietBox()
        let harness = DetectionPathHarness(
            recallResponder: memory.recallResponder,
            speechDecorator: { inner in
                let presenter = QuietSpeech(wrapping: inner) { cues.record($0) }
                quiet.presenter = presenter
                return presenter
            }
        )
        let presenter = try XCTUnwrap(quiet.presenter)
        presenter.armPrompt()

        let request = Self.approval
        let decision = Task {
            await memory.withWindow(
                sessionID: request.sessionID, agent: request.agent,
                summary: request.summary, detail: request.detail
            ) {
                await harness.interaction.resolve(request)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        XCTAssertEqual(cues.cues, [.prompt], "the request must arrive as a cue")
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "a chimed prompt says nothing: \(harness.speech.spoken.map(\.text))")

        harness.hear("status")

        let stillListening = await harness.waitForWindow(2)
        XCTAssertTrue(stillListening, "a question keeps the window open")
        XCTAssertTrue(
            harness.speech.spoken.contains { $0.text.contains(request.summary) },
            "the wearer asked what was waiting and must hear it in full: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertEqual(cues.cues, [.prompt],
                       "an answer to the wearer is never a cue")

        harness.hear("yes")
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "a chimed prompt is answered the same way")
    }

    /// The other cue, and the reason there are two: something that happened is not something
    /// that needs you. An announcement the wearer never has to answer plays the flat
    /// notification tone, not the prompt tone, and adds no words.
    func testQuietPlaysTheFlatCueForAnAnnouncement() async throws {
        let cues = CueRecorder()
        let harness = DetectionPathHarness(speechDecorator: { inner in
            QuietSpeech(wrapping: inner) { cues.record($0) }
        })

        harness.interaction.announce(Self.notification)

        XCTAssertEqual(cues.cues, [.notification],
                       "a state change is not a prompt and must not sound like one")
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "\(harness.speech.spoken.map(\.text))")
    }

    /// The line quiet mode must never take away: a dictation read-back.
    ///
    /// It is the only moment the wearer hears what the agent is about to be told, and
    /// confirming a tone would be confirming nothing. So the prompt that opened the window
    /// is a cue and the read-back inside it is speech, from the same presenter, one
    /// utterance apart — and the nod that follows queues the sentence that was read back.
    func testQuietStillSpeaksADictationReadBack() async throws {
        var dictated: [String] = []
        let cues = CueRecorder()
        let quiet = QuietBox()
        let harness = DetectionPathHarness(
            instructionCapability: { true },
            instructionEnqueue: { dictated.append($0) },
            speechDecorator: { inner in
                let presenter = QuietSpeech(wrapping: inner) { cues.record($0) }
                quiet.presenter = presenter
                return presenter
            },
            attribution: .wearer
        )
        let presenter = try XCTUnwrap(quiet.presenter)
        presenter.armPrompt()

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        XCTAssertEqual(cues.cues, [.prompt])

        harness.hear("tell it to run the tests again", attributed: .wearer)

        let readBackWindow = await harness.waitForWindow(2)
        XCTAssertTrue(readBackWindow, "the read-back must re-listen")
        XCTAssertTrue(
            harness.speech.spoken.contains { $0.text.contains("run the tests again") },
            "the read-back was chimed away: \(harness.speech.spoken.map(\.text))"
        )
        XCTAssertEqual(cues.cues, [.prompt], "only the prompt is a cue in this window")
        XCTAssertTrue(dictated.isEmpty, "nothing is queued before the wearer confirms it")

        // The nod that confirms the read-back is spent inside the dictation flow.
        harness.feed(TraceGenerators.doubleNod())
        let resumed = await harness.waitForWindow(3)
        XCTAssertTrue(resumed, "queueing must resume the window")
        XCTAssertEqual(dictated, ["run the tests again"])

        // And the request underneath is still the one being asked.
        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
    }

    // MARK: - Fixtures

    /// Holds the decorator the slot built, so the test can arm the prompt the way the host
    /// does. The runtime keeps the same reference in a local `var` for the same purpose.
    private final class QuietBox {
        var presenter: QuietSpeech?
    }

    /// The words the wearer hears when a question moves to the screen. Read off the shipping
    /// presenter rather than typed here, so a reworded deferral fails the assertion that
    /// cares rather than this one.
    private static let deferral = DefaultApprovalRequestPresenter().deferralNotice()

    private static let approval = ApprovalRequest(
        id: "r1", sessionID: "s1", agent: .claudeCode, toolName: "Bash",
        summary: "run the test suite", detail: "swift test"
    )

    private static let selection = SelectionRequest(
        id: "r2", sessionID: "s1", agent: .claudeCode, question: "Which format?",
        options: [
            .init(label: "PDF", description: ""),
            .init(label: "PNG", description: ""),
        ],
        multiSelect: false
    )

    private static let notification = AgentNotification(
        sessionID: "s1", agent: .claudeCode, kind: .finished,
        summary: "the build finished"
    )
}

/// Why a motion channel ended, as this target is allowed to say it.
///
/// A copy of `MotionLossReason`, raw values and all, because that enum lives in
/// `TapQAppleAdapters` and importing it here would put a macOS-only module in a portable
/// target's graph (R8). The raw values are the tie: they are the `reason` field of the
/// `motion.lost` diagnostic, so a case renamed on the Apple side and not here shows up as a
/// mismatched diagnostic rather than as a silently divergent test.
private enum MotionLoss: String {
    case neverStreamed = "never_streamed"
    case lostWhileStreaming = "lost_while_streaming"
    case silentStream = "silent_stream"
}

/// The runtime's `onMotionLost` closure, restated over the portable pieces.
///
/// The order is the feature and is copied exactly: guard the reason, route the
/// announcement, play it, and only then cancel both arbiters. Every step but the guard is
/// the shipping implementation — a real `NotificationPolicy`, the harness's real arbiters,
/// the real controllers that turn a cancelled window into a deferral. What is restated is
/// the sequence, because the executable that owns it is macOS-only and a wiring regression
/// in it has to fail on Linux too.
@MainActor
private final class DegradePath {
    /// The sentence the host speaks for a real outage. Restated with the ordering, so an
    /// assertion on it is an assertion on this file — the tests lean on `verdicts` for the
    /// claim that matters.
    static let notice = "AirPods motion disconnected."

    /// The one-time voice-only notice. The host speaks it from two places behind one
    /// once-per-run flag — the startup availability poll, and the `.neverStreamed` branch
    /// restated below, which is how a run whose availability flag lied (AirPods paired but
    /// in their case) still gets told it is voice-only. In the host it is a status line
    /// gated on `--no-announcements`; the gate is not restated here, the order is.
    static let voiceOnlyNotice = "No AirPods detected. Running voice only."

    let harness: DetectionPathHarness
    /// The one cue player a run has. `QuietSpeech` and this path share it in the runtime,
    /// so a test that composes both passes the same recorder to both.
    let cues: CueRecorder
    /// Every verdict this path asked the policy for, in order. Empty means the guard fired
    /// before the policy was ever consulted.
    private(set) var verdicts: [NotificationPolicy.Verdict] = []

    private let policy: NotificationPolicy

    /// `cues` is optional rather than defaulted to a fresh recorder because a default
    /// argument is evaluated outside the actor, and `CueRecorder` is `@MainActor` (R4).
    init(harness: DetectionPathHarness, cues: CueRecorder? = nil, quiet: Bool = false) {
        self.harness = harness
        self.cues = cues ?? CueRecorder()
        // A registry of its own: motion loss is not per-session and never consults it, and
        // sharing one would only invite a reader to think it does.
        self.policy = NotificationPolicy(
            settings: .init(quiet: quiet), waits: SessionWaitRegistry()
        )
    }

    /// Whether the once-per-run voice-only notice has been spoken, mirroring the host's
    /// flag of the same purpose.
    private var voiceOnlyNoticeSpoken = false

    func motionLost(_ reason: MotionLoss) {
        guard reason != .neverStreamed else {
            // The host's guard speaks the one-time notice and stops: the policy is never
            // consulted and nothing is cancelled. A repeat `.neverStreamed` — every
            // subsequent window of a no-AirPods run reports one — says nothing more.
            if !voiceOnlyNoticeSpoken {
                voiceOnlyNoticeSpoken = true
                harness.speech.speak(
                    Self.voiceOnlyNotice, priority: .notification, onFinish: nil
                )
            }
            return
        }
        let verdict = policy.route(.motionLost)
        verdicts.append(verdict)
        switch verdict {
        case .speak:
            harness.speech.speak(Self.notice, priority: .notification, onFinish: nil)
        case .chime(let cue):
            cues.record(cue)
        case .suppress:
            break
        }
        harness.inputArbiter.cancel()
        harness.selectionArbiter.cancel()
    }
}
