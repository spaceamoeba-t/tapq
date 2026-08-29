import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The suppression mechanism, and the three things it is not allowed to do.
///
/// It exists for one job: a window resolved while the model was answering the wearer means
/// that answer has lost its audience, so it is abandoned rather than played. Every test here
/// is a boundary of that job, and each one is a live trace rather than a hypothesis.
///
/// The 2026-08-28 hardware report is `testTheRefusalAfterAToolCallIsHeard`: the wearer asked
/// TapQ to hand an instruction to an agent that was not in the run, TapQ refused correctly,
/// spoke the refusal on its own scripted channel — and the wearer heard nothing at all. The
/// log showed no cancel, no suppression, and a response that streamed to completion, which is
/// what made it hard to read: the sentence was not stopped, it was *discarded*, twice over,
/// by two mechanisms that both believed a window ending was reason enough.
@MainActor
final class VoiceResponseSuppressionTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }

        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage.map(\.name)
        }

        func count(_ name: String) -> Int { names.filter { $0 == name }.count }

        func fields(_ name: String) -> [[String: String]] {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.name == name }.map(\.fields)
        }
    }

    /// A duplex, tool-calling, response-naming backend — the shape of the realtime adapter,
    /// including the one thing the provider now cross-checks against: it names its responses.
    @MainActor
    private final class NamingToolBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true,
                                                    supportsNativeTurnDetection: true,
                                                    supportsToolCalling: true)

        /// What `response.created` would have named. The test moves it exactly where the
        /// service would.
        var activeResponseIdentity: String?

        private(set) var scriptedSpeech: [String] = []
        private(set) var toolResults: [(callID: String, output: String)] = []
        private(set) var cancels = 0
        private(set) var modelTurnRequests = 0
        private(set) var endUserTurnExpectations: [Bool] = []
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            handler = onEvent
        }
        func close() { handler = nil }
        func beginUserTurn() {}

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            endUserTurnExpectations.append(expectingResponse)
            if expectingResponse { activeResponseIdentity = "resp_turn_\(endUserTurnExpectations.count)" }
            return expectingResponse
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) { activeResponseIdentity = "resp_grounded" }

        func requestScriptedSpeech(text: String) {
            scriptedSpeech.append(text)
            activeResponseIdentity = "resp_scripted_\(scriptedSpeech.count)"
        }

        func cancelResponse() {
            cancels += 1
            activeResponseIdentity = nil
        }

        func setNativeTurnDetection(_ enabled: Bool) {}

        @discardableResult
        func requestModelTurn() -> Bool {
            modelTurnRequests += 1
            activeResponseIdentity = "resp_model_\(modelTurnRequests)"
            return true
        }

        func declareTools(_ tools: [VoiceToolDeclaration]) {}
        func updateInstructions(_ instructions: String) {}
        func sendToolResult(callID: String, output: String) {
            toolResults.append((callID, output))
        }

        func emit(_ event: VoiceBackendEvent) { handler?(event) }

        /// The peer finishing a response: the id is forgotten, then the terminal frame goes up.
        func completeResponse() {
            activeResponseIdentity = nil
            emit(.responseCompleted)
        }
    }

    @MainActor
    private final class FakePlayback: VoiceResponseAudioPlaying {
        private(set) var isPlaying = false
        var onPlayingChange: (@MainActor (Bool) -> Void)?
        private(set) var enqueued = 0
        private(set) var finishStreamCount = 0
        private(set) var stopAndFlushCount = 0

        func enqueue(_ chunk: VoiceAudioChunk) {
            enqueued += 1
            guard !isPlaying else { return }
            isPlaying = true
            onPlayingChange?(true)
        }

        func finishStream() { finishStreamCount += 1 }

        func stopAndFlush() {
            stopAndFlushCount += 1
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }
    }

    private func makeProvider(_ backend: NamingToolBackend,
                              playback: FakePlayback,
                              sink: RecordingSink) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left running
            // in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink)
    }

    private func settle() async { for _ in 0..<6 { await Task.yield() } }

    private func chunk() -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data([0, 1, 2, 3]),
                        format: .pcm16Mono24k,
                        timestamp: 0)
    }

    private func queueInstruction(_ text: String) -> VoiceBackendEvent {
        .toolCall(VoiceToolCall(callID: "call_1", name: "queue_instruction",
                                argumentsJSON: #"{"text":"\#(text)"}"#))
    }

    // MARK: - (a) The hardware trace

    /// The whole report, start to finish: a window resolved by a tool call, the refusal TapQ
    /// wrote about it, and a wearer who must hear that refusal.
    ///
    /// Every step is from the 2026-08-28 log. The backend's own VAD committed the wearer's
    /// sentence; TapQ asked the model to act on it; the model called `queue_instruction`; the
    /// call resolved the window through both resolve paths; the runtime refused it (the agent
    /// was not in this run) and queued its own sentence behind the response still in flight;
    /// that response finished; the sentence went out; its audio arrived; and the next window
    /// came round and closed while the player still held every sample of it.
    func testTheRefusalAfterAToolCallIsHeard() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        var delivered: [VoiceCommand] = []

        provider.start { command in
            delivered.append(command)
            // The interaction layer acts on the command and stops the provider: the second
            // of the two resolve paths, a beat after `deliver` closed the window itself.
            provider.stop()
        }
        await settle()

        backend.emit(.userAudioCommittedByBackend)
        backend.emit(queueInstruction("tell CodeX to run git ls"))
        XCTAssertEqual(delivered, [.beginInstruction("tell CodeX to run git ls")])
        XCTAssertEqual(backend.toolResults.count, 1, "the model is owed exactly one result")

        // The refusal. It has nowhere to go yet — the function-call response is still open.
        XCTAssertEqual(provider.speakScripted("Codex is not in this run, so nothing was queued."),
                       .queued)
        XCTAssertTrue(backend.scriptedSpeech.isEmpty)

        // The function-call response finishes; the refusal takes the pipe.
        backend.completeResponse()
        await settle()
        XCTAssertEqual(backend.scriptedSpeech,
                       ["Codex is not in this run, so nothing was queued."])

        // The next listening window comes round and defers behind TapQ's sentence.
        provider.start { _ in }
        await settle()
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))

        // The refusal's audio arrives. This is the assertion the wearer cares about.
        backend.emit(.audio(chunk()))
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 2,
                       "TapQ's own refusal was dropped instead of played")
        XCTAssertEqual(backend.cancels, 0, "nothing cancelled TapQ's own sentence")
        XCTAssertFalse(sink.names.contains("audio.dropped_no_window"))

        // The peer delivers a sentence far faster than it takes to say: the response is over
        // on the wire while every sample is still queued in the player.
        backend.completeResponse()
        await settle()
        let flushesBefore = playback.stopAndFlushCount

        // And now the window closes. Before the fix this threw the whole sentence away.
        provider.stop()
        XCTAssertEqual(playback.stopAndFlushCount, flushesBefore,
                       "a window ending flushed TapQ's own sentence out of the player")
        XCTAssertTrue(sink.names.contains("playback.flush_skipped_scripted"))
    }

    // MARK: - (a′) The audible refusal rides the same channel

    /// A wearer says "approve" into a quiet room, and hears an answer.
    ///
    /// Both halves are asserted because both are the decision (2026-08-28): the model is
    /// still told the call did nothing — leaving it parked would hang the channel — *and*
    /// the wearer is told out loud. Until this test the first happened and the second did
    /// not, and from where the wearer stands the difference between "TapQ refused me" and
    /// "TapQ is broken" was nothing at all.
    func testApproveWithNoWindowOpenSpeaksAndStillAnswersTheModel() async {
        let backend = NamingToolBackend()
        let provider = makeProvider(backend, playback: FakePlayback(), sink: RecordingSink())
        defer { provider.shutdown() }

        // The session outlives its windows under the conversation policy, which is what
        // makes this case reachable at all: the window is gone, the microphone and the model
        // are not, and the call lands with nothing armed to receive it.
        provider.start { _ in }
        await settle()
        provider.stop()
        await settle()

        backend.emit(.toolCall(VoiceToolCall(callID: "call_1", name: "approve",
                                             argumentsJSON: "")))
        await settle()

        XCTAssertEqual(backend.toolResults.count, 1,
                       "the model must not be left parked on an unanswered call")
        XCTAssertEqual(backend.toolResults.first?.callID, "call_1")
        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.nothingWaitingNotice],
                       "the wearer heard nothing about a request they made out loud")
    }

    /// The same for `deny` and `select_item` — the other two rows that used to be silent.
    func testTheOtherTwoAnswersAlsoSpeakWithNoWindowOpen() async {
        for call in [VoiceToolCall(callID: "c", name: "deny", argumentsJSON: ""),
                     VoiceToolCall(callID: "c", name: "select_item",
                                   argumentsJSON: #"{"index":2}"#)] {
            let backend = NamingToolBackend()
            let provider = makeProvider(backend, playback: FakePlayback(),
                                        sink: RecordingSink())
            provider.start { _ in }
            await settle()
            provider.stop()
            await settle()

            backend.emit(.toolCall(call))
            await settle()
            XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.nothingWaitingNotice],
                           "\(call.name) refused in silence")
            XCTAssertEqual(backend.toolResults.count, 1, "\(call.name) left the model parked")
            provider.shutdown()
        }
    }

    /// The precondition, stated as a test: a refusal spoken in the exact position that used
    /// to eat sentences is heard to the end.
    ///
    /// That position is the one the 2026-08-28 trace above found — a window resolved by a
    /// tool call, TapQ's own sentence queued behind the response the call arrived in, and
    /// then the window closing while the player still holds the audio. Every new refusal
    /// sentence rides this channel, so it is asserted with a refusal rather than with the
    /// hand-written string the original trace used.
    func testARefusalSpokenRightAfterAToolResolvedWindowCompletes() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in provider.stop() }
        await settle()

        // The window resolves by tool call, exactly as the trace did: the service's own
        // endpoint commits, TapQ asks the model to act on the segment, and the call arrives
        // inside the response that ask created.
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(queueInstruction("run the tests again"))

        // …and the refusal for it is written while that response is still open.
        XCTAssertEqual(provider.speakScripted(VoiceIntentTools.notListeningNotice), .queued)
        XCTAssertTrue(backend.scriptedSpeech.isEmpty, "it must wait, not fall back")

        backend.completeResponse()
        await settle()
        XCTAssertEqual(backend.scriptedSpeech, [VoiceIntentTools.notListeningNotice])

        // Its audio plays, and the window closing does not throw it away.
        backend.emit(.audio(chunk()))
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 2, "the refusal was dropped instead of played")
        XCTAssertEqual(backend.cancels, 0, "something cancelled TapQ's own refusal")

        let flushesBefore = playback.stopAndFlushCount
        provider.stop()
        XCTAssertEqual(playback.stopAndFlushCount, flushesBefore,
                       "a window ending flushed the refusal out of the player")
        XCTAssertFalse(sink.names.contains("audio.dropped_no_window"))
    }

    /// The mark, when one is armed, names the response it was armed against — and is spent
    /// against that response only. A mark that outlived its response used to be free to fire
    /// on the next one, and the next one is TapQ's own voice more often than not.
    func testASuppressionMarkNeverFiresOnALaterResponse() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.userAudioCommittedByBackend)
        let armedAgainst = backend.activeResponseIdentity
        backend.emit(queueInstruction("ship it"))

        XCTAssertEqual(sink.count("response.suppression_armed"), 1)
        XCTAssertEqual(sink.fields("response.suppression_armed").first?["response_id"],
                       armedAgainst)

        // That response ends without ever producing audio. The mark dies with it.
        backend.completeResponse()
        await settle()
        XCTAssertEqual(sink.fields("response.suppression_retired").first?["by"],
                       "response_completed")

        // A wholly different response — TapQ's own — now speaks.
        provider.speakScripted("Queued for Claude.")
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)
        XCTAssertEqual(backend.cancels, 0)
    }

    // MARK: - (b) One ending per window

    /// `deliver` ends the window and the interaction layer's `stop()` ends it again. Two
    /// paths, one ending: the second is a recorded no-op rather than a second arm over a
    /// state machine that has already moved.
    func testTheSecondResolvePathDoesNotArmAgain() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in provider.stop() }
        await settle()
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(queueInstruction("ship it"))

        XCTAssertEqual(sink.count("response.suppression_armed"), 1,
                       "both resolve paths armed the same suppression")
        XCTAssertEqual(sink.count("window.end_skipped_already_ended"), 1,
                       "the second ending should be recorded, not silent")
        XCTAssertEqual(sink.fields("window.end_skipped_already_ended").first?["suppress"],
                       "true")
    }

    /// The no-op is scoped to one window, not to the provider. A genuinely new window ends
    /// on its own terms.
    func testANewWindowMayEndAgain() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in provider.stop() }
        await settle()
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(queueInstruction("ship it"))
        backend.completeResponse()
        await settle()

        provider.start { _ in }
        await settle()
        XCTAssertTrue(provider.isWindowOpenForTesting)
        provider.stop()
        XCTAssertFalse(provider.isWindowOpenForTesting,
                       "a second window must still be closable")
    }

    // MARK: - (c) The case the mechanism exists for

    /// A wearer-turn response that has started speaking when its window resolves is cancelled
    /// on the spot. Nothing in this fix relaxes that.
    func testAnAudibleWearerTurnResponseIsStillCancelledOnResolve() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        XCTAssertEqual(backend.endUserTurnExpectations, [true],
                       "the model path commits asking for a response")
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)

        provider.stop()
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertTrue(sink.names.contains("response.suppressed_match_resolved"))
        XCTAssertGreaterThan(playback.stopAndFlushCount, 0,
                             "the model's answer keeps no place in the player")
    }

    /// The other half of the same case: the response exists but has not spoken yet, so the
    /// mark is armed and the first audio of *that* response is what spends it.
    func testAPendingWearerTurnResponseIsSuppressedOnItsFirstAudio() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        provider.stop()
        XCTAssertEqual(sink.count("response.suppression_armed"), 1)

        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 0, "a suppressed response must not be played")
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertEqual(sink.fields("response.suppressed_on_first_audio").first?["cancelled"],
                       "true")
    }

    // MARK: - (d) Barge-in

    /// The wearer talking over TapQ's own sentence still stops it. The scripted invariant is
    /// about a *window resolving* silencing TapQ, never about the wearer interrupting.
    func testBargeInStillCancelsScriptedSpeech() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertEqual(provider.speakScripted("Claude is waiting on a Bash command."), .spoken)
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)

        provider.cancelActiveResponse()
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertFalse(playback.isPlaying, "barge-in must flush what is queued")
        XCTAssertTrue(sink.names.contains("response.cancelled_by_coordinator"))
    }

    // MARK: - The scripted invariant, stated directly

    /// A window resolving while TapQ's own sentence is pending arms nothing at all.
    func testAResolvingWindowNeverArmsAgainstScriptedSpeech() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        // TapQ speaks between windows; a new window opens and is resolved by a tool call
        // while that sentence is still on its way to the wearer.
        XCTAssertEqual(provider.speakScripted("Claude is waiting."), .spoken)
        provider.start { _ in }
        await settle()
        backend.emit(queueInstruction("ship it"))

        XCTAssertEqual(sink.count("response.suppression_armed"), 0)
        XCTAssertTrue(sink.names.contains("response.suppression_skipped_scripted"))

        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1, "TapQ's sentence must still be played")
        XCTAssertEqual(backend.cancels, 0)
    }

    /// A sentence spoken with no window anywhere — a notice between windows, the reason
    /// `openSessionForSpeech` exists — reaches the player.
    func testScriptedSpeechWithNoWindowOpenIsStillPlayed() async {
        let backend = NamingToolBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertFalse(provider.isWindowOpenForTesting)

        XCTAssertEqual(provider.speakScripted("Claude finished the tests."), .spoken)
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1,
                       "a sentence spoken between windows was thrown away")
        XCTAssertFalse(sink.names.contains("audio.dropped_no_window"))
    }
}
