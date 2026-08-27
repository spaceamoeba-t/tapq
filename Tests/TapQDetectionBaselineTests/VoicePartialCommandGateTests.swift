import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

/// The firing policy for partial transcripts, at the level where it is a pure function of
/// (text, finality, clock). The listener that owns the timer is covered separately; what is
/// pinned here is the rule itself.
final class VoicePartialCommandGateTests: XCTestCase {
    private let window: TimeInterval = 0.7

    private func makeGate() -> VoicePartialCommandGate {
        VoicePartialCommandGate(stabilityWindow: window)
    }

    // MARK: - The reported defect

    /// The live failure, twice on hardware, 2026-08-27: the wearer says "ok, skip the
    /// command", the recognizer's first partial is "OK", the grammar reads that fragment as
    /// an approval — correctly, for that text — and the old listener fired it and tore the
    /// recognizer down before the word "skip" ever existed. The wearer meant skip; the
    /// runtime approved.
    ///
    /// The transcripts below are the shape a streaming recognizer actually produces:
    /// cumulative, growing, and a command in their own right at every step.
    func testPartialOKFollowedByFinalSkipSkipsAndNeverApproves() {
        var gate = makeGate()

        XCTAssertEqual(gate.admit(transcript: "OK", isFinal: false, at: 0),
                       .hold(recheckAfter: window),
                       "an approval matched on a fragment must not be delivered")
        XCTAssertEqual(gate.admit(transcript: "OK skip", isFinal: false, at: 0.35),
                       .hold(recheckAfter: window),
                       "the wearer is still talking; the candidate is replaced, not fired")
        XCTAssertEqual(gate.admit(transcript: "ok skip the command", isFinal: true, at: 0.6),
                       .fire(.skip))
    }

    /// The same sentence when the recognizer never flags anything final — the ordinary case
    /// on a live audio buffer, where finality only arrives at teardown. The deferral still
    /// wins, and it wins on the stability rule alone.
    func testPartialOKFollowedByPartialSkipStillSkipsWithoutAnyFinalTranscript() {
        var gate = makeGate()

        XCTAssertEqual(gate.admit(transcript: "OK", isFinal: false, at: 0),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.admit(transcript: "ok skip the command", isFinal: false, at: 0.4),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.recheck(at: 0.4 + window), .fire(.skip))
    }

    // MARK: - The two answers

    func testApprovalOnAPartialIsHeldAndTheSameTextAsFinalFires() {
        var gate = makeGate()
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: false, at: 0),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: true, at: 0.05), .fire(.yes))
    }

    /// The stability release: text that stops changing is text the wearer has finished
    /// saying, so a spoken "yes" still resolves its window on a recognizer that never
    /// finalizes anything.
    func testApprovalHeldOnPartialsFiresOnceTheTranscriptStopsChanging() {
        var gate = makeGate()
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: false, at: 0),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: false, at: 0.3),
                       .hold(recheckAfter: window - 0.3),
                       "a repeat of the same text keeps the original clock, not a new one")
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: false, at: window), .fire(.yes))
    }

    /// A re-check that lands a hair early — two clock sources rarely agree to the
    /// microsecond — reschedules the sliver instead of firing early or hanging.
    func testAnEarlyRecheckReschedulesTheRemainder() {
        var gate = makeGate()
        _ = gate.admit(transcript: "approve", isFinal: false, at: 0)
        guard case .hold(let remaining) = gate.recheck(at: window - 0.001) else {
            return XCTFail("an early re-check must hold, not fire")
        }
        XCTAssertEqual(remaining, 0.001, accuracy: 0.0001)
        XCTAssertEqual(gate.recheck(at: window), .fire(.yes))
    }

    func testDenialIsHeldOnAPartialToo() {
        var gate = makeGate()
        XCTAssertEqual(gate.admit(transcript: "no", isFinal: false, at: 0),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.recheck(at: window), .fire(.no),
                       "a denial arriving a beat late is the cost this fix accepts")
    }

    // MARK: - Everything else that decides something

    func testSelectionAndInstructionFamiliesWaitForASettledTranscript() {
        for (transcript, command) in [("two", VoiceCommand.number(2)),
                                      ("pick this", .select),
                                      ("next option", .next),
                                      ("go back", .previous),
                                      ("skip", .skip),
                                      ("tell it to run the tests", .beginInstruction("run the tests"))] {
            var gate = makeGate()
            XCTAssertEqual(gate.admit(transcript: transcript, isFinal: false, at: 0),
                           .hold(recheckAfter: window),
                           "'\(transcript)' mutates state and must not fire on a fragment")
            XCTAssertEqual(gate.admit(transcript: transcript, isFinal: true, at: 0.1),
                           .fire(command))
        }
    }

    // MARK: - The informational commands stay instant

    /// Repeating a request, expanding it, or answering a question about the fleet resolves
    /// nothing and leaves the window open, so there is nothing for a fragment to get wrong
    /// and every reason to answer at once.
    func testInformationalCommandsFireOnTheFirstPartial() {
        for (transcript, command) in [("repeat that", VoiceCommand.repeatRequest),
                                      ("details", .details),
                                      ("status", .status),
                                      ("what did you just do", .whatChanged)] {
            var gate = makeGate()
            XCTAssertEqual(gate.admit(transcript: transcript, isFinal: false, at: 0),
                           .fire(command),
                           "'\(transcript)' mutates nothing and must stay instant")
        }
    }

    // MARK: - Non-matches and withdrawal

    func testUnmatchedTranscriptIsIdleAndDropsAHeldCandidate() {
        var gate = makeGate()
        XCTAssertEqual(gate.admit(transcript: "yes", isFinal: false, at: 0),
                       .hold(recheckAfter: window))
        XCTAssertEqual(gate.admit(transcript: "yesterday", isFinal: false, at: 0.2), .idle,
                       "the recognizer revised the word away; the approval goes with it")
        XCTAssertEqual(gate.recheck(at: 10), .idle)
    }

    func testResetForgetsAHeldCandidate() {
        var gate = makeGate()
        _ = gate.admit(transcript: "yes", isFinal: false, at: 0)
        gate.reset()
        XCTAssertEqual(gate.recheck(at: 10), .idle,
                       "a window that closed must not be resolved by what it was holding")
    }

    // MARK: - The single-shot shape

    /// A backend that sends one settled transcript and nothing else — the realtime path's
    /// shape — is unaffected by any of this: every family fires on arrival, exactly as it
    /// did before the gate existed.
    func testASingleFinalTranscriptFiresImmediatelyForEveryFamily() {
        for (transcript, command) in [("yes please", VoiceCommand.yes),
                                      ("no", .no),
                                      ("skip", .skip),
                                      ("three", .number(3)),
                                      ("details", .details)] {
            var gate = makeGate()
            XCTAssertEqual(gate.admit(transcript: transcript, isFinal: true, at: 0),
                           .fire(command))
        }
    }
}
