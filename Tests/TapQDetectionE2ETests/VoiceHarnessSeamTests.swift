import Foundation
import XCTest
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

/// One test per seam the voice harness gained, and nothing else.
///
/// These are not the voice route's E2E tests — those are the three track files, which use
/// these seams to say something about the product. These say something about the seams: a
/// scripted transcript really does travel through the production provider, a scripted
/// verdict really does reach both attribution gates, a cue really is observable where the
/// runtime plays one, and the motion flag really does change what a prompt teaches. If one
/// of these fails, no assertion in the track files means what it claims to.
@MainActor
final class VoiceHarnessSeamTests: XCTestCase {
    // MARK: - Seam 1: the provider channel

    /// The channel swap: the same "yes" that resolves an approval through the transcript
    /// channel resolves it through a real `VoiceBackendCommandProvider` over a scripted
    /// backend — and does so on the *final* transcript, with an unmatched partial ahead of
    /// it proving the provider is the thing doing the matching.
    ///
    /// The turn accounting is the assertion that the provider is really in the path: it
    /// opened one session, opened one turn, and ended that turn on the match without
    /// anybody asking it to (teardown-on-match). The harness channel restated none of it.
    func testProviderChannelResolvesAnApprovalOnAFinalTranscript() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in ProviderVoiceChannel(diagnosticSink: sink) }
        )
        let channel = try XCTUnwrap(harness.providerChannel)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the provider's session never opened")
        XCTAssertEqual(channel.backend.beganTurns, 1, "one window opens exactly one turn")

        // "well" is not in the grammar, so the partial resolves nothing; the final does.
        harness.hear(partial: "well", then: "yes")

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "the match must end the turn, and never ask for a spoken reply")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.matched"
        }, "the real provider, not the harness, must be what matched the transcript")
    }

    // MARK: - Seam 2: per-utterance attribution

    /// Three verdicts, three different fates for the same window, all scripted per
    /// utterance rather than derived from an envelope.
    ///
    /// A dictation arrives while the signal cannot answer: the instruction path refuses it
    /// out loud (fail closed) while the command gate is still passing everything through
    /// (fail open). A bystander's "yes" is then dropped at the gate. The wearer's own "yes"
    /// resolves the window. Nothing here is asserting *about* attribution policy — the
    /// policy is pinned by `WearerPathE2ETests` and the unit suites; this is asserting that
    /// the scripted verdict is what the gates read.
    func testScriptedVerdictReachesBothAttributionGates() async throws {
        var dictated: [String] = []
        let harness = DetectionPathHarness(
            instructionCapability: { true },
            instructionEnqueue: { dictated.append($0); return .queued },
            attribution: .wearer
        )

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        // (a) The signal cannot answer. The instruction is refused; the command gate is
        // simultaneously letting the very same utterance through.
        harness.hear("tell it to run the tests again", attributed: .signalUnavailable)
        let refusalWindow = await harness.waitForWindow(2)
        XCTAssertTrue(refusalWindow, "a refusal re-listens; it never resolves")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.passed_signal_unavailable"
        }, "commands must still fail open on an unavailable signal")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "instruction.rejected_unattributed"
        }, "instructions must fail closed on the same signal")
        XCTAssertTrue(dictated.isEmpty)

        // (b) Somebody else in the room, with the signal live.
        harness.hear("yes", attributed: .bystander)
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.rejected_nonwearer"
        }, "a bystander's yes must not reach the controller")
        XCTAssertEqual(harness.inputs.openedWindows, 2,
                       "a dropped command must not re-listen")

        // (c) The wearer, in the same window, one utterance later.
        harness.hear("yes", attributed: .wearer)
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
    }

    // MARK: - Seam 3: the speech decorator slot

    /// A cue played by a real `QuietSpeech` in the decorator slot is observable, and the
    /// sentence it replaced is not spoken.
    ///
    /// The runtime arms the prompt as it opens the window; the test does it here for the
    /// same reason and at the same moment. What is being pinned is the slot — that the
    /// controllers speak through whatever it returns and `harness.speech` stays the
    /// recorder underneath — not `QuietSpeech`'s routing rules, which `QuietSpeechTests`
    /// owns.
    func testCueRecorderObservesACueThroughTheDecoratorSlot() async throws {
        let cues = CueRecorder()
        let quiet = QuietBox()
        let harness = DetectionPathHarness(speechDecorator: { inner in
            let presenter = QuietSpeech(wrapping: inner) { cues.record($0) }
            quiet.presenter = presenter
            return presenter
        })
        let presenter = try XCTUnwrap(quiet.presenter)
        presenter.armPrompt()

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        XCTAssertEqual(cues.cues, [.prompt], "the prompt must arrive as a cue")
        XCTAssertFalse(harness.speech.spoken.contains { $0.text.contains("run the test suite") },
                       "the request was spoken as well as chimed: "
                           + "\(harness.speech.spoken.map(\.text))")

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "a chimed prompt is answered by the same nod")
    }

    // MARK: - Seam 4: the motion-availability flag

    /// With no motion device, the selection prompt teaches the voice-only controls and the
    /// swipe channel refuses to attach — the two places the host sends the same flag.
    func testMotionUnavailableChoosesTheVoiceOnlyHintAndGatesSwipes() async throws {
        let harness = DetectionPathHarness(motionAvailable: false)

        let result = Task { await harness.selection.resolve(Self.selection) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        let prompt = try XCTUnwrap(harness.speech.spoken.first?.text)
        XCTAssertTrue(prompt.hasSuffix(SelectionController.voiceOnlyControlsHint),
                      "the prompt taught controls that cannot resolve it: \(prompt)")
        XCTAssertFalse(prompt.contains(SelectionController.controlsHint))
        let suppressed = try XCTUnwrap(
            harness.diagnostics.events.first { $0.name == "swipes.suppressed" },
            "the swipe channel attached without a motion device"
        )
        XCTAssertEqual(suppressed.fields["reason"], "motion_unavailable")

        // And the controls it did teach work: "select" takes the option under the cursor.
        harness.hear("select")
        let selected = await result.value
        harness.assertWatchdogDidNotFire()
        XCTAssertFalse(selected.timedOut)
        XCTAssertEqual(selected.choices.map(\.index), [0])
    }

    // MARK: - Fixtures

    /// Holds the decorator the slot built, so the test can arm the prompt the way the host
    /// does. The runtime keeps the same reference in a local `var` for the same purpose.
    private final class QuietBox {
        var presenter: QuietSpeech?
    }

    private static let approval = ApprovalRequest(
        id: "r1", sessionID: "s1", toolName: "Bash",
        summary: "run the test suite", detail: "swift test"
    )

    private static let selection = SelectionRequest(
        id: "r2", sessionID: "s1", question: "Which format?",
        options: [
            .init(label: "PDF", description: ""),
            .init(label: "PNG", description: ""),
        ],
        multiSelect: false
    )
}
