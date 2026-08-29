import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// What happens to a realtime session when nothing can play what it says back.
///
/// The bug these cover: a playback engine that could not start left the run half-alive —
/// the microphone pumped, transcripts matched, and every sentence routed to the backend's
/// voice was silently inaudible, the "Voice session ended." announcement included. The
/// wrapper's job is to make that a session that *ended*, loudly, and to hand the composition
/// the same mid-run drop it already knows how to degrade through.
@MainActor
final class PlaybackDependentVoiceBackendTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var names: [String] { events.map(\.name) }

        func event(named name: String) -> TapQDiagnosticEvent? {
            events.first { $0.name == name }
        }
    }

    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private let speakingCapabilities = VoiceBackendCapabilities(
        supportsBargeIn: true, producesAudio: true, duplex: true)

    private func makeWrapper(sink: RecordingSink = RecordingSink())
        -> (ScriptedVoiceBackend, PlaybackDependentVoiceBackend) {
        let inner = ScriptedVoiceBackend(name: "primary", capabilities: speakingCapabilities)
        return (inner, PlaybackDependentVoiceBackend(inner: inner, diagnosticSink: sink))
    }

    // MARK: - A run that never loses its output is untouched

    func testAWorkingOutputCostsTheSessionNothing() async throws {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        wrapper.sendAudio(VoiceAudioChunk(data: Data(repeating: 7, count: 64),
                                          format: .pcm16Mono24k, timestamp: 0))
        wrapper.endUserTurn(expectingResponse: true)
        inner.emit(.transcriptFinal("approve"))
        inner.emit(.responseCompleted)

        XCTAssertEqual(inner.calls,
                       [.open, .beginUserTurn, .sendAudio(64), .endUserTurn])
        XCTAssertTrue(events.failures.isEmpty)
        XCTAssertFalse(sink.names.contains("session.terminated"))
        XCTAssertFalse(sink.names.contains("playback.unavailable"))
        XCTAssertTrue(inner.isOpen)
    }

    func testEveryCallAndEventPassesThroughUnchanged() async throws {
        let (inner, wrapper) = makeWrapper()
        let events = EventLog()

        XCTAssertEqual(wrapper.capabilities, speakingCapabilities)
        try await wrapper.open { events.append($0) }
        wrapper.setNativeTurnDetection(true)
        wrapper.requestResponse(text: "Waiting on the build.")
        wrapper.cancelResponse()

        XCTAssertEqual(inner.nativeTurnDetection, [true])
        XCTAssertEqual(inner.calls,
                       [.open, .requestResponse("Waiting on the build."), .cancelResponse])
        // The cancel ack the scripted backend replays reached the caller.
        XCTAssertEqual(events.events, [.responseCompleted])
    }

    // MARK: - The engine could not start

    func testPlaybackThatCannotStartTerminatesTheSession() async throws {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.notePlaybackUnavailable(detail: "playback_setup: -10868")

        XCTAssertEqual(events.failures.count, 1,
                       "the session ends rather than continuing without a voice")
        XCTAssertFalse(inner.isOpen, "the inner pipe — and its microphone — is closed")
        XCTAssertEqual(inner.calls, [.open, .close])
    }

    func testTerminationNamesBothCauseAndConsequenceAtErrorLevel() async throws {
        let sink = RecordingSink()
        let (_, wrapper) = makeWrapper(sink: sink)

        try await wrapper.open { _ in }
        wrapper.notePlaybackUnavailable(detail: "playback_setup: -10868")

        guard let cause = sink.event(named: "playback.unavailable"),
              let consequence = sink.event(named: "session.terminated") else {
            return XCTFail("expected both a cause and a consequence in the log")
        }
        XCTAssertEqual(cause.level, .error)
        XCTAssertEqual(consequence.level, .error)
        XCTAssertEqual(cause.fields["detail"], "playback_setup: -10868")
        XCTAssertEqual(cause.fields["consequence"], "voice_disabled_for_run")
        XCTAssertEqual(consequence.fields["reason"], "playback_unavailable")
    }

    // MARK: - The engine died mid-run

    func testPlaybackDyingMidTurnTerminatesTheSameWay() async throws {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        wrapper.notePlaybackUnavailable(detail: "playback_schedule: engine stopped")

        XCTAssertEqual(events.failures.count, 1)
        XCTAssertFalse(inner.isOpen)
        XCTAssertTrue(sink.names.contains("session.terminated"))
        // No half-alive state: the turn went down with the session it belonged to.
        XCTAssertFalse(inner.isTurnActive)
    }

    func testASecondReportIsNotASecondTermination() async throws {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.notePlaybackUnavailable(detail: "first")
        wrapper.notePlaybackUnavailable(detail: "second")

        XCTAssertEqual(events.failures.count, 1)
        XCTAssertEqual(sink.names.filter { $0 == "session.terminated" }.count, 1)
        XCTAssertEqual(sink.names.filter { $0 == "playback.unavailable" }.count, 1)
        XCTAssertEqual(inner.calls, [.open, .close])
    }

    func testAReportWithNoSessionOpenStillRecordsTheDowngrade() async {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)

        wrapper.notePlaybackUnavailable(detail: "playback_setup: -10868")

        XCTAssertTrue(sink.names.contains("playback.unavailable"))
        XCTAssertFalse(sink.names.contains("session.terminated"),
                       "there was no session to terminate")
        XCTAssertEqual(inner.calls, [], "a pipe that was never opened sees no traffic")
        XCTAssertTrue(wrapper.isPlaybackUnavailableForTesting)
    }

    // MARK: - The verdict lasts the run

    func testALaterOpenIsRefusedWithoutTouchingThePipe() async throws {
        let sink = RecordingSink()
        let (inner, wrapper) = makeWrapper(sink: sink)

        try await wrapper.open { _ in }
        wrapper.notePlaybackUnavailable(detail: "playback_setup: -10868")
        let callsAfterTermination = inner.calls

        do {
            try await wrapper.open { _ in }
            XCTFail("a session nobody can hear must not be handed back")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure,
                           .network("response audio playback is unavailable"))
        }

        XCTAssertEqual(inner.calls, callsAfterTermination,
                       "the refused open reached the pipe with zero traffic")
        guard let refusal = sink.event(named: "open.refused") else {
            return XCTFail("expected the refusal to be logged")
        }
        XCTAssertEqual(refusal.level, .error)
        XCTAssertEqual(refusal.fields["reason"], "playback_unavailable")
    }

    func testPlaybackDyingDuringOpenClosesTheSessionItWasOpening() async throws {
        let sink = RecordingSink()
        let inner = ScriptedVoiceBackend(name: "primary", capabilities: speakingCapabilities)
        let wrapper = PlaybackDependentVoiceBackend(inner: inner, diagnosticSink: sink)
        inner.openGate = { [weak wrapper] in
            wrapper?.notePlaybackUnavailable(detail: "playback_setup: -10868")
        }

        do {
            try await wrapper.open { _ in }
            XCTFail("an already-mute session must not be handed back")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure,
                           .network("response audio playback is unavailable"))
        }
        XCTAssertFalse(inner.isOpen)
    }

    // MARK: - Where the termination lands

    /// The composition the runtime builds for `--voice-backend openai-realtime`, minus the
    /// AVFoundation halves: `VoiceBrokenState(PlaybackDependent(realtime))`. There is no
    /// third backend in it, and that is the point — the same failure that used to bring an
    /// Apple stack up underneath now ends the run's hands-free voice instead.
    private func makeComposition(sink: RecordingSink)
        -> (PlaybackDependentVoiceBackend, ScriptedVoiceBackend, VoiceBrokenState) {
        let realtime = ScriptedVoiceBackend(name: "realtime", capabilities: speakingCapabilities)
        let dependent = PlaybackDependentVoiceBackend(inner: realtime, diagnosticSink: sink)
        return (dependent, realtime,
                VoiceBrokenState(inner: dependent, provider: .openaiRealtime,
                                 diagnosticSink: sink))
    }

    func testTerminationBreaksTheRunRatherThanChangingBackends() async throws {
        let sink = RecordingSink()
        let (dependent, realtime, composition) = makeComposition(sink: sink)
        let events = EventLog()

        try await composition.open { events.append($0) }
        composition.beginUserTurn()
        dependent.notePlaybackUnavailable(detail: "playback_setup: -10868")
        await settle()

        XCTAssertFalse(realtime.isOpen, "the realtime pipe is gone")
        XCTAssertTrue(composition.isBroken, "and nothing came up in its place")
        XCTAssertEqual(events.failures.count, 1,
                       "the caller is told, once, so its window stops waiting for voice")
        // Cause, then both halves of the consequence, in the order a log reader meets them.
        XCTAssertEqual(sink.names,
                       ["playback.unavailable", "session.terminated",
                        "voice.pipeline_failed", "voice.disabled_for_run"])
        XCTAssertEqual(sink.event(named: "voice.pipeline_failed")?.fields["backend"],
                       "openai-realtime")
    }

    /// The sentence the wearer could not hear is not re-routed to some other pipe. After the
    /// break there is nothing to hand it to, and the announcement that matters — the break
    /// notice itself — is spoken by the host through its own synthesizer.
    func testAfterTheBreakNothingIsHandedToABackendAtAll() async throws {
        let sink = RecordingSink()
        let (dependent, realtime, composition) = makeComposition(sink: sink)
        var spoken: [String] = []
        composition.speakNotice = { spoken.append($0) }

        try await composition.open { _ in }
        dependent.notePlaybackUnavailable(detail: "playback_setup: -10868")
        await settle()
        let callsAfterBreak = realtime.calls

        composition.requestResponse(text: "Voice session ended.")

        XCTAssertEqual(realtime.calls, callsAfterBreak,
                       "nothing is handed to a pipe whose audio nobody can play")
        XCTAssertEqual(spoken, [VoiceBrokenState.spokenNotice])
    }

    func testTheDeadPipeIsNotRetriedOnTheNextWindow() async throws {
        let sink = RecordingSink()
        let (dependent, realtime, composition) = makeComposition(sink: sink)

        try await composition.open { _ in }
        dependent.notePlaybackUnavailable(detail: "playback_setup: -10868")
        await settle()
        composition.close()

        do {
            try await composition.open { _ in }
            XCTFail("a broken run must never be handed another session")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure,
                           .closed("hands-free voice is disabled for this run"))
        }

        XCTAssertEqual(realtime.calls.filter { $0 == .open }.count, 1,
                       "the realtime pipe is opened once in the life of the run")
    }

    func testAWindowThatNeverRoutesSpeechToTheBackendIsUnaffected() async throws {
        let sink = RecordingSink()
        let (_, realtime, composition) = makeComposition(sink: sink)
        let events = EventLog()

        try await composition.open { events.append($0) }
        composition.beginUserTurn()
        composition.sendAudio(VoiceAudioChunk(data: Data(repeating: 1, count: 32),
                                              format: .pcm16Mono24k, timestamp: 0))
        realtime.emit(.transcriptFinal("approve"))
        composition.endUserTurn(expectingResponse: false)
        await settle()

        XCTAssertTrue(realtime.isOpen)
        XCTAssertFalse(composition.isBroken)
        XCTAssertTrue(events.failures.isEmpty)
        XCTAssertTrue(sink.names.isEmpty, "a healthy window writes nothing: \(sink.names)")
    }
}
