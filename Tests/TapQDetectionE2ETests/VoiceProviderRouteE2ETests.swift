import Foundation
import XCTest
import TapQBrokerRuntime
import TapQContracts
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// The production voice route, end to end, with the provider in it.
///
/// Every other voice test in this target enters at the grammar: `TranscriptVoiceChannel`
/// hands a matched `VoiceCommand` straight to the arbiter, and the one rule the real path
/// has that the grammar does not — free-form delivery — is restated by hand in the channel.
/// These tests enter one layer lower. A `ScriptedVoiceBackend` emits the events a streaming
/// recognizer emits, a real `VoiceBackendCommandProvider` reads them, and the subject of
/// every assertion below is something the provider decides rather than something the
/// grammar matched: when a session opens, when a turn ends, whether an unmatched sentence
/// becomes a command at all, and what happens to a transcript nobody is listening for.
///
/// Nothing here re-tests the grammar (`VoiceCommandMatcherTests` owns it) or the provider's
/// internal state machine (`VoiceBackendCommandProviderTests` owns that). What it owns is
/// the composition: the provider really is in the shipping path, and the turn accounting a
/// backend sees is the accounting the interaction layer's behavior implies.
@MainActor
final class VoiceProviderRouteE2ETests: XCTestCase {
    // MARK: - Wire to wire, through the provider

    /// An agent's request arrives as bytes, the wearer's "yes" arrives as a partial and then
    /// a final transcript on a scripted backend, and the allow leaves as bytes.
    ///
    /// The partial is a streaming prefix the grammar does not know, so the resolution is
    /// unambiguously the final's — which is the ordering that matters, because a provider
    /// that matched partials would approve on half a word.
    func testASpokenYesApprovesWireToWireThroughTheProvider() async throws {
        try await assertSpokenAnswerLeavesOnTheWire(
            partial: "ye", final: "yes",
            requestID: "r1",
            expected: .decision(.allow, reason: nil)
        )
    }

    /// The same route, the other answer. Worth its own pass rather than a parameter of the
    /// one above: `deny` is the answer that carries a reason on the wire, and it is the
    /// answer a mis-ordered grammar or a partial-matching provider would get wrong first.
    func testASpokenNoDeniesWireToWireThroughTheProvider() async throws {
        try await assertSpokenAnswerLeavesOnTheWire(
            partial: "n", final: "no",
            requestID: "r2",
            expected: .decision(.deny, reason: "Denied via TapQ")
        )
    }

    // MARK: - Free-form is the provider's decision

