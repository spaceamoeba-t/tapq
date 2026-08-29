import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// The break, stated as the four things it owes and the one thing it must never do.
///
/// Owes: two error diagnostics naming cause and consequence, one locally spoken notice,
/// every held boundary released, and a pipe that is never opened again. Must never do:
/// reach a second backend. There is no fallback left to reach, and these tests are what
/// keeps it that way — the composition below has exactly one backend in it, and after the
/// break it has none.
@MainActor
final class VoiceBrokenStateTests: XCTestCase {
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

        func count(_ name: String) -> Int { names.filter { $0 == name }.count }
    }

    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
    }

    /// What the host wires into the latch: the local synthesizer and the wait registry.
    @MainActor
    private final class HostSide {
        private(set) var spoken: [String] = []
        private(set) var releases = 0

        func install(on latch: VoiceBrokenState) {
            latch.speakNotice = { [weak self] in self?.spoken.append($0) }
            latch.releaseHolds = { [weak self] in self?.releases += 1 }
        }
    }

    private let realtimeCapabilities = VoiceBackendCapabilities(
        supportsBargeIn: true, producesAudio: true, duplex: true,
        supportsNativeTurnDetection: true)

    private func makeLatch(sink: RecordingSink = RecordingSink())
        -> (ScriptedVoiceBackend, VoiceBrokenState, HostSide) {
        let inner = ScriptedVoiceBackend(name: "realtime", capabilities: realtimeCapabilities)
        let latch = VoiceBrokenState(inner: inner, provider: .openaiRealtime,
                                    diagnosticSink: sink)
        let host = HostSide()
        host.install(on: latch)
        return (inner, latch, host)
    }

    // MARK: - A healthy pipe costs nothing

    func testAWorkingBackendIsForwardedVerbatim() async throws {
        let sink = RecordingSink()
        let (inner, latch, host) = makeLatch(sink: sink)
        let events = EventLog()

        XCTAssertEqual(latch.capabilities, realtimeCapabilities)
        try await latch.open { events.append($0) }
        latch.setNativeTurnDetection(true)
        latch.beginUserTurn()
        latch.sendAudio(VoiceAudioChunk(data: Data(repeating: 3, count: 48),
                                        format: .pcm16Mono24k, timestamp: 0))
        inner.emit(.transcriptFinal("yes"))
        latch.endUserTurn(expectingResponse: false)
        latch.requestResponse(text: "The build is green.")
        latch.cancelResponse()

        XCTAssertFalse(latch.isBroken)
        XCTAssertEqual(inner.nativeTurnDetection, [true])
        XCTAssertEqual(inner.calls,
                       [.open, .beginUserTurn, .sendAudio(48), .endUserTurn,
                        .requestResponse("The build is green."), .cancelResponse])
        XCTAssertEqual(events.events, [.transcriptFinal("yes"), .responseCompleted])
        XCTAssertTrue(sink.names.isEmpty, "a healthy run writes nothing here: \(sink.names)")
        XCTAssertTrue(host.spoken.isEmpty)
        XCTAssertEqual(host.releases, 0)
    }

    // MARK: - The latch

    func testAMidRunSessionFailureBreaksTheRun() async throws {
        let sink = RecordingSink()
        let (inner, latch, host) = makeLatch(sink: sink)
        let events = EventLog()

        try await latch.open { events.append($0) }
        latch.beginUserTurn()
        inner.emit(.sessionFailed(.network("the socket dropped")))

        XCTAssertTrue(latch.isBroken)
        XCTAssertEqual(events.failures, [.network("the socket dropped")],
                       "the failure still reaches the caller, which tears its window down")
        XCTAssertEqual(host.spoken, [VoiceBrokenState.spokenNotice])
        XCTAssertEqual(host.releases, 1)
    }

    func testTheDiagnosticsNameCauseThenConsequenceAtErrorLevel() async throws {
        let sink = RecordingSink()
        let (inner, latch, _) = makeLatch(sink: sink)

        try await latch.open { _ in }
        inner.emit(.sessionFailed(.network("no route to host")))

        XCTAssertEqual(sink.names, ["voice.pipeline_failed", "voice.disabled_for_run"],
                       "cause then consequence, in that order and nothing between them")
        guard let cause = sink.event(named: "voice.pipeline_failed"),
              let consequence = sink.event(named: "voice.disabled_for_run") else {
            return XCTFail("expected both halves of the break in the log")
        }
        XCTAssertEqual(cause.level, .error)
        XCTAssertEqual(consequence.level, .error)
        XCTAssertEqual(cause.category, "Voice")
        XCTAssertEqual(cause.fields["backend"], "openai-realtime")
        XCTAssertEqual(cause.fields["reason"],
                       VoiceBackendFailure.network("no route to host").localizedDescription)
    }

    /// The break is the run's, not the session's: two failures are one break, and the
    /// wearer hears about it once.
    func testTheLatchFiresExactlyOnce() async throws {
        let sink = RecordingSink()
        let (inner, latch, host) = makeLatch(sink: sink)

        try await latch.open { _ in }
        inner.emit(.sessionFailed(.network("first")))
        latch.noteBackendFailed(reason: "second")
        latch.noteBackendFailed(reason: "third")

        XCTAssertEqual(sink.count("voice.pipeline_failed"), 1)
        XCTAssertEqual(sink.count("voice.disabled_for_run"), 1)
        XCTAssertEqual(host.spoken, [VoiceBrokenState.spokenNotice])
        XCTAssertEqual(host.releases, 1)
        XCTAssertEqual(sink.event(named: "voice.pipeline_failed")?.fields["reason"],
                       VoiceBackendFailure.network("first").localizedDescription,
                       "the first cause is the one on the record")
    }

    func testTheSpokenNoticeIsOneLocalSentence() async {
        // Read off the type rather than typed twice: a reworded notice must not need this
        // test edited to keep passing, only the one place it is written.
        XCTAssertEqual(VoiceBrokenState.spokenNotice,
                       "Hands-free voice is off. The voice backend failed.")
        let (_, latch, host) = makeLatch()
        latch.noteBackendFailed(reason: "playback_unavailable")
        XCTAssertEqual(host.spoken.count, 1)
    }

    /// A host that wires neither closure — every test composition, and any host with no
    /// synthesizer and no held boundaries — still breaks, and still says so in the log.
    func testAHostThatWiresNothingStillBreaks() async throws {
        let sink = RecordingSink()
        let inner = ScriptedVoiceBackend(name: "realtime", capabilities: realtimeCapabilities)
        let latch = VoiceBrokenState(inner: inner, provider: .openaiRealtime,
                                     diagnosticSink: sink)

        try await latch.open { _ in }
        inner.emit(.sessionFailed(.closed("the peer hung up")))

        XCTAssertTrue(latch.isBroken)
        XCTAssertEqual(sink.names, ["voice.pipeline_failed", "voice.disabled_for_run"])
    }

    // MARK: - Open failures

    func testAnOpenThatFailsAfterStartupBreaksTheRun() async {
        let sink = RecordingSink()
        let (inner, latch, host) = makeLatch(sink: sink)
        inner.openFailure = .network("handshake timed out")

        do {
            try await latch.open { _ in }
            XCTFail("a failed open must not be reported as a session")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure, .network("handshake timed out"))
        }

        XCTAssertTrue(latch.isBroken,
                      "there is no second backend to try, so the first failure is the last")
        XCTAssertEqual(host.spoken, [VoiceBrokenState.spokenNotice])
        XCTAssertEqual(host.releases, 1)
        XCTAssertEqual(sink.event(named: "voice.pipeline_failed")?.fields["reason"],
                       VoiceBackendFailure.network("handshake timed out").localizedDescription)
    }

    // MARK: - No reopen, ever

    func testEveryLaterOpenIsRefusedWithoutTouchingThePipe() async throws {
        let sink = RecordingSink()
        let (inner, latch, _) = makeLatch(sink: sink)

        try await latch.open { _ in }
        inner.emit(.sessionFailed(.network("dropped")))
        latch.close()
        let callsAfterBreak = inner.calls

        for _ in 0..<3 {
            do {
                try await latch.open { _ in }
                XCTFail("a broken run must never be handed a session")
            } catch {
                XCTAssertEqual(error as? VoiceBackendFailure,
                               .closed("hands-free voice is disabled for this run"))
            }
        }

        XCTAssertEqual(inner.calls, callsAfterBreak,
                       "three refused opens reached the pipe with zero traffic")
        XCTAssertEqual(sink.count("open.refused"), 3)
        let refusal = try XCTUnwrap(sink.event(named: "open.refused"))
        XCTAssertEqual(refusal.fields["reason"], "voice_disabled_for_run")
        XCTAssertEqual(refusal.level, .warning,
                       "the error pair was written once; a per-window repeat would bury it")
    }

    /// Nothing is forwarded to a dead pipe. The provider above tears its window down on the
    /// failure, and the calls that teardown makes must not reach a backend that is gone.
    func testCallsAfterTheBreakReachNothing() async throws {
        let (inner, latch, _) = makeLatch()

        try await latch.open { _ in }
        latch.beginUserTurn()
        inner.emit(.sessionFailed(.network("dropped")))
        let callsAfterBreak = inner.calls

        latch.beginUserTurn()
        XCTAssertFalse(latch.endUserTurn(expectingResponse: true),
                       "a turn nobody is holding created no response")
        latch.sendAudio(VoiceAudioChunk(data: Data(repeating: 1, count: 16),
                                        format: .pcm16Mono24k, timestamp: 0))
        latch.requestResponse(text: "anything")
        latch.cancelResponse()
        latch.setNativeTurnDetection(true)

        XCTAssertEqual(inner.calls, callsAfterBreak)
        XCTAssertEqual(inner.nativeTurnDetection, [])
    }

    /// A late event from the session that died — the ordering a real socket produces when
    /// its error frame and its close race — is dropped rather than relayed as a second
    /// failure for a session nobody is listening to.
    func testEventsArrivingAfterTheBreakAreDropped() async throws {
        let sink = RecordingSink()
        let (inner, latch, host) = makeLatch(sink: sink)
        let events = EventLog()

        try await latch.open { events.append($0) }
        inner.emit(.sessionFailed(.network("dropped")))
        inner.emit(.transcriptFinal("too late"))
        inner.emit(.sessionFailed(.closed("and again")))

        XCTAssertEqual(events.failures.count, 1)
        XCTAssertFalse(events.events.contains(.transcriptFinal("too late")))
        XCTAssertEqual(host.spoken.count, 1)
        XCTAssertEqual(sink.count("voice.disabled_for_run"), 1)
    }

    // MARK: - The composition the runtime builds

    /// Playback termination lands in the break, not in a fallback: the runtime's
    /// `VoiceBrokenState(PlaybackDependent(pump(realtime)))` stack, minus the AVFoundation
    /// halves that cannot exist in a portable target.
    func testAPlaybackTerminationLandsInTheBreak() async throws {
        let sink = RecordingSink()
        let realtime = ScriptedVoiceBackend(name: "realtime",
                                            capabilities: realtimeCapabilities)
        let dependent = PlaybackDependentVoiceBackend(inner: realtime, diagnosticSink: sink)
        let latch = VoiceBrokenState(inner: dependent, provider: .openaiRealtime,
                                     diagnosticSink: sink)
        let host = HostSide()
        host.install(on: latch)
        let events = EventLog()

        try await latch.open { events.append($0) }
        latch.beginUserTurn()
        dependent.notePlaybackUnavailable(detail: "playback_setup: -10868")

        XCTAssertTrue(latch.isBroken)
        XCTAssertFalse(realtime.isOpen, "the pipe — and its microphone — is closed")
        XCTAssertEqual(events.failures.count, 1,
                       "the caller is told once, and tears its window down on it")
        XCTAssertEqual(host.spoken, [VoiceBrokenState.spokenNotice])
        XCTAssertEqual(host.releases, 1)
        // Cause, then the two halves of the consequence, in the order a log reader meets
        // them: the renderer gave up, the session ended, the run's voice is off.
        XCTAssertEqual(sink.names,
                       ["playback.unavailable", "session.terminated",
                        "voice.pipeline_failed", "voice.disabled_for_run"])
        XCTAssertEqual(sink.event(named: "playback.unavailable")?.fields["consequence"],
                       "voice_disabled_for_run")
    }
}
