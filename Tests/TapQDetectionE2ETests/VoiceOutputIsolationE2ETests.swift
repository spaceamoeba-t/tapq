import XCTest
import TapQContracts
import TapQVoiceBackends
@testable import TapQInteractionBaseline

/// One backend, one voice — asserted from the top of the interaction path rather than at
/// the seam that implements it.
///
/// Every other test of this feature can be satisfied by a routing decision that is correct
/// in isolation. These run the real controllers: the real `InteractionController` writes the
/// real prompt, the real `SelectionController` writes the real options and the real
/// deferral, and the question asked of the result is the one the maintainer's decision
/// actually made — *did any sentence reach the local synthesizer?*
///
/// `harness.speech` is that synthesizer. It sits underneath the sink in exactly the place
/// the runtime's `SpeechEngine` sits, and it stays empty because the sink has no reference
/// to it. That emptiness is the test.
@MainActor
final class VoiceOutputIsolationE2ETests: XCTestCase {
    /// The route closure has to exist before the harness that owns the provider does, so it
    /// reads the provider out of a box the test fills in immediately afterwards. Nothing is
    /// spoken in between.
    @MainActor
    private final class ProviderBox {
        var provider: VoiceBackendCommandProvider?

        func route(_ text: String) -> BackendSpeechDelivery {
            provider?.speakScripted(text) ?? .dropped("no_provider")
        }
    }

    /// The realtime shape: a conversation-mode session over a duplex pipe, with every
    /// sentence routed to it. `idleSleep` is bounded rather than the harness's hour so the
    /// timer this composition starts cannot outlive the test that started it.
    private func makeHarness(_ box: ProviderBox) -> DetectionPathHarness {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in
                ProviderVoiceChannel(
                    diagnosticSink: sink,
                    sessionPolicy: .conversation(idleClose: 60),
                    supportsBargeIn: true,
                    backendCapabilities: ProviderVoiceChannel.realtimeCapabilities,
                    idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) }
                )
            },
            speechDecorator: { _ in
                BackendSpeechSink(route: { box.route($0) })
            }
        )
        box.provider = harness.providerChannel?.provider
        return harness
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "r1", sessionID: "s1", toolName: "Bash",
                        summary: "run the test suite", detail: "swift test")
    }

    /// The prompt — the sentence that names what the wearer is authorizing — is read by the
    /// backend, verbatim, and the local voice is never asked for it.
    func testTheApprovalPromptIsReadByTheBackendAndNotByTheLocalVoice() async {
        let box = ProviderBox()
        let harness = makeHarness(box)
        let backend = try! XCTUnwrap(harness.providerChannel).backend

        let decision = Task { await harness.interaction.resolve(self.request()) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        XCTAssertTrue(backend.scriptedSpeech.contains { $0.contains("run the test suite") },
                      "the prompt never reached the backend: \(backend.scriptedSpeech)")
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "the local synthesizer spoke: \(harness.speech.spoken)")
        XCTAssertTrue(backend.requestedResponses.isEmpty,
                      "a prompt is a scripted reading, never a generated response")

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "the local synthesizer spoke: \(harness.speech.spoken)")
    }

    /// A selection window says several things across several turns, and the backend says all
    /// of them — including the one written while the pipe was still busy with the last.
    ///
    /// The middle of this test is the queue doing its job. A sentence that cannot go out now
    /// waits for the response ahead of it to finish; what it never does is arrive in a second
    /// voice, which is what the old decorator did with every sentence a busy route declined.
    func testASelectionWindowSaysEverythingThroughTheBackend() async {
        let box = ProviderBox()
        let harness = makeHarness(box)
        let backend = try! XCTUnwrap(harness.providerChannel).backend
        let selection = SelectionRequest(
            id: "r1", sessionID: "s1", question: "Which branch?",
            options: [
                .init(label: "main", description: ""),
                .init(label: "release", description: ""),
            ],
            multiSelect: false
        )

        let result = Task { await harness.selection.resolve(selection) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        XCTAssertTrue(backend.scriptedSpeech.contains { $0.contains("Which branch?") },
                      "\(backend.scriptedSpeech)")

        // Navigating writes the next option's line while the question is still being read.
        harness.hear("next")
        let moved = await harness.waitForWindow(2)
        XCTAssertTrue(moved, "the navigation opened no second window")
        XCTAssertFalse(backend.scriptedSpeech.contains { $0.contains("release") },
                       "one response at a time: \(backend.scriptedSpeech)")
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "a busy pipe is not a reason to use the local voice:"
                          + " \(harness.speech.spoken)")

        // The pipe finishes the question, and the sentence behind it goes out on the same
        // pipe rather than having been said somewhere else in the meantime.
        backend.emit(.responseCompleted)
        await Task.yield()
        XCTAssertTrue(backend.scriptedSpeech.contains { $0.contains("release") },
                      "\(backend.scriptedSpeech)")

        harness.hear("select")
        let outcome = await result.value
        XCTAssertEqual(outcome.choices, [.init(index: 1, label: "release")])
        XCTAssertTrue(harness.speech.spoken.isEmpty,
                      "the local synthesizer spoke: \(harness.speech.spoken)")
        XCTAssertTrue(backend.requestedResponses.isEmpty,
                      "nothing TapQ wrote was sent as a generated response")
    }
}