    /// Without `--voice-freeform` an unmatched sentence is inert, and the provider is what
    /// makes it inert.
    ///
    /// This is the assertion the harness's transcript channel cannot make: its
    /// `hearFreeform` synthesizes `.freeform` unconditionally, so a test written against it
    /// would pass whether or not the flag were ever consulted. Here the flag is off — the
    /// default composition, the Apple path, every run without the switch — and the question
    /// reaches no responder, opens no new window, and resolves nothing.
    func testWithoutTheFreeformFlagTheProviderDeliversNoCommandForAnUnmatchedTranscript() async throws {
        var routed: [String] = []
        let harness = DetectionPathHarness(
            freeformResponder: { text in
                routed.append(text)
                return true
            },
            voiceChannel: { sink in ProviderVoiceChannel(diagnosticSink: sink) }
        )
        let channel = try XCTUnwrap(harness.providerChannel)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        harness.hearFreeform("did the tests pass")
        // Give a delivery that should not exist every chance to happen.
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(routed.isEmpty,
                      "the flag is off; nothing may be routed: \(routed)")
        XCTAssertTrue(harness.diagnostics.events.contains { $0.name == "transcript.rejected" },
                      "the provider must still write the unmatched sentence down")
        XCTAssertEqual(Self.count("freeform.delivered", in: harness), 0)
        XCTAssertEqual(harness.inputs.openedWindows, 1,
                       "no command was delivered, so nothing re-listened")
        XCTAssertEqual(channel.backend.beganTurns, 1,
                       "an unmatched transcript neither ends nor reopens the turn")
        XCTAssertTrue(channel.backend.endedTurns.isEmpty)

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "the request the question was asked inside still answers")
    }

    /// With the flag on, exactly one free-form command is delivered per turn — and the
    /// one-shot belongs to the provider, not to whoever consumes the command.
    ///
    /// Proving that needs a turn that survives a delivery, which the arbiter alone never
    /// gives: any command it receives resolves its listen and stops the channel. So the
    /// composition is the host's own stack — a real `WearerGatedVoice` around the provider —
    /// and the first question is a bystander's. The gate drops the command before the
    /// arbiter sees it, the window stays exactly as it was, and the turn is still open when
    /// the wearer asks their own question a moment later. It is not delivered: the turn's
    /// one free-form slot was already spent on a sentence that went nowhere.
    ///
    /// That is the shipping rule stated where it can actually be observed. The attribution
    /// policy itself is not what is being pinned here — `VoiceAttributionE2ETests` owns
    /// that — the gate is present only because it is the one production component that can
    /// swallow a command without closing the turn behind it.
    func testTheProviderDeliversAtMostOneFreeformPerTurn() async throws {
        var routed: [String] = []
        let harness = DetectionPathHarness(
            freeformResponder: { text in
                routed.append(text)
                return true
            },
            voiceChannel: { sink in
                ProviderVoiceChannel(diagnosticSink: sink, freeformEnabled: true)
            },
            attribution: .wearer
        )
        let channel = try XCTUnwrap(harness.providerChannel)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")
        XCTAssertEqual(channel.backend.beganTurns, 1)

        // (a) Somebody else in the room asks a question. The provider delivers it as
        // free-form; the gate drops it; the window is untouched.
        harness.hear("did the tests pass", attributed: .bystander)

        XCTAssertEqual(Self.count("freeform.delivered", in: harness), 1,
                       "an unmatched final under the flag is one free-form delivery")
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "command.rejected_nonwearer"
        }, "the delivered command must have been dropped before the arbiter")
        XCTAssertTrue(routed.isEmpty, "a dropped command answers nobody: \(routed)")
        XCTAssertEqual(harness.inputs.openedWindows, 1,
                       "a dropped command must not re-listen")

        // (b) The wearer asks, in the same turn. The provider hears it and declines to
        // deliver it a second time.
        harness.hear("is the build green", attributed: .wearer)

        XCTAssertEqual(Self.count("freeform.delivered", in: harness), 1,
                       "the free-form one-shot is per turn, and this turn had spent it")
        XCTAssertEqual(Self.count("transcript.rejected", in: harness), 2,
                       "both sentences reached the provider; only one became a command")
        XCTAssertTrue(routed.isEmpty)
        XCTAssertEqual(harness.inputs.openedWindows, 1)

        // (c) A matched command still resolves the window it was all spoken inside.
        harness.hear("yes", attributed: .wearer)
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(channel.backend.beganTurns, 1,
                       "three utterances, one window, one turn")
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "the match ends the turn, and never asks for a spoken reply")
    }

    // MARK: - Teardown on match, and the commands that are not answers

    /// What a backend sees while the wearer stalls: every matched command tears the turn
    /// down, and the commands that do not answer the request open a fresh one.
    ///
    /// "Details" and "repeat" are informational — the window must survive them — but the
    /// provider does not know that, and must not: a match is a match, the turn ends, and the
    /// controller's decision to listen again is what reopens the session. The accounting is
    /// the assertion, because it is invisible from the interaction layer and it is what a
    /// live backend charges for.
    func testInformationalCommandsEndTheTurnAndTheWindowListensAgain() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in ProviderVoiceChannel(diagnosticSink: sink) }
        )
        let channel = try XCTUnwrap(harness.providerChannel)

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")
        let prompt = try XCTUnwrap(harness.speech.spoken.first?.text)
        XCTAssertEqual(channel.backend.beganTurns, 1)

        // "Details" resolves the listen without resolving the request.
        harness.hear("details")
        let afterDetails = await harness.waitForWindow(2)
        XCTAssertTrue(afterDetails, "details must re-listen, not resolve")
        XCTAssertTrue(harness.speech.said(Self.approval.detail),
                      "spoke: \(harness.speech.spoken.map(\.text))")
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "the match ended the turn without asking for a reply")
        XCTAssertEqual(channel.backend.closes, 1,
                       "per-window sessions close on teardown")
        XCTAssertEqual(channel.backend.beganTurns, 2,
                       "re-listening opened a second turn")

        // So does "repeat", which says the prompt again.
        harness.hear("say again")
        let afterRepeat = await harness.waitForWindow(3)
        XCTAssertTrue(afterRepeat, "repeat must re-listen, not resolve")
        XCTAssertEqual(harness.speech.spoken.filter { $0.text == prompt }.count, 2,
                       "the wearer must have heard the request a second time")
        XCTAssertEqual(channel.backend.beganTurns, 3)

        // And the answer, when it comes, is the only thing that ends the window.
        harness.hear("yes")
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(harness.inputs.openedWindows, 3,
                       "two questions and one answer, and no window more")
        XCTAssertEqual(channel.backend.endedTurns, [false, false, false],
                       "one turn per window, and not one of them asked the backend to speak")
        XCTAssertEqual(channel.backend.closes, 3)
    }

    // MARK: - The handler-nil guard

    /// A transcript that arrives while nothing is listening is dropped, at both of the
    /// moments a real recognizer produces one.
    ///
    /// (a) Before the first window is ready: `start()` posts the session open to a later
    /// main-actor turn, so an event emitted now reaches a backend nobody has subscribed to.
    /// (b) Between two windows of a conversation-mode session: the session is still alive —
    /// that is the whole point of conversation mode — but the provider's handler is nil, and
    /// the guard is the only thing standing between a stale sentence and the next request.
    ///
    /// The dropped sentence is "no" and the answers are not, so a leak in either direction
    /// would show up as the wrong decision rather than as a missing assertion. This pins the
    /// guard as intended behavior: it is also why `hear` is documented to follow
    /// `waitForWindow`.
    func testATranscriptDeliveredWhileNoWindowIsListeningIsDropped() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in
                ProviderVoiceChannel(diagnosticSink: sink,
                                     sessionPolicy: .conversation(idleClose: 3_600))
            }
        )
        let channel = try XCTUnwrap(harness.providerChannel)

        // (a) The session has not opened yet: the resolve task has been created but nothing
        // has suspended, so the open is still queued behind this line.
        let first = Task { await harness.interaction.resolve(Self.approval) }
        XCTAssertFalse(channel.backend.isOpen, "the session opens on a later main-actor turn")
        channel.backend.emit(.transcriptFinal("no"))

        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")
        XCTAssertEqual(Self.count("command.matched", in: harness), 0,
                       "a transcript emitted at a closed session reaches no grammar")

        harness.hear("yes")
        let firstOutcome = await first.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(firstOutcome, .allow, "the early 'no' must not have survived")

        // (b) Between windows. The conversation session is open and no window is.
        XCTAssertTrue(channel.backend.isOpen,
                      "conversation mode keeps the session between windows")
        XCTAssertEqual(channel.backend.closes, 0)
        XCTAssertFalse(channel.provider.isWindowOpenForTesting,
                       "a resolved window leaves no handler behind")

        channel.backend.emit(.transcriptFinal("no"))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(Self.count("command.matched", in: harness), 1,
                       "only the 'yes' that answered a window may ever have matched")

        // And nothing was queued for the next one, which answers by nod on its own terms.
        let second = Task { await harness.interaction.resolve(Self.approval) }
        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened, "the second approval opened no input window")
        harness.feed(TraceGenerators.doubleNod())
        let secondOutcome = await second.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(secondOutcome, .allow, "the stale 'no' must not have denied it")
        XCTAssertEqual(channel.backend.beganTurns, 2, "one turn per window")
        XCTAssertEqual(channel.backend.closes, 0, "and one session for both of them")
    }

    // MARK: - Turn detection, degraded and not

    /// The bug this path exists to fix, from the wearer's side.
    ///
    /// No AirPods streaming means no IMU endpoint, and on the realtime pipe a transcript
    /// does not exist until something commits the audio. Before the carve-out, "something"
    /// was only TapQ, so a wearer without AirPods spoke into a buffer that nobody committed
    /// until the window timed out — up to four minutes of a voice channel that looked alive
    /// and was not. Here the backend's own VAD commits, and the very next thing that happens
    /// is the ordinary match-on-transcript resolution the window has always used.
    ///
    /// The order of the assertions is the argument: the mode was chosen before the turn
    /// opened, the commit resolved nothing by itself, and the transcript resolved the window.
    func testWithNoWearerTurnSignalTheBackendsOwnVADCarriesTheWindowToAnAnswer() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in
                ProviderVoiceChannel(diagnosticSink: sink,
                                     backendCapabilities: ProviderVoiceChannel.realtimeCapabilities)
            }
        )
        let channel = try XCTUnwrap(harness.providerChannel)
        channel.isWearerTurnSignalLive = false

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")
        XCTAssertEqual(channel.backend.nativeTurnDetection, [true],
                       "the window degraded before its turn opened")
        XCTAssertEqual(channel.backend.beganTurns, 1)

        channel.backend.emit(.userAudioCommittedByBackend)
        XCTAssertTrue(channel.provider.isUserTurnActiveForCoordination,
                      "a commit ends an utterance, not the wearer's turn")
        XCTAssertTrue(channel.backend.endedTurns.isEmpty,
                      "and it is not TapQ ending anything")

        channel.backend.emit(.transcriptFinal("yes"))
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "the window resolved by transcript, not by timeout")
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "the match ended the turn, and never asked for a spoken reply")
        XCTAssertEqual(Self.count("turn.committed_by_backend", in: harness), 1)
        XCTAssertEqual(Self.count("turn_detection.native", in: harness), 1)
    }

    /// The other half, and the one that has to keep being true: with the IMU signal live,
    /// nothing about the wire traffic changes.
    ///
    /// The wearer nods this one through rather than speaking it, so the only thing the
    /// backend ever hears about is the mode — and the assertion is that the mode it heard is
    /// "TapQ still owns turns". A regression that degraded an IMU-armed run would hand a
    /// remote endpoint the shape of the wearer's speech for no reason at all.
    func testWithALiveWearerTurnSignalTheRealtimePathIsUntouched() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in
                ProviderVoiceChannel(diagnosticSink: sink,
                                     backendCapabilities: ProviderVoiceChannel.realtimeCapabilities)
            }
        )
        let channel = try XCTUnwrap(harness.providerChannel)
        channel.isWearerTurnSignalLive = true

        let decision = Task { await harness.interaction.resolve(Self.approval) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        XCTAssertEqual(channel.backend.nativeTurnDetection, [false])
        XCTAssertEqual(Self.count("turn_detection.native", in: harness), 0)

        harness.hear("yes")
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "one window, one turn, ended by TapQ exactly as before")
    }

    /// AirPods connect between two requests. The second window switches back on its own —
    /// nothing above the provider is told, and nothing is spoken about it.
    func testTheModeSwitchesBetweenWindowsWhenTheSignalComesBack() async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in
                ProviderVoiceChannel(diagnosticSink: sink,
                                     sessionPolicy: .conversation(idleClose: 3_600),
                                     backendCapabilities: ProviderVoiceChannel.realtimeCapabilities)
            }
        )
        let channel = try XCTUnwrap(harness.providerChannel)
        channel.isWearerTurnSignalLive = false

        let first = Task { await harness.interaction.resolve(Self.approval) }
        let firstOpened = await harness.waitForWindow(1)
        XCTAssertTrue(firstOpened, "the first approval opened no window")
        XCTAssertEqual(channel.backend.nativeTurnDetection, [true])
        channel.deliverAfterNativeCommit("yes")
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .allow)

        // The wearer puts their AirPods in.
        channel.isWearerTurnSignalLive = true

        let second = Task { await harness.interaction.resolve(Self.approval) }
        let secondOpened = await harness.waitForWindow(2)
        XCTAssertTrue(secondOpened, "the second approval opened no window")
        XCTAssertEqual(channel.backend.nativeTurnDetection, [true, false],
                       "the next window is TapQ's again, on the same conversation session")

        harness.hear("no")
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .deny)
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(channel.backend.closes, 0,
                       "the mode changed on the live session; nothing reconnected")
    }

    // MARK: - Helpers

    /// Drives one approval from wire bytes to wire bytes with the provider in the path, and
    /// asserts both the response and the turn accounting behind it.
    private func assertSpokenAnswerLeavesOnTheWire(
        partial: String,
        final: String,
        requestID: String,
        expected: BrokerResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let harness = DetectionPathHarness(
            voiceChannel: { sink in ProviderVoiceChannel(diagnosticSink: sink) }
        )
        let channel = try XCTUnwrap(harness.providerChannel, file: file, line: line)
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { [harness] in await harness.interaction.resolve($0) },
            onNotification: { _ in }
        )
        try server.start()
        defer { server.stop() }

        let exchange = Task {
            try await transport.deliver(Data(Self.approvalRequestJSON(id: requestID).utf8))
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window", file: file, line: line)
        XCTAssertEqual(channel.backend.beganTurns, 1,
                       "one window opens exactly one turn", file: file, line: line)

        harness.hear(partial: partial, then: final)

        let responseData = try await exchange.value
        harness.assertWatchdogDidNotFire(file: file, line: line)
        let response = try JSONDecoder().decode(BrokerResponse.self, from: responseData)
        XCTAssertEqual(response, expected, file: file, line: line)
        XCTAssertEqual(Self.count("command.matched", in: harness), 1,
                       "the partial resolved nothing; only the final may have matched",
                       file: file, line: line)
        XCTAssertEqual(channel.backend.endedTurns, [false],
                       "the match must end the turn, and never ask for a spoken reply",
                       file: file, line: line)
        XCTAssertEqual(channel.backend.closes, 1,
                       "a per-window session closes with the window it opened for",
                       file: file, line: line)
    }

    private static func count(_ event: String, in harness: DetectionPathHarness) -> Int {
        harness.diagnostics.events.filter { $0.name == event }.count
    }

    // MARK: - Fixtures

    private static let approval = ApprovalRequest(
        id: "r1", sessionID: "s1", toolName: "Bash",
        summary: "run the test suite", detail: "swift test"
    )

    /// Wire protocol v4, `pre_tool_use` outside auto mode, so the broker delegates to the
    /// approval closure rather than auto-passing.
    private static func approvalRequestJSON(id: String) -> String {
        """
        {"type":"approval.request","token":"tok","protocol_version":4,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","tool_name":"Bash","tool_input":{"command":"swift test"},\
        "summary":"run the test suite","detail":"swift test",\
        "approval_source":"pre_tool_use","request_id":"\(id)"}
        """
    }
}
