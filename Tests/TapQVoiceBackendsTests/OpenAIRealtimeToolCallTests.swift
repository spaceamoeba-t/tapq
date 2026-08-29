import XCTest
import Foundation
@testable import TapQVoiceBackends
import TapQContracts

/// Tool calling through the realtime adapter's response state machine.
///
/// The state machine is the reason this file exists separately from the message codec's. A
/// function call is an item *inside* a response TapQ asked for, so it has to thread past the
/// activeResponseID bookkeeping, the cancel tombstones, and the "a response TapQ never
/// requested" check without disturbing any of them.
@MainActor
final class OpenAIRealtimeToolCallTests: XCTestCase {
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
    }

    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var toolCalls: [VoiceToolCall] {
            events.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
    }

    private func makeBackend(_ server: ScriptedRealtimeServer,
                             sink: RecordingSink = RecordingSink())
        -> OpenAIRealtimeVoiceBackend {
        OpenAIRealtimeVoiceBackend(transport: server, timeout: 1, diagnosticSink: sink)
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func pcm16(_ frames: Int) -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data(repeating: 0x11, count: frames * 2),
                        format: OpenAIRealtimeVoiceBackend.audioFormat, timestamp: 0)
    }

    private let tools = [
        VoiceToolDeclaration(name: "approve", description: "the wearer authorized it"),
        VoiceToolDeclaration(
            name: "select_item", description: "the wearer chose an entry",
            parameters: [VoiceToolParameter(name: "index", kind: .integer,
                                            description: "one-based position")]
        ),
    ]

    private func sessionUpdates(_ server: ScriptedRealtimeServer) -> [[String: Any]] {
        server.sent
            .filter { $0["type"] as? String == "session.update" }
            .compactMap { $0["session"] as? [String: Any] }
    }

    /// Opens a session with a turn committed and a response in flight — the state a tool call
    /// actually arrives in.
    private func openRespondingTurn(_ backend: OpenAIRealtimeVoiceBackend,
                                    collecting log: EventLog) async throws {
        try await backend.open { log.append($0) }
        backend.beginUserTurn()
        backend.sendAudio(pcm16(2_400))
        backend.endUserTurn(expectingResponse: true)
        await settle()
    }

    // MARK: - Declaring

    /// Declared before `open`, so the tool set rides the very first frame — the same frame
    /// that turns the service's own VAD off. Folding it in costs nothing and leaves no
    /// instant in a session's life where the model can hear the wearer and not act.
    func testToolsDeclaredBeforeOpenRideTheHandshakeFrame() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        backend.declareTools(tools)

        try await backend.open { _ in }

        XCTAssertEqual(server.sentTypes, ["session.update"], "no extra frame was needed")
        let session = try XCTUnwrap(sessionUpdates(server).first)
        XCTAssertEqual((session["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["approve", "select_item"])
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
    }

    /// A declaration on a live session is one more `session.update`, and it restates turn
    /// detection rather than merging over it: GA's update is a merge, and an omitted
    /// `turn_detection` would leave whatever mode the session had drifted into.
    func testDeclaringOnALiveSessionSendsOneUpdateAndKeepsManualTurns() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await backend.open { _ in }

        backend.declareTools(tools)
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "session.update"])
        let latest = try XCTUnwrap(sessionUpdates(server).last)
        XCTAssertTrue(ScriptedRealtimeServer.inputAudio(of: latest)?["turn_detection"] is NSNull)
        XCTAssertTrue(sink.names.contains("tool.declared"))
    }

    /// Idempotent: re-declaring the same set sends nothing. A provider that grounds every
    /// turn would otherwise put a redundant frame on the wire per window.
    func testRedeclaringTheSameToolsSendsNothing() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        backend.declareTools(tools)
        try await backend.open { _ in }

        backend.declareTools(tools)
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update"])
    }

    /// Grounding is a `session.update` too, and only when it changed.
    func testInstructionsAreUpdatedOnlyWhenTheyChange() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        try await backend.open { _ in }

        backend.updateInstructions("A TapQ window is open.")
        await settle()
        backend.updateInstructions("A TapQ window is open.")
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "session.update"])
        XCTAssertEqual(sessionUpdates(server).last?["instructions"] as? String,
                       RealtimeDefaults.instructions(grounding: "A TapQ window is open."))
    }

    /// Grounding is *appended* to the standing rules; it never replaces them.
    ///
    /// This is the ordering `RealtimeDefaults.instructions(grounding:)` exists to enforce,
    /// and until 2026-08-28 nothing called it: the provider is portable and passes the
    /// window brief alone, so the first grounded turn of every session overwrote the whole
    /// `instructions` field with that brief. A session in that state has no rule against
    /// firing a tool on a word it merely heard, no rule against narrating its own tool
    /// results, and — since the audible-refusal decision — no rule requiring a directed
    /// request to be answered out loud.
    func testGroundingNeverReplacesTheStandingRules() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        try await backend.open { _ in }

        backend.updateInstructions("A TapQ window is open.")
        await settle()

        let sent = try XCTUnwrap(sessionUpdates(server).last?["instructions"] as? String)
        XCTAssertTrue(sent.contains("A TapQ window is open."), "the window brief is missing")
        XCTAssertTrue(sent.contains(RealtimeDefaults.toolPolicy),
                      "the tool policy was overwritten by the window brief")
        XCTAssertTrue(sent.contains(RealtimeDefaults.baseInstructions),
                      "the base instructions were overwritten by the window brief")
        XCTAssertTrue(sent.contains("you must answer them out loud"),
                      "the audible-refusal rule never reached the live session")

        // Re-grounding replaces only the brief, and the rules survive every one of them.
        backend.updateInstructions("No TapQ window is open.")
        await settle()
        let regrounded = try XCTUnwrap(sessionUpdates(server).last?["instructions"] as? String)
        XCTAssertTrue(regrounded.contains("No TapQ window is open."))
        XCTAssertFalse(regrounded.contains("A TapQ window is open."),
                       "the stale brief outlived the turn it described")
        XCTAssertTrue(regrounded.contains(RealtimeDefaults.toolPolicy))
    }

    /// The instructions carry what the wearer is being asked to authorize. A diagnostic that
    /// quoted them would put a request's own words in the log the speech-safe surface exists
    /// to keep them out of.
    func testGroundingIsLoggedByLengthAndNotByContent() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await backend.open { _ in }

        backend.updateInstructions("Delete /Users/someone/secrets? Nod or say yes.")
        await settle()

        XCTAssertTrue(sink.names.contains("session.instructions_updated"))
    }

    // MARK: - Receiving a call

    /// The ordinary path: a response TapQ asked for produces a call, the call is reported,
    /// and the response then completes exactly as any other does.
    func testAFunctionCallInsideARequestedResponseIsReported() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await openRespondingTurn(backend, collecting: log)

        server.push(RealtimeToolFrame.functionCall(
            callID: "call_1", name: "select_item", arguments: #"{"index":2}"#))
        await settle()

        XCTAssertEqual(log.toolCalls,
                       [VoiceToolCall(callID: "call_1", name: "select_item",
                                      argumentsJSON: #"{"index":2}"#)])
        XCTAssertTrue(sink.names.contains("tool.called"))

        // The response that carried it still owes a terminal frame, and it settles normally:
        // a call is an item inside a response, not a response of its own.
        server.push(RealtimeFrame.responseDone(id: server.currentResponseID ?? "resp_1"))
        await settle()
        XCTAssertEqual(log.failures, [], "a tool call must not disturb the response machine")
        XCTAssertEqual(backend.turnStateForTesting, .open)
    }

    /// Answering a call is legal while the peer is still speaking, which is the normal case:
    /// `response.output_item.done` precedes `response.done`. A conversation item is not a
    /// response, and the half-duplex rule has nothing to say about it.
    func testAToolResultIsSentWhileTheResponseIsStillInFlight() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await openRespondingTurn(backend, collecting: log)

        server.push(RealtimeToolFrame.functionCall(
            callID: "call_1", name: "approve", arguments: ""))
        await settle()
        XCTAssertEqual(backend.turnStateForTesting, .responding)

        backend.sendToolResult(callID: "call_1", output: "Approved.")
        await settle()

        XCTAssertEqual(server.sentTypes.last, "conversation.item.create")
        XCTAssertEqual(log.failures, [])
        XCTAssertTrue(sink.names.contains("tool.result_sent"))
    }

    /// No `response.create` follows a result. What the wearer hears about a tool is a
    /// sentence TapQ wrote, read back verbatim on the scripted channel.
    func testAnsweringACallStartsNoResponse() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let backend = makeBackend(server)
        try await openRespondingTurn(backend, collecting: log)
        let before = server.sentTypes.filter { $0 == "response.create" }.count

        server.push(RealtimeToolFrame.functionCall(callID: "c1", name: "approve", arguments: ""))
        await settle()
        backend.sendToolResult(callID: "c1", output: "Approved.")
        await settle()

        XCTAssertEqual(server.sentTypes.filter { $0 == "response.create" }.count, before)
    }

    /// The exact ordering the 2026-08-28 hardware defect ran through, scripted end to end: a
    /// response carrying a function call, answered and finished, and then a *second*,
    /// separate response carrying the sentence TapQ wrote about it.
    ///
    /// What is asserted is the naming, because the naming is what the caller above binds a
    /// suppression mark to. Two responses, two ids, and `nil` between them — a caller that
    /// meant to abandon the first can say so without touching the second, which is TapQ's
    /// own voice and must reach the wearer.
    func testAToolCallResponseAndTheScriptedSentenceAfterItAreNamedSeparately() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let backend = makeBackend(server)
        try await openRespondingTurn(backend, collecting: log)

        let callResponse = backend.activeResponseIdentity
        XCTAssertNotNil(callResponse, "the peer names the response the call arrives in")

        server.push(RealtimeToolFrame.functionCall(
            callID: "call_1", name: "approve", arguments: ""))
        await settle()
        backend.sendToolResult(callID: "call_1", output: "Approved.")
        await settle()
        XCTAssertEqual(backend.activeResponseIdentity, callResponse,
                       "answering a call does not retire the response it arrived in")

        server.push(RealtimeFrame.responseDone(id: callResponse ?? ""))
        await settle()
        XCTAssertNil(backend.activeResponseIdentity,
                     "a settled response leaves no id for a later mark to match")

        // TapQ's own sentence, on its own response.
        backend.requestScriptedSpeech(text: "Codex is not in this run.")
        await settle()
        let scriptedResponse = backend.activeResponseIdentity
        XCTAssertNotNil(scriptedResponse)
        XCTAssertNotEqual(scriptedResponse, callResponse,
                          "TapQ's sentence must be a different response, differently named")

        server.push(RealtimeFrame.audioDelta(Data([0x01, 0x02])))
        server.push(RealtimeFrame.responseDone(id: scriptedResponse ?? ""))
        await settle()
        XCTAssertEqual(log.failures, [])
        XCTAssertEqual(backend.turnStateForTesting, .open)
    }

    // MARK: - The no-AirPods path

    /// In native-turn mode the service commits the buffer itself and creates no response, so
    /// TapQ asks for one explicitly. No second commit goes with it: the buffer is already
    /// gone, and a commit over an empty one is an `error` frame that ends the session.
    func testRequestingAModelTurnSendsOnlyAResponseCreate() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        backend.setNativeTurnDetection(true)
        try await backend.open { log.append($0) }
        backend.beginUserTurn()
        backend.sendAudio(pcm16(2_400))
        await settle()

        // The service's own VAD ends the utterance; TapQ ends its turn over the empty buffer
        // and asks for the model's.
        server.commitFromServerVAD()
        await settle()
        backend.endUserTurn(expectingResponse: false)
        let created = backend.requestModelTurn()
        await settle()

        XCTAssertTrue(created)
        XCTAssertEqual(server.sentTypes.last, "response.create")
        XCTAssertEqual(server.sentTypes.filter { $0 == "input_audio_buffer.commit" }.count, 0,
                       "the service already took the buffer")
        XCTAssertNil(server.responseObject(at: 0)?["instructions"],
                     "the session's own instructions are what the model must read")
        XCTAssertEqual(log.failures, [])
        XCTAssertTrue(sink.names.contains("tool.model_turn_requested"))
    }

    /// A second ask while one is running is the half-duplex rule being broken, and it fails
    /// the session rather than quietly producing two responses.
    func testAsThatArriveDuringAResponseAreAViolation() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let backend = makeBackend(server)
        try await openRespondingTurn(backend, collecting: log)

        XCTAssertFalse(backend.requestModelTurn())
        await settle()

        XCTAssertEqual(log.failures.count, 1)
    }

    // MARK: - Barge-in and tombstones

    /// The frame a cancelled response can still produce that would *do* something. The
    /// wearer talked over the model, or the window resolved by nod while it was deciding; in
    /// both cases the response has lost its audience, and executing its approval a beat later
    /// would authorize something nobody was waiting on any more.
    func testACallFromACancelledResponseIsDroppedAndNotAnswered() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesCancelWithDone = false
        let log = EventLog()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await openRespondingTurn(backend, collecting: log)
        let cancelled = try XCTUnwrap(server.currentResponseID)

        backend.cancelResponse()
        await settle()
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [cancelled])

        // The tail of the cancelled response, carrying the call it had already produced.
        server.push(RealtimeToolFrame.functionCall(
            callID: "call_1", name: "approve", arguments: ""))
        await settle()

        XCTAssertEqual(log.toolCalls, [], "a cancelled response's approval must not be executed")
        XCTAssertTrue(sink.names.contains("tool.call_dropped_cancelled"))

        // The tombstone still retires on the done it was waiting for, unchanged.
        server.push(RealtimeFrame.responseDone(id: cancelled))
        await settle()
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [])
        XCTAssertEqual(log.failures, [])
    }

    /// The same rule for a peer that named nothing: TapQ has an outstanding cancel and no way
    /// to tell whether this call belongs to it, and "might be from a response I abandoned" is
    /// abandoned.
    func testACallDuringAnUnnamedCancelIsAlsoDropped() async throws {
        let server = ScriptedRealtimeServer()
        server.namesResponses = false
        server.acknowledgesCancelWithDone = false
        let log = EventLog()
        let backend = makeBackend(server)
        try await openRespondingTurn(backend, collecting: log)

        backend.cancelResponse()
        await settle()
        server.push(RealtimeToolFrame.functionCall(callID: "c1", name: "approve", arguments: ""))
        await settle()

        XCTAssertEqual(log.toolCalls, [])
    }

    // MARK: - Malformed traffic

    /// A half-formed call ends the session, at the decoder, before anything can be executed
    /// from it. Fail-loud posture unchanged: there is no reading of "a function call with no
    /// name" that is safe to guess at.
    func testAHalfFormedCallFailsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let log = EventLog()
        let backend = makeBackend(server)
        try await openRespondingTurn(backend, collecting: log)

        server.push(
            #"{"type":"response.output_item.done","item":{"type":"function_call","name":"approve"}}"#)
        await settle()

        XCTAssertEqual(log.failures.count, 1)
        guard case .protocolViolation? = log.failures.first else {
            return XCTFail("expected a protocol violation, got \(log.failures)")
        }
    }

    /// A result for a session that died between the call and the answer touches nothing. It
    /// is the one path that could turn a closed session into a reported failure, and nothing
    /// is waiting on the far side of a socket that is gone.
    func testAResultAfterTheSessionClosedIsARecordedNoOp() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await backend.open { _ in }
        backend.close()

        backend.sendToolResult(callID: "c1", output: "Approved.")
        await settle()

        XCTAssertFalse(server.sentTypes.contains("conversation.item.create"))
        XCTAssertTrue(sink.names.contains("tool.result_skipped"))
    }

    // MARK: - Capability

    func testTheAdapterAdvertisesToolCalling() async {
        let backend = makeBackend(ScriptedRealtimeServer())
        XCTAssertTrue(backend.capabilities.supportsToolCalling)
    }
}
