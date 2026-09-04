import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Keeps a short timer pending that re-enqueues onto the main actor for the life of the
/// test process.
///
/// The Linux container's runtime nondeterministically loses a main-actor wakeup (the
/// CLAUDE.md "wedge"): queued main-actor jobs stop being drained and the process sits at
/// ~0% CPU until a NEW job lands on the main actor. Measured 2026-08-29: a test with an
/// instant `idleSleep` and no timers of its own stalled for 59.98s and resumed exactly
/// when an earlier test's real 60-second idle-timer task fired — this suite's
/// 1s/61s/121s run-to-run variance was that accidental rescue, at 60s granularity, and
/// the runs slim-check kills as wedged are the same stall with no timer left pending.
/// This task is the same rescue on purpose, every 100ms, so a lost wakeup costs ~0.1s.
/// It must be a `@MainActor` task: each sleep completion then resumes onto the main
/// actor, and that enqueue is what restarts the drain (a detached variant was measured
/// NOT to rescue — its ticks stay on the global pool). Lazy global, so it starts with
/// the first `settle()` of the run; never cancelled, because process exit does not wait
/// for a sleeping task.
private let executorStallHeartbeat: Task<Void, Never> = Task { @MainActor in
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
final class VoiceBackendCommandProviderTests: XCTestCase {
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

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A backend that records the exact call sequence and replays scripted events on
    /// demand.
    ///
    /// It also polices the turn protocol from the backend's side: an `endUserTurn` with no
    /// turn open, a second `beginUserTurn`, or any turn call after `close` fails the test
    /// where it happens. The fake never ends a turn itself — that is the invariant these
    /// tests exist to defend, and a fake that quietly did it would hide the bug.
    @MainActor
    final class ScriptedVoiceBackend: VoiceBackend {
        enum Call: Equatable {
            case open
            case close
            case beginUserTurn
            case endUserTurn
            case sendAudio(Int)
            case requestResponse(String)
            case cancelResponse
        }

        let capabilities: VoiceBackendCapabilities
        private(set) var calls: [Call] = []
        private(set) var handlers: [(@MainActor (VoiceBackendEvent) -> Void)] = []
        private(set) var isOpen = false
        private(set) var isTurnActive = false
        /// The `expectingResponse` argument of every `endUserTurn`, in order. `Call` cannot
        /// carry it without rewriting every sequence assertion in the file.
        private(set) var endUserTurnExpectations: [Bool] = []
        /// Set to make the handshake fail; cleared by the test to let a retry succeed.
        var openFailure: VoiceBackendFailure?
        /// When set, `open` suspends on it so a test can stop the window mid-handshake.
        var openGate: (() async -> Void)?

        init(capabilities: VoiceBackendCapabilities = .transcriptOnly) {
            self.capabilities = capabilities
        }

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append(.open)
            if let openGate {
                await openGate()
            }
            if let openFailure {
                throw openFailure
            }
            isOpen = true
            handlers.append(onEvent)
        }

        func close() {
            calls.append(.close)
            isOpen = false
            isTurnActive = false
        }

        func beginUserTurn() {
            calls.append(.beginUserTurn)
            XCTAssertTrue(isOpen, "beginUserTurn on a closed session")
            XCTAssertFalse(isTurnActive, "double beginUserTurn")
            isTurnActive = true
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            calls.append(.endUserTurn)
            endUserTurnExpectations.append(expectingResponse)
            XCTAssertTrue(isOpen, "endUserTurn on a closed session")
            XCTAssertTrue(isTurnActive, "endUserTurn with no turn open")
            isTurnActive = false
            // Transcript-only backend: never creates a response.
            return false
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {
            calls.append(.sendAudio(chunk.data.count))
        }

        func requestResponse(text: String) {
            calls.append(.requestResponse(text))
        }

        func cancelResponse() {
            calls.append(.cancelResponse)
        }

        /// Every turn-detection mode the provider asked for, in order. Kept out of `Call`
        /// deliberately: this file asserts on exact call sequences everywhere, and a mode
        /// switch appearing inside one would make sixty tests argue about a decision only a
        /// handful of them are actually testing.
        private(set) var nativeTurnDetection: [Bool] = []

        func setNativeTurnDetection(_ enabled: Bool) {
            XCTAssertTrue(capabilities.supportsNativeTurnDetection,
                          "a backend that cannot do native turn detection was asked to")
            nativeTurnDetection.append(enabled)
        }

        /// Delivers an event to the newest window, or to an older one when a test needs to
        /// prove stale callbacks are dropped.
        func emit(_ event: VoiceBackendEvent, toHandler index: Int? = nil) {
            guard !handlers.isEmpty else { return XCTFail("no window is listening") }
            handlers[index ?? handlers.count - 1](event)
        }
    }

    /// Stands in for `VoiceCommandMatcher`, which lives in a module this one does not
    /// depend on. Deliberately substring-based so cumulative transcripts behave the way the
    /// real grammar's whole-utterance matching does.
    private static let match: VoiceBackendCommandProvider.TranscriptMatching = { text in
        let lowered = text.lowercased()
        if lowered.contains("yes") { return .yes }
        if lowered.contains("no") { return .no }
        return nil
    }

    private func makeProvider(backend: ScriptedVoiceBackend,
                              sink: RecordingSink = RecordingSink())
        -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(backend: backend, match: Self.match, diagnosticSink: sink)
    }

    /// The window opens across an `await`, so tests hand the main actor back before
    /// asserting on it.
    private func settle() async {
        _ = executorStallHeartbeat
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: - Window lifecycle

    func testStartOpensTheSessionAndBeginsExactlyOneUserTurn() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)

        provider.start { _ in XCTFail("nothing was transcribed") }
        XCTAssertEqual(backend.calls, [], "the handshake is async; nothing happens inline")
        await settle()

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn])
        XCTAssertTrue(backend.isTurnActive)
        XCTAssertTrue(provider.isWindowOpenForTesting)
    }

    func testDuplicateStartIsIgnored() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)

        provider.start { _ in }
        provider.start { _ in XCTFail("a second start must not replace the window") }
        await settle()

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn])
        XCTAssertEqual(sink.events.first { $0.name == "start.skipped" }?.fields["reason"],
                       "already_running")
    }

    func testStopEndsTheTurnAndClosesTheSession() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)

        provider.start { _ in }
        await settle()
        provider.stop()

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn, .close])
        XCTAssertFalse(provider.isWindowOpenForTesting)
    }

    func testStopIsIdempotent() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)

        provider.start { _ in }
        await settle()
        provider.stop()
        provider.stop()
        provider.stop()

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn, .close])
    }

    func testStopBeforeTheHandshakeCompletesStillClosesTheSession() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        backend.openGate = { await Task.yield() }

        provider.start { _ in XCTFail("the window was abandoned") }
        provider.stop()
        await settle()

        XCTAssertEqual(backend.calls, [.open, .close],
                       "a session that finishes opening after stop must not be left running")
        XCTAssertFalse(backend.isOpen)
        XCTAssertFalse(backend.isTurnActive)
    }

    // MARK: - Matching

    func testMatchOnPartialTranscriptDeliversOnceAndEndsTheTurn() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        XCTAssertEqual(received, [.yes])
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn, .close])
        XCTAssertFalse(provider.isWindowOpenForTesting)
        XCTAssertEqual(sink.events.last { $0.name == "command.matched" }?.fields["command"],
                       "yes")
    }

    func testCumulativeTranscriptIsMatchedAsAWhole() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        // Cumulative, exactly as SFSpeechRecognizer reports it: each partial repeats the
        // whole utterance so far.
        backend.emit(.transcriptPartial("um"))
        XCTAssertEqual(received, [])
        backend.emit(.transcriptPartial("um yes"))

        XCTAssertEqual(received, [.yes])
    }

    func testTranscriptsAfterAMatchDeliverNothing() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))
        // In-flight transcripts landing after the window resolved.
        backend.emit(.transcriptPartial("yes"))
        backend.emit(.transcriptFinal("no"))

        XCTAssertEqual(received, [.yes], "a window resolves exactly once")
    }

    func testUnmatchedFinalTranscriptDeliversNothingAndLeavesTheTurnOpen() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("what time is the standup"))

        XCTAssertEqual(received, [])
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn],
                       "a backend's final transcript is not a turn boundary")
        XCTAssertTrue(backend.isTurnActive)
        XCTAssertTrue(provider.isWindowOpenForTesting)
        let rejection = sink.events.last { $0.name == "transcript.rejected" }
        XCTAssertEqual(rejection?.fields["reason"], "unmatched")
        XCTAssertEqual(rejection?.fields["length"], "24")
    }

    func testUnmatchedPartialTranscriptIsNotLoggedAsRejected() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptPartial("um"))

        XCTAssertFalse(sink.names.contains("transcript.rejected"),
                       "every partial is unmatched until it isn't; logging each is noise")
    }

    // MARK: - Turn ownership

    func testTheBackendNeverEndsATurnOnItsOwn() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)

        provider.start { _ in }
        await settle()
        // Everything a backend can say that is not a match: none of it may commit a turn.
        backend.emit(.transcriptPartial("hello"))
        backend.emit(.transcriptFinal("hello"))
        backend.emit(.responseCompleted)
        backend.emit(.audio(VoiceAudioChunk(data: Data([0, 1, 2, 3]),
                                            format: .pcm16Mono16k, timestamp: 1)))

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn])
        XCTAssertTrue(backend.isTurnActive)
        provider.stop()
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn, .close],
                       "only the caller ends the turn")
    }

    func testResponseAudioIsIgnoredAndRecorded() async {
        let backend = ScriptedVoiceBackend(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.audio(VoiceAudioChunk(data: Data(repeating: 7, count: 64),
                                            format: .pcm16Mono24k, timestamp: 2)))

        XCTAssertEqual(received, [])
        XCTAssertTrue(sink.names.contains("audio.ignored"))
    }

    func testProviderNeverPushesAudioIntoABackendThatRecordsItself() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        XCTAssertFalse(backend.calls.contains { if case .sendAudio = $0 { return true }
                                                return false })
        XCTAssertFalse(backend.calls.contains(.requestResponse("")))
        XCTAssertFalse(backend.calls.contains(.cancelResponse))
    }

    // MARK: - Failure paths (all fail open)

    func testSessionFailedMidWindowTearsDownWithoutDelivering() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.sessionFailed(.network("socket dropped")))

        XCTAssertEqual(received, [], "a dead session resolves nothing")
        XCTAssertFalse(provider.isWindowOpenForTesting)
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .close],
                       "no endUserTurn into a session that is already gone")
        let failure = sink.events.last { $0.name == "session.failed" }
        XCTAssertEqual(failure?.level, .warning)
        XCTAssertTrue(failure?.fields["detail"]?.contains("socket dropped") == true)
    }

    func testTranscriptsAfterSessionFailureAreDropped() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.sessionFailed(.closed("peer hung up")))
        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(received, [])
    }

    func testOpenFailureFailsOpenSilently() async {
        let backend = ScriptedVoiceBackend()
        backend.openFailure = .authorization("no credentials")
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        XCTAssertEqual(received, [])
        XCTAssertEqual(backend.calls, [.open], "a session that never opened is not closed")
        XCTAssertFalse(provider.isWindowOpenForTesting)
        let failed = sink.events.last { $0.name == "window.open_failed" }
        XCTAssertEqual(failed?.level, .warning)
        XCTAssertTrue(failed?.fields["error"]?.contains("credentials") == true)
    }

    func testSecondStartAfterFailureOpensAFreshTurn() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.sessionFailed(.network("route changed")))

        provider.start { received.append($0) }
        await settle()
        XCTAssertEqual(backend.calls,
                       [.open, .beginUserTurn, .close, .open, .beginUserTurn])
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes], "the next window recovers on a fresh session")
    }

    func testSecondStartAfterAnOpenFailureRecovers() async {
        let backend = ScriptedVoiceBackend()
        backend.openFailure = .network("first handshake timed out")
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.openFailure = nil

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(received, [.yes])
        XCTAssertEqual(backend.calls, [.open, .open, .beginUserTurn, .endUserTurn, .close])
    }

    // MARK: - Stale callbacks

    func testEventsFromAPriorWindowAreDropped() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.stop()

        provider.start { received.append($0) }
        await settle()
        XCTAssertEqual(backend.handlers.count, 2)

        backend.emit(.transcriptFinal("yes"), toHandler: 0)
        XCTAssertEqual(received, [], "a transcript from the closed window resolves nothing")

        backend.emit(.transcriptFinal("yes"), toHandler: 1)
        XCTAssertEqual(received, [.yes])
    }

    func testFailureFromAPriorWindowDoesNotTearDownTheLiveOne() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.stop()
        provider.start { received.append($0) }
        await settle()

        backend.emit(.sessionFailed(.network("late failure from window 1")), toHandler: 0)
        XCTAssertTrue(provider.isWindowOpenForTesting)
        backend.emit(.transcriptPartial("yes"), toHandler: 1)
        XCTAssertEqual(received, [.yes])
    }

    // MARK: - Composition

    func testStacksUnderSpeechGatedVoice() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeProvider(backend: backend)
        let activity = FakeSpeechActivity()
        let gated = SpeechGatedVoice(wrapping: provider, activity: activity)
        var received: [VoiceCommand] = []

        activity.setSpeaking(true)
        gated.start { received.append($0) }
        await settle()
        XCTAssertEqual(backend.calls, [], "the mic stays shut while the synthesizer talks")

        activity.setSpeaking(false)
        await settle()
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn])
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
    }

    // MARK: - Conversation mode

    /// Virtual clock for idle-close testing.
    @MainActor
    private final class VirtualClock {
        var time: TimeInterval = 0
        func advance(by interval: TimeInterval) { time += interval }
    }

    private func makeConversationProvider(
        backend: ScriptedVoiceBackend,
        idleClose: TimeInterval = 60,
        supportsBargeIn: Bool = false,
        clock: VirtualClock? = nil,
        instantIdle: Bool = false,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        let resolvedClock = clock ?? VirtualClock()
        return VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: idleClose),
            supportsBargeIn: supportsBargeIn,
            monotonicNow: { resolvedClock.time },
            idleSleep: instantIdle ? { _ in } : { try? await Task.sleep(for: .seconds($0)) },
            diagnosticSink: sink)
    }

    func testConversationModeOneOpenAcrossMultipleStartStopCycles() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var received: [VoiceCommand] = []

        // First window
        provider.start { received.append($0) }
        await settle()
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn])
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
        // Match resolves the window, ends the turn, session stays open
        XCTAssertTrue(backend.isOpen, "the session must stay open in conversation mode")
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn])

        // Second window: no new open, just a fresh turn
        provider.start { received.append($0) }
        await settle()
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn, .beginUserTurn])
        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.yes, .no])
        XCTAssertTrue(backend.isOpen)
    }

    func testConversationModeExactlyOneBeginUserTurnPerStart() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)

        // Cycle three start/stop pairs.
        for _ in 0..<3 {
            provider.start { _ in }
            await settle()
            provider.stop()
        }
        let beginCount = backend.calls.filter { $0 == .beginUserTurn }.count
        XCTAssertEqual(beginCount, 3, "each start opens exactly one turn")
        let openCount = backend.calls.filter { $0 == .open }.count
        XCTAssertEqual(openCount, 1, "one open for the whole conversation")
    }

    func testConversationModeMatchDeliversOnceThenEndsTheTurn() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        XCTAssertEqual(received, [.yes])
        XCTAssertFalse(backend.isTurnActive, "the turn ends on match")
        XCTAssertTrue(backend.isOpen, "the session stays open")
        XCTAssertFalse(provider.isWindowOpenForTesting, "the window is closed")
    }

    func testConversationModeSecondStartAfterMatchYieldsTurnTwoOnSameSession() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        // Second start: same session, fresh turn, clean transcript slate
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)
        backend.emit(.transcriptFinal("no"))
        XCTAssertEqual(received, [.yes, .no])
    }

    func testConversationModeIdleTimerClosesSessionAfterIdleClose() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, idleClose: 60,
                                                instantIdle: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertTrue(backend.isOpen, "session stays open right after stop")

        // The injectable sleep returns instantly; settle lets the Task deliver.
        await settle()

        XCTAssertFalse(backend.isOpen, "session closed by idle timer")
        XCTAssertTrue(sink.names.contains("session.idle_closed"))
    }

    func testConversationModeStartAfterIdleCloseReopens() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend, idleClose: 60,
                                                instantIdle: true)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.stop()
        // The injectable sleep returns instantly; settle lets the idle fire.
        await settle()

        XCTAssertFalse(backend.isOpen)
        // New start should reopen
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isOpen)
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
        let openCount = backend.calls.filter { $0 == .open }.count
        XCTAssertEqual(openCount, 2, "idle-close forces a reopen")
    }

    func testConversationModeStopDuringAsyncOpenStillClosesExactlyOnce() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        backend.openGate = { await Task.yield() }

        provider.start { _ in XCTFail("the window was abandoned") }
        provider.stop()
        await settle()

        XCTAssertEqual(backend.calls, [.open, .close],
                       "a session finishing its open after stop must be closed")
        XCTAssertFalse(backend.isOpen)
    }

    func testConversationModeSessionFailedMidConversation() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.sessionFailed(.network("socket dropped")))

        XCTAssertFalse(provider.isWindowOpenForTesting)
        XCTAssertFalse(provider.isSessionOpenForTesting)

        // Next start reopens from scratch
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isOpen)
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
    }

    func testConversationModeShutdownIsIdempotent() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)

        provider.start { _ in }
        await settle()
        provider.shutdown()
        provider.shutdown()
        provider.shutdown()

        XCTAssertFalse(backend.isOpen)
        let closeCount = backend.calls.filter { $0 == .close }.count
        XCTAssertEqual(closeCount, 1, "shutdown closes exactly once")
    }

    func testConversationModeStartAfterShutdownIsIgnored() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, sink: sink)

        provider.start { _ in }
        await settle()
        provider.shutdown()

        provider.start { _ in XCTFail("a shut-down provider must not start") }
        await settle()

        XCTAssertTrue(sink.names.contains("start.skipped"))
    }

    // MARK: - endActiveTurn

    func testEndActiveTurnCommitsExactlyOnce() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, sink: sink)

        provider.start { _ in }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        provider.endActiveTurn()

        XCTAssertFalse(backend.isTurnActive)
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn])
        XCTAssertTrue(sink.names.contains("turn.committed_by_coordinator"))
    }

    func testEndActiveTurnTranscriptAfterCommitStillMatchesAndResolves() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.endActiveTurn()

        // Transcript arriving after the commit (the OpenAI flow)
        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes], "post-commit transcript must still resolve")
    }

    func testEndActiveTurnWithNoActiveTurnIsRecordedNoOp() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, sink: sink)

        // No window open
        provider.endActiveTurn()
        XCTAssertTrue(sink.names.contains("endActiveTurn.skipped"))
        XCTAssertEqual(backend.calls, [])
    }

    func testEndActiveTurnNeverCausesAProtocolViolation() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, sink: sink)

        // With a window but turn already ended by stop
        provider.start { _ in }
        await settle()
        provider.stop()
        provider.endActiveTurn()

        // No crash, no protocol violation
        XCTAssertTrue(sink.names.contains("endActiveTurn.skipped"))
    }

    /// The endpoint commits for transcription and nothing else. A reply to an endpointed
    /// turn is the one utterance TapQ cannot vouch for, so the commit stops asking for one.
    func testEndActiveTurnCommitsWithoutAskingForAResponse() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()

        XCTAssertEqual(backend.endUserTurnExpectations, [false],
                       "the endpoint must commit with expectingResponse: false")
        XCTAssertFalse(backend.calls.contains(where: {
            if case .requestResponse = $0 { return true }
            return false
        }), "no response may be requested from an endpointed turn")
    }

    /// The same commit against a backend that models the adapters' responding state: it
    /// stays out of `.responding`, so the next window opens its turn immediately instead
    /// of waiting out a reply nobody asked for.
    func testEndActiveTurnLeavesTheAdapterOutOfTheRespondingState() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.endActiveTurn()

        XCTAssertFalse(backend.isResponding, "the commit created no response")
        XCTAssertFalse(provider.isResponseInFlight)

        provider.stop()
        XCTAssertFalse(sink.names.contains("response.suppression_armed"),
                       "nothing to suppress — no response was ever created")

        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive, "the next turn starts immediately")
        XCTAssertFalse(sink.names.contains("turn.deferred_response_in_flight"))

        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
    }

    // MARK: - speakViaBackend

    func testSpeakViaBackendDeclinesWithNoSession() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertEqual(backend.calls, [], "a closed session is never touched")
        XCTAssertEqual(Self.skipReasons(sink), ["no_session"])
    }

    func testSpeakViaBackendDeclinesWhileAUserTurnIsOpen() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertFalse(backend.isResponding, "requestResponse during a user turn kills the session")
        XCTAssertEqual(Self.skipReasons(sink), ["user_turn_open"])
    }

    func testSpeakViaBackendRoutesFromTheCommittedState() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()

        XCTAssertTrue(provider.speakViaBackend("Claude is waiting: tests are green."))
        XCTAssertTrue(backend.calls.contains(
            .requestResponse("Claude is waiting: tests are green.")))
        XCTAssertTrue(sink.names.contains("speech.routed_to_backend"))
    }

    /// The common notification case: no window is open, but the conversation session is.
    func testSpeakViaBackendRoutesBetweenWindows() async {
        let backend = RespondingAwareBackend()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false)

        provider.start { _ in }
        await settle()
        provider.stop()

        XCTAssertTrue(provider.speakViaBackend("Claude is waiting."))
        XCTAssertTrue(backend.calls.contains(.requestResponse("Claude is waiting.")))
    }

    func testSpeakViaBackendDeclinesWhileAResponseIsInFlight() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                            format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertEqual(Self.skipReasons(sink), ["response_in_flight"])
    }

    /// A routed utterance is itself a response: a second one before it settles would be
    /// `responseAlreadyInFlight` on the adapter, which is a dead session.
    func testSpeakViaBackendDeclinesASecondUtteranceUntilTheFirstSettles() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertTrue(provider.speakViaBackend("First."))

        XCTAssertFalse(provider.speakViaBackend("Second."))
        XCTAssertEqual(Self.skipReasons(sink), ["response_in_flight"])
        XCTAssertFalse(backend.calls.contains(.requestResponse("Second.")))

        // Once the backend finishes, the next notification routes again.
        backend.emit(.responseCompleted)
        XCTAssertTrue(provider.speakViaBackend("Second."))
        XCTAssertTrue(backend.calls.contains(.requestResponse("Second.")))
    }

    /// The window that opens while the backend is still speaking must not call
    /// `beginUserTurn` into a responding adapter — the session-death race, reached through
    /// the speech path this time.
    func testSpeakViaBackendDefersTheNextUserTurn() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertTrue(provider.speakViaBackend("Claude is waiting."))

        provider.start { received.append($0) }
        await settle()
        XCTAssertFalse(backend.isTurnActive, "no turn while the backend is speaking")
        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))

        backend.emit(.responseCompleted)
        XCTAssertTrue(backend.isTurnActive, "the deferred turn starts once speech ends")

        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
    }

    func testSpeakViaBackendDeclinesEmptyText() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()

        XCTAssertFalse(provider.speakViaBackend("   \n "))
        XCTAssertFalse(backend.calls.contains(where: {
            if case .requestResponse = $0 { return true }
            return false
        }))
        XCTAssertEqual(Self.skipReasons(sink), ["empty_text"])
    }

    func testSpeakViaBackendDeclinesAfterShutdown() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.shutdown()

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertEqual(Self.skipReasons(sink), ["no_session"])
    }

    /// Per-window mode closes the session with the window, so between windows there is
    /// nothing to route to and the caller falls back to the local engine.
    func testSpeakViaBackendDeclinesBetweenPerWindowSessions() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertEqual(Self.skipReasons(sink), ["no_session"])
    }

    /// A dead session declines rather than reaching into the backend that just died.
    func testSpeakViaBackendDeclinesAfterSessionFailure() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.sessionFailed(.network("socket dropped")))

        XCTAssertFalse(provider.speakViaBackend("Claude is waiting."))
        XCTAssertFalse(backend.calls.contains(.requestResponse("Claude is waiting.")))
        XCTAssertEqual(Self.skipReasons(sink), ["no_session"])
    }

    private static func skipReasons(_ sink: RecordingSink) -> [String] {
        sink.events
            .filter { $0.name == "speakViaBackend.skipped" }
            .compactMap { $0.fields["reason"] }
    }

    // MARK: - cancelActiveResponse

    func testCancelActiveResponseSkipsWhenNoResponse() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, supportsBargeIn: true,
                                                sink: sink)

        provider.start { _ in }
        await settle()
        provider.cancelActiveResponse()

        XCTAssertTrue(sink.names.contains("cancelActiveResponse.skipped"))
        XCTAssertFalse(backend.calls.contains(.cancelResponse))
    }

    func testCancelActiveResponseSkipsWhenBargeInUnsupported() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, supportsBargeIn: false,
                                                sink: sink)

        provider.start { _ in }
        await settle()
        provider.cancelActiveResponse()

        XCTAssertTrue(sink.names.contains("cancelActiveResponse.skipped"))
    }

    // MARK: - onTranscriptFinal

    func testOnTranscriptFinalFiresForMatchedFinalTranscript() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var finals: [(String, Bool)] = []
        provider.onTranscriptFinal = { text, matched in finals.append((text, matched)) }

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals[0].0, "yes")
        XCTAssertTrue(finals[0].1, "matched must be true for a command match")
    }

    func testOnTranscriptFinalFiresForUnmatchedFinalTranscript() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var finals: [(String, Bool)] = []
        provider.onTranscriptFinal = { text, matched in finals.append((text, matched)) }

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptFinal("what time is the standup"))

        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals[0].0, "what time is the standup")
        XCTAssertFalse(finals[0].1, "matched must be false for unmatched")
    }

    func testOnTranscriptFinalDoesNotFireForPartials() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var finals: [(String, Bool)] = []
        provider.onTranscriptFinal = { text, matched in finals.append((text, matched)) }

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptPartial("um"))

        XCTAssertEqual(finals.count, 0, "partials never fire onTranscriptFinal")
    }

    func testOnTranscriptFinalFiresForMatchOnPartial() async {
        // A partial that matches fires onTranscriptFinal only if it is not marked as a final.
        // In the current design, only .transcriptFinal triggers onTranscriptFinal. A match on a
        // partial resolves the window but does not fire onTranscriptFinal (partials are not final).
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        var finals: [(String, Bool)] = []
        provider.onTranscriptFinal = { text, matched in finals.append((text, matched)) }
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        XCTAssertEqual(received, [.yes], "the match resolves the window")
        XCTAssertEqual(finals.count, 0, "partials do not fire onTranscriptFinal even when matched")
    }

    // MARK: - Turn never spans a TTS-busy interval (composition test)

    func testTurnNeverSpansATTSBusyInterval() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend)
        let activity = FakeSpeechActivity()
        let gated = SpeechGatedVoice(wrapping: provider, activity: activity)
        var received: [VoiceCommand] = []

        // TTS starts speaking during an open window
        gated.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // TTS becomes busy: SpeechGatedVoice stops the provider, ending the turn
        activity.setSpeaking(true)
        XCTAssertFalse(backend.isTurnActive, "turn must end when TTS starts")
        XCTAssertTrue(backend.isOpen, "session stays open in conversation mode")

        // TTS finishes: SpeechGatedVoice restarts the provider, beginning a new turn
        activity.setSpeaking(false)
        await settle()
        XCTAssertTrue(backend.isTurnActive, "a fresh turn opens after TTS drains")

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    @MainActor
    private final class FakeSpeechActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?

        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    // MARK: - FakePlayback (VoiceResponseAudioPlaying)

    @MainActor
    private final class FakePlayback: VoiceResponseAudioPlaying {
        private(set) var isPlaying = false
        var onPlayingChange: (@MainActor (Bool) -> Void)?

        private(set) var enqueued: [VoiceAudioChunk] = []
        private(set) var finishStreamCount = 0
        private(set) var stopAndFlushCount = 0

        func enqueue(_ chunk: VoiceAudioChunk) {
            enqueued.append(chunk)
            if !isPlaying {
                isPlaying = true
                onPlayingChange?(true)
            }
        }

        func finishStream() {
            finishStreamCount += 1
        }

        func stopAndFlush() {
            stopAndFlushCount += 1
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }

        /// Simulates all outstanding buffers completing after `finishStream()`. In the real
        /// `BackendAudioPlayback`, this happens when the last `AVAudioPlayerNode` completion
        /// fires after `finishStream()` has been called.
        func completeDrain() {
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }
    }

    private func makeProviderWithPlayback(
        backend: ScriptedVoiceBackend,
        playback: FakePlayback,
        sessionPolicy: SessionPolicy = .perWindow,
        supportsBargeIn: Bool = false,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: sessionPolicy,
            supportsBargeIn: supportsBargeIn,
            responseAudio: playback,
            diagnosticSink: sink)
    }

    // MARK: - Response audio routing (WP2)

    func testAudioChunksAreRoutedToPlayerInOrder() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback)

        provider.start { _ in }
        await settle()

        let chunk1 = VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                      format: .pcm16Mono24k, timestamp: 1)
        let chunk2 = VoiceAudioChunk(data: Data([5, 6, 7, 8]),
                                      format: .pcm16Mono24k, timestamp: 2)
        backend.emit(.audio(chunk1))
        backend.emit(.audio(chunk2))

        XCTAssertEqual(playback.enqueued.count, 2)
        XCTAssertEqual(playback.enqueued[0], chunk1)
        XCTAssertEqual(playback.enqueued[1], chunk2)
    }

    func testResponseCompletedCallsFinishStream() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback)

        provider.start { _ in }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        backend.emit(.responseCompleted)

        XCTAssertEqual(playback.finishStreamCount, 1)
    }

    func testWindowTeardownCallsStopAndFlush() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback)

        provider.start { _ in }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        provider.stop()

        XCTAssertEqual(playback.stopAndFlushCount, 1)
    }

    func testSessionFailedCallsStopAndFlush() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback)

        provider.start { _ in }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        backend.emit(.sessionFailed(.network("socket dropped")))

        XCTAssertEqual(playback.stopAndFlushCount, 1)
    }

    func testCancelActiveResponseCallsStopAndFlush() async {
        let backend = ScriptedVoiceBackend(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true))
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProviderWithPlayback(
            backend: backend, playback: playback,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()

        // An .audio event sets _responseInFlight = true (event-stream gating).
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        provider.cancelActiveResponse()

        XCTAssertTrue(backend.calls.contains(.cancelResponse))
        XCTAssertEqual(playback.stopAndFlushCount, 1,
                       "cancelActiveResponse must flush the audio player")
        XCTAssertFalse(provider.isResponseInFlight)
        XCTAssertTrue(sink.names.contains("response.cancelled_by_coordinator"))
    }

    func testWithNoPlayerAudioIsIgnoredAndDiagnosticRecorded() async {
        // This tests the existing behavior is preserved when no player is provided.
        let backend = ScriptedVoiceBackend(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
        let sink = RecordingSink()
        let provider = makeProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.audio(VoiceAudioChunk(data: Data(repeating: 7, count: 64),
                                            format: .pcm16Mono24k, timestamp: 2)))

        XCTAssertEqual(received, [])
        XCTAssertTrue(sink.names.contains("audio.ignored"))
    }

    func testWithPlayerAudioIsNotRecordedAsIgnored() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))

        XCTAssertFalse(sink.names.contains("audio.ignored"),
                       "audio routed to a player is not logged as ignored")
    }

    func testConversationModeTeardownOnMatchCallsStopAndFlush() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(
            backend: backend, playback: playback,
            sessionPolicy: .conversation(idleClose: 60))
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        backend.emit(.transcriptPartial("yes"))

        XCTAssertEqual(received, [.yes])
        XCTAssertEqual(playback.stopAndFlushCount, 1,
                       "match resolution calls stopAndFlush in conversation mode")
    }

    func testShutdownCallsStopAndFlush() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(
            backend: backend, playback: playback,
            sessionPolicy: .conversation(idleClose: 60))

        provider.start { _ in }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        provider.shutdown()

        XCTAssertEqual(playback.stopAndFlushCount, 1)
    }

    func testAudioEventsAfterWindowCloseAreDropped() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(backend: backend, playback: playback)

        provider.start { _ in }
        await settle()
        provider.stop()

        // Audio arriving after the window is closed
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))

        XCTAssertEqual(playback.enqueued.count, 0,
                       "audio events after window close must not reach the player")
    }

    func testResponseCompletedClearsResponseInFlight() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let provider = makeProviderWithPlayback(
            backend: backend, playback: playback,
            sessionPolicy: .conversation(idleClose: 60))

        provider.start { _ in }
        await settle()

        XCTAssertFalse(provider.isResponseInFlight)
        backend.emit(.responseCompleted)
        XCTAssertFalse(provider.isResponseInFlight, "responseCompleted clears the flag")
        XCTAssertEqual(playback.finishStreamCount, 1)
    }

    // MARK: - Response-in-flight tracking at session scope (defect 1)

    /// A backend that polices the responding state: calling `beginUserTurn` while a
    /// response is in flight fails the session, exactly as `VoiceTurnStateMachine` does in
    /// `OpenAIRealtimeVoiceBackend`. `ScriptedVoiceBackend` does not model the responding
    /// state, which is why the original tests passed.
    @MainActor
    private final class RespondingAwareBackend: VoiceBackend {
        enum Call: Equatable {
            case open
            case close
            case beginUserTurn
            case endUserTurn
            case sendAudio(Int)
            case requestResponse(String)
            case cancelResponse
        }

        let capabilities: VoiceBackendCapabilities
        private(set) var calls: [Call] = []
        private(set) var isOpen = false
        private(set) var isTurnActive = false
        private(set) var isResponding = false
        private(set) var endUserTurnExpectations: [Bool] = []
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?
        /// When true, every `endUserTurn` creates a response, whatever `expectingResponse`
        /// says. TapQ no longer asks a turn end for a reply, so this is what keeps the
        /// pending-response suppression machinery — which must survive intact for the
        /// grounded reply — exercised against a backend that answers a commit anyway.
        private let respondsToEveryCommit: Bool

        init(capabilities: VoiceBackendCapabilities = VoiceBackendCapabilities(
            supportsBargeIn: true, producesAudio: true, duplex: true
        ), respondsToEveryCommit: Bool = false) {
            self.capabilities = capabilities
            self.respondsToEveryCommit = respondsToEveryCommit
        }

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append(.open)
            isOpen = true
            handler = onEvent
        }

        func close() {
            calls.append(.close)
            isOpen = false
            isTurnActive = false
            isResponding = false
            handler = nil
        }

        func beginUserTurn() {
            calls.append(.beginUserTurn)
            if isResponding {
                // This is the exact behavior OpenAIRealtimeVoiceBackend exhibits:
                // VoiceTurnStateMachine.beginUserTurn from .responding throws
                // responseAlreadyInFlight, which is surfaced via violated() -> failSession.
                let callback = handler
                isOpen = false
                isTurnActive = false
                isResponding = false
                handler = nil
                callback?(.sessionFailed(.protocolViolation(
                    "A response is already in flight.")))
                return
            }
            isTurnActive = true
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            calls.append(.endUserTurn)
            endUserTurnExpectations.append(expectingResponse)
            isTurnActive = false
            if expectingResponse || respondsToEveryCommit {
                // Simulates the OpenAI adapter: endUserTurn commits + requestResponse,
                // entering the responding state.
                isResponding = true
                return true
            }
            // Commit only, no response created.
            return false
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {
            calls.append(.sendAudio(chunk.data.count))
        }

        func requestResponse(text: String) {
            calls.append(.requestResponse(text))
            // The adapters move to `.responding` here; modeling it is what lets a test
            // prove `speakViaBackend` never asks for a second response over the first.
            isResponding = true
        }

        func cancelResponse() {
            calls.append(.cancelResponse)
            isResponding = false
        }

        func setNativeTurnDetection(_ enabled: Bool) {}

        func emit(_ event: VoiceBackendEvent) {
            if case .responseCompleted = event { isResponding = false }
            handler?(event)
        }
    }

    private func makeConversationProviderWithRespondingBackend(
        backend: RespondingAwareBackend,
        supportsBargeIn: Bool = true,
        instantIdle: Bool = true,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: supportsBargeIn,
            idleSleep: instantIdle ? { _ in } : { try? await Task.sleep(for: .seconds($0)) },
            diagnosticSink: sink)
    }

    func testConversationModeMatchResolvedSuppressesResponse() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        // Window 1: open, begin turn, backend starts responding with audio, then match.
        // The response must be suppressed via cancelResponse because _responseInFlight
        // is true (set by the audio event).
        provider.start { received.append($0) }
        await settle()
        // Simulate audio arriving from the backend response (sets _responseInFlight).
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
        XCTAssertTrue(backend.isOpen, "session stays open")
        XCTAssertFalse(backend.isResponding, "match-resolved response suppressed")
        XCTAssertTrue(backend.calls.contains(.cancelResponse),
                      "cancelResponse must follow endUserTurn for match-resolved windows")
        XCTAssertTrue(sink.names.contains("response.suppressed_match_resolved"))
        XCTAssertFalse(provider.isResponseInFlight,
                       "suppression must clear the response-in-flight flag")

        // Window 2: no response in flight, start() begins a new turn directly.
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isTurnActive, "new turn started successfully")
        XCTAssertTrue(backend.isOpen, "session survived")
    }

    /// When a response created by the commit is still pending at stop(), stop() now arms
    /// suppression. The first audio arriving between windows triggers the cancel. The next
    /// start() finds no response in flight and begins a turn immediately.
    ///
    /// TapQ's own commit no longer asks for a reply, so the backend here is one that
    /// answers every commit — the machinery must hold against any backend that produces a
    /// response TapQ did not author.
    func testConversationModeStopAfterCoordinatorEndpointSuppressesResponse() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        // Window 1: open, coordinator commits the turn, then stop() closes the window.
        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        XCTAssertTrue(backend.isResponding, "the backend answered the commit")
        provider.stop()
        // stop() now passes suppressResponse: true, arming the suppression mark.
        XCTAssertTrue(sink.names.contains("response.suppression_armed"),
                      "stop() must arm suppression for the pending response")

        // Between windows, audio arrives — suppression fires.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]), format: .pcm16Mono24k, timestamp: 1)))

        XCTAssertTrue(backend.calls.contains(.cancelResponse),
                      "the pending response must be cancelled on first audio")
        XCTAssertFalse(backend.isResponding, "response cancelled by suppression")
        XCTAssertTrue(sink.names.contains("response.suppressed_on_first_audio"))

        // Window 2: no response in flight, start() begins a new turn directly.
        provider.start { _ in }
        await settle()

        XCTAssertTrue(backend.isTurnActive, "new turn started immediately")
        XCTAssertTrue(backend.isOpen, "session survived")
    }

    func testConversationModeStartDuringResponseDefersWhenBargeInUnsupported() async {
        let backend = RespondingAwareBackend(capabilities: .transcriptOnly)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: false, sink: sink)
        var received: [VoiceCommand] = []

        // Window 1: trigger a response
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])

        // Between windows, mark response in flight.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]), format: .pcm16Mono24k, timestamp: 1)))

        // Window 2: cannot barge in, so the turn is deferred.
        provider.start { received.append($0) }
        await settle()

        XCTAssertFalse(backend.isTurnActive, "turn not started yet — deferred")
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))

        // Response completes: the deferred turn should now fire.
        backend.emit(.responseCompleted)
        XCTAssertTrue(backend.isTurnActive, "deferred turn started after responseCompleted")
        XCTAssertTrue(sink.names.contains("turn.started_after_deferred"))

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.yes, .no])
    }

    func testResponseInFlightTrackedAtSessionScopeBetweenWindows() async {
        let backend = RespondingAwareBackend()
        let provider = makeConversationProviderWithRespondingBackend(backend: backend)

        // Window 1: start, match, end window
        provider.start { _ in }
        await settle()
        backend.emit(.transcriptPartial("yes"))
        XCTAssertFalse(provider.isWindowOpenForTesting)

        // Between windows, audio arrives (response in flight from the prior commit).
        // handler is nil, but isResponseInFlight must still track this.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]), format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight,
                      "response-in-flight must be tracked even without a window")

        // responseCompleted clears it.
        backend.emit(.responseCompleted)
        XCTAssertFalse(provider.isResponseInFlight)
    }

    // MARK: - Session-death race: no-audio-yet gap (defect 1)

    /// With the ground-truth contract, stop() passes expectingResponse: false, so no
    /// response is created and no gap-deferral is needed. The turn starts immediately.
    /// This is the correct fix for the original defect 1 race: stop() no longer creates
    /// spurious responses.
    func testConversationModeStopWithNoResponseStartsTurnImmediately() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)
        var received: [VoiceCommand] = []

        // Window 1: open, then stop() — no response created (expectingResponse: false).
        provider.start { received.append($0) }
        await settle()
        provider.stop()
        XCTAssertFalse(backend.isResponding,
                       "stop passes expectingResponse: false — no response created")

        // Window 2: start() can begin a turn immediately (no gap to defer on).
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isTurnActive, "turn starts immediately — no response pending")
        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertFalse(sink.names.contains("turn.deferred_response_in_flight"),
                       "no deferral needed — no response was created")

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    /// Same race triggered by the coordinator's endActiveTurn instead of stop(), against a
    /// backend that answers every commit: the adapter enters .responding, and the next
    /// start() must defer rather than crashing into beginUserTurn.
    func testConversationModeStartAfterCoordinatorCommitGapDefersWithoutSessionDeath() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        // The coordinator commits the turn (wearer stopped speaking).
        provider.endActiveTurn()
        XCTAssertTrue(backend.isResponding, "the backend answered the commit")

        // The window closes (arbiter resolves or times out).
        provider.stop()

        // NO .audio emitted yet -- the response is cooking but has not produced audio.

        // Next window: must defer.
        provider.start { received.append($0) }
        await settle()

        XCTAssertFalse(backend.isTurnActive, "turn must not start -- response pending")
        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))

        // Response completes.
        backend.emit(.responseCompleted)
        XCTAssertTrue(backend.isTurnActive, "deferred turn started")

        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])
    }

    /// The pauseListening path: TTS starts while a turn is open, the turn is committed
    /// with expectingResponse: false (TTS pause does not want a model reply), TTS
    /// finishes, start() resumes. No response was created, so the turn starts immediately.
    func testConversationModeResumeAfterTTSPauseStartsTurnImmediately() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let playback = FakePlayback()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        let tts = FakeSpeechActivity()
        let combinedActivity = CombinedSpeechActivity(tts: tts, playback: playback)
        let gated = SpeechGatedVoice(
            wrapping: provider, activity: combinedActivity, diagnosticSink: sink)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // TTS starts (a notification prompt). This calls pauseListening, which ends the
        // turn with expectingResponse: false — no response is created.
        tts.setSpeaking(true)
        XCTAssertFalse(backend.isTurnActive, "turn ended by TTS pause")
        XCTAssertFalse(backend.isResponding,
                       "pauseListening passes expectingResponse: false — no response created")

        // TTS finishes: SpeechGatedVoice restarts the inner provider.
        tts.setSpeaking(false)
        await settle()

        // The turn starts immediately because no response is pending.
        XCTAssertTrue(backend.isTurnActive, "fresh turn after TTS drain — no deferral needed")
        XCTAssertTrue(backend.isOpen, "session survived")

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    // MARK: - Stale response-in-flight across conversations (defect 3)

    /// Regression for defect 3: audio arrives with no window open, idle-close
    /// fires (closing the session), then the next conversation's start() must
    /// beginUserTurn immediately with no cancelResponse call.
    ///
    /// Before the fix, _responseInFlight and pendingUserTurn were not cleared in
    /// fireIdleClose or on a fresh openWindow, so:
    ///   - A stale _responseInFlight from a previous conversation made the next
    ///     start() send a spurious cancelResponse (or defer the turn forever if
    ///     supportsBargeIn was false).
    ///   - A stale pendingUserTurn would wait on a responseCompleted that never
    ///     comes because the session was closed.
    func testStaleResponseInFlightClearedByIdleClose() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        // Conversation 1: open, speak, match -> response starts
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])

        // Audio arrives between windows (response in flight from the prior commit).
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        // Idle-close fires (the sleep returns instantly in this fixture).
        await settle()
        XCTAssertFalse(backend.isOpen, "session closed by idle-close")
        XCTAssertFalse(provider.isResponseInFlight,
                       "idle-close must clear the stale response-in-flight flag")

        // Conversation 2: start() must beginUserTurn immediately, no cancelResponse.
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isOpen, "a fresh session opened for conversation 2")
        XCTAssertTrue(backend.isTurnActive, "turn started immediately")
        XCTAssertFalse(backend.calls.suffix(3).contains(.cancelResponse),
                       "no spurious cancelResponse on the new conversation")

        // The new conversation works normally.
        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.yes, .no])
    }

    /// Same scenario but for pendingUserTurn: if barge-in is unsupported, a stale
    /// _responseInFlight would have caused start() to defer the turn forever.
    func testStaleResponseInFlightDoesNotWedgeTurnAfterIdleClose() async {
        let backend = RespondingAwareBackend(capabilities: .transcriptOnly)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: false, sink: sink)
        var received: [VoiceCommand] = []

        // Conversation 1: open, speak, match
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        // Audio between windows.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))

        // Idle-close fires.
        await settle()
        XCTAssertFalse(backend.isOpen)

        // Conversation 2: must not wedge on pendingUserTurn.
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive,
                      "turn must start immediately, not wait for a responseCompleted that will never come")
        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.yes, .no])
    }

    /// Verifies the openWindow success path clears stale state when the session
    /// was lost (e.g. sessionFailed while _responseInFlight was true) and a new
    /// openWindow is required.
    func testStaleResponseInFlightClearedByFreshOpenWindow() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        // Conversation 1
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("yes"))

        // Audio arrives, then the session fails.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        // sessionFailed clears _responseInFlight already (line 289), but let's
        // verify the openWindow path is also safe by going through it.
        backend.emit(.sessionFailed(.network("socket dropped")))

        // Conversation 2: needs a fresh open because the session died.
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)
        XCTAssertFalse(provider.isResponseInFlight,
                       "fresh openWindow must clear stale response-in-flight")
        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.yes, .no])
    }

    // MARK: - Idle timer with injectable sleep (defect 3)

    func testIdleTimerFiresWithoutRealSleep() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        // Uses instantIdle: the idle sleep returns immediately, so no real delay needed.
        let provider = makeConversationProvider(backend: backend, idleClose: 3600,
                                                instantIdle: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertTrue(backend.isOpen, "session open right after stop")

        // Settle lets the Task with the instant sleep deliver.
        await settle()

        XCTAssertFalse(backend.isOpen, "session closed by idle timer (no real sleep)")
        XCTAssertTrue(sink.names.contains("session.idle_closed"))
    }

    func testIdleTimerCancelledByNewWindow() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        // instantIdle makes the sleep return immediately; but if a new window opens first
        // (bumping idleGeneration), the fire should be suppressed.
        let provider = makeConversationProvider(backend: backend, idleClose: 3600,
                                                instantIdle: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()
        // Immediately reopen before the idle Task delivers.
        provider.start { _ in }
        await settle()

        XCTAssertTrue(backend.isOpen, "session stayed open — idle timer was cancelled")
        XCTAssertFalse(sink.names.contains("session.idle_closed"))
    }

    // MARK: - Conversation reopened callback (WP6)

    func testConversationReopenedCallbackFiresOnceAfterIdleClose() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, idleClose: 60,
                                                instantIdle: true, sink: sink)
        var reopenCount = 0
        provider.onConversationReopened = { reopenCount += 1 }

        // Conversation 1: open, stop, idle-close.
        provider.start { _ in }
        await settle()
        provider.stop()
        await settle() // idle-close fires (instant sleep)
        XCTAssertFalse(backend.isOpen, "session closed by idle timer")
        XCTAssertEqual(reopenCount, 0, "no reopen yet — this was the first conversation")

        // Conversation 2: reopen after idle-close.
        provider.start { _ in }
        await settle()
        XCTAssertTrue(backend.isOpen, "session reopened")
        XCTAssertEqual(reopenCount, 1, "callback fires exactly once on reopen after idle-close")
        XCTAssertTrue(sink.names.contains("session.reopened_after_idle"))
    }

    /// The ordering guarantee the seam is worth anything for: `onConversationReopened`
    /// fires BEFORE `backend.open`, so whatever a host resets there is in force for the
    /// session about to be established rather than for the one that idle-closed. Before the
    /// fix it fired after the open, which bound the new conversation to the old state.
    func testConversationReopenedCallbackPrecedesOpenCall() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend, idleClose: 60,
                                                instantIdle: true, sink: sink)

        var callbackFiredBeforeOpen = false
        var callbackCallCount = 0
        provider.onConversationReopened = {
            callbackCallCount += 1
            // At the time the callback fires, backend.isOpen must still be false
            // (the open hasn't happened yet).
            callbackFiredBeforeOpen = !backend.isOpen
        }

        // Conversation 1: open, stop, idle-close.
        provider.start { _ in }
        await settle()
        provider.stop()
        await settle()
        XCTAssertFalse(backend.isOpen)

        // Record open count before conversation 2.
        let openCountBefore = backend.calls.filter { $0 == .open }.count

        // Conversation 2: reopen after idle-close.
        provider.start { _ in }
        await settle()

        XCTAssertEqual(callbackCallCount, 1, "callback fired exactly once")
        XCTAssertTrue(callbackFiredBeforeOpen,
                      "onConversationReopened must fire BEFORE backend.open (decision 3)")
        let openCountAfter = backend.calls.filter { $0 == .open }.count
        XCTAssertEqual(openCountAfter, openCountBefore + 1,
                       "backend.open was called after the callback")
    }

    func testConversationReopenedCallbackDoesNotFireOnFirstOpen() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend, idleClose: 60)
        var reopenCount = 0
        provider.onConversationReopened = { reopenCount += 1 }

        // First open is not a reopen.
        provider.start { _ in }
        await settle()
        XCTAssertEqual(reopenCount, 0,
                       "the very first session open is not a conversation reopen")
    }

    func testConversationReopenedCallbackDoesNotFireOnSessionFailureReopen() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeConversationProvider(backend: backend, idleClose: 60)
        var reopenCount = 0
        provider.onConversationReopened = { reopenCount += 1 }

        // Open, then fail the session.
        provider.start { _ in }
        await settle()
        backend.emit(.sessionFailed(.network("dropped")))

        // Next start() reopens from sessionFailed, not from idle-close.
        provider.start { _ in }
        await settle()
        XCTAssertEqual(reopenCount, 0,
                       "session-failure reopen is not idle-close reopen")
    }

    // MARK: - Match-resolved response suppression scripted test (WP6)

    /// When stop() ends a conversation-mode window (no match), endUserTurn passes
    /// expectingResponse: false — no response is created. The backend stays in .committed
    /// (not .responding), and no cancelResponse is called.
    func testConversationModeStopCreatesNoResponse() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)

        provider.start { _ in }
        await settle()
        provider.stop()

        XCTAssertFalse(backend.isResponding,
                       "stop() passes expectingResponse: false — no response created")
        XCTAssertFalse(backend.calls.contains(.cancelResponse),
                       "no response to cancel")
        XCTAssertFalse(sink.names.contains("response.suppressed_match_resolved"))
    }

    /// Regression for defect 2: match-resolved response suppression must not call
    /// cancelResponse when no response is actually in flight. On the OpenAI path, the
    /// empty-turn guard can leave the adapter in .committed (not .responding) after
    /// endUserTurn, and on the Apple fallback, cancelResponse always throws
    /// bargeInUnsupported. The _responseInFlight guard prevents both session-killing paths.
    func testMatchResolvedDoesNotCallCancelResponseWhenNoResponseInFlight() async {
        // A backend that enforces VoiceTurnStateMachine legality (like the real adapters).
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        // The backend is in .userTurn -> endUserTurn moves to .committed.
        // RespondingAwareBackend.endUserTurn sets isResponding = true (simulating OpenAI's
        // commit + response.create). But if we match on a partial BEFORE any audio event
        // marks _responseInFlight = true, the provider must NOT call cancelResponse.
        // The response-in-flight flag is set by .audio events, not by endUserTurn.
        XCTAssertFalse(provider.isResponseInFlight,
                       "no audio events yet — response not in flight")

        // Match on the partial: this calls endWindowKeepSession(suppressResponse: true).
        // endUserTurn will set isResponding = true on the backend, but the provider's
        // _responseInFlight is still false, so cancelResponse must NOT be called.
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])

        // The backend survived — no session death from an illegal cancelResponse.
        XCTAssertTrue(backend.isOpen,
                      "session must survive — no illegal cancelResponse")
        XCTAssertFalse(sink.names.contains("response.suppressed_match_resolved"),
                       "suppression must not fire when no response is in flight")
    }

    /// Regression for defect 2b: when a response IS in flight at match time,
    /// the suppression path should still fire and clear _responseInFlight.
    func testMatchResolvedSuppressesWhenResponseActuallyInFlight() async {
        let backend = RespondingAwareBackend()
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        // Mark response in flight via an audio event.
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                             format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        // Match: should suppress the response.
        backend.emit(.transcriptPartial("yes"))
        XCTAssertEqual(received, [.yes])

        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertFalse(provider.isResponseInFlight,
                       "suppression must clear the response-in-flight flag")
        XCTAssertTrue(sink.names.contains("response.suppressed_match_resolved"))
    }

    /// Without supportsBargeIn, a match-resolved window does not attempt to suppress
    /// the response (cancelResponse is not valid on such backends). The response came from
    /// the commit at the coordinator endpoint; match resolves after transcript.
    func testMatchResolvedDoesNotSuppressWithoutBargeIn() async {
        let backend = RespondingAwareBackend(capabilities: .transcriptOnly,
                                             respondsToEveryCommit: true)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        // Coordinator commits the turn; this backend answers the commit.
        provider.endActiveTurn()
        // Transcript arrives post-commit and matches.
        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
        // Without barge-in, the response cannot be cancelled — it is left to drain.
        XCTAssertFalse(backend.calls.contains(.cancelResponse))
        XCTAssertFalse(sink.names.contains("response.suppressed_match_resolved"))
    }

    // MARK: - Gesture/timeout stop suppresses endpoint-created response (fixup defect 3)

    /// The coordinator commits the turn (wearer stopped speaking) and the backend answers
    /// the commit. Then the window resolves by gesture or timeout (stop()). With
    /// suppressResponse: true, the pending response is suppressed so it is not left to be
    /// dropped between windows. The next start() begins a turn immediately.
    func testStopAfterEndpointSuppressesPendingResponseAndNextStartIsImmediate() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, instantIdle: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()

        // Coordinator commits the turn (wearer stopped speaking).
        provider.endActiveTurn()
        XCTAssertTrue(backend.isResponding, "the backend answered the commit")

        // Gesture resolution: stop() is called.
        provider.stop()

        // stop() arms suppression for the pending response.
        XCTAssertTrue(sink.names.contains("response.suppression_armed"),
                      "stop() must arm suppression for the endpoint-created response")

        // The response completes (responseCompleted clears all flags).
        backend.emit(.responseCompleted)

        // Next window: no stale response state, turn starts immediately.
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isTurnActive,
                      "the next start() must begin a turn immediately")
        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertFalse(sink.names.contains("turn.deferred_response_in_flight"),
                       "no deferral — the response was suppressed at stop()")

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    // MARK: - Real OpenAI ordering: suppression via armed mark (defect 1 fix, defect 5)

    /// The real OpenAI flow for a match-resolved window after the coordinator committed,
    /// against a backend that answers every commit:
    /// beginUserTurn -> sendAudio -> endActiveTurn (commit, backend responds) ->
    /// transcriptFinal(match) -> first .audio arriving after resolution.
    /// The provider must cancel the response on first audio, with zero enqueues.
    func testRealOpenAIOrderingMatchAfterCommitSuppressesOnFirstAudio() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        var received: [VoiceCommand] = []

        // 1. Open and begin turn.
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // 2. Coordinator commits the turn (wearer stopped speaking).
        provider.endActiveTurn()
        XCTAssertTrue(backend.isResponding, "the backend answered the commit")

        // 3. Transcript arrives post-commit and matches.
        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
        XCTAssertFalse(provider.isWindowOpenForTesting, "window resolved by match")
        XCTAssertTrue(sink.names.contains("response.suppression_armed"),
                      "response pending but no audio yet — suppression armed")

        // 4. First .audio arrives AFTER the window is resolved.
        let chunk = VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                     format: .pcm16Mono24k, timestamp: 1)
        backend.emit(.audio(chunk))

        // The audio must trigger cancelResponse, not enqueue.
        XCTAssertTrue(backend.calls.contains(.cancelResponse),
                      "cancelResponse must fire on first audio of a suppressed response")
        XCTAssertEqual(playback.enqueued.count, 0,
                       "zero audio enqueues — the response was suppressed")
        XCTAssertFalse(provider.isResponseInFlight,
                       "response-in-flight must not be set for a cancelled response")
        XCTAssertTrue(sink.names.contains("response.suppressed_on_first_audio"))

        // 5. Next window starts immediately (no stale state).
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive, "fresh turn started")
    }

    /// Same real OpenAI ordering, but the response completes (responseCompleted) before
    /// any audio arrives. The suppression mark is cleared without a cancel.
    func testRealOpenAIOrderingResponseCompletedClearsSuppression() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let sink = RecordingSink()
        let provider = makeConversationProviderWithRespondingBackend(
            backend: backend, supportsBargeIn: true, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.endActiveTurn()
        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
        XCTAssertTrue(sink.names.contains("response.suppression_armed"))

        // responseCompleted arrives before any audio.
        backend.emit(.responseCompleted)
        XCTAssertFalse(provider.isResponseInFlight)

        // Next window starts without issue.
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)
    }

    // MARK: - No-response-created backend: next start() not wedged (defect 2 fix)

    /// A backend whose endUserTurn creates no response (e.g. the empty-turn guard on
    /// OpenAI skipped commit, or a transcript-only backend). The provider must derive
    /// _responsePendingFromTurn from the ground-truth return value. The next start()
    /// must begin a user turn immediately, not defer waiting for a responseCompleted
    /// that will never come.
    @MainActor
    private final class NoResponseBackend: VoiceBackend {
        enum Call: Equatable {
            case open, close, beginUserTurn, endUserTurn
            case sendAudio(Int), requestResponse(String), cancelResponse
        }
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                     duplex: true)
        private(set) var calls: [Call] = []
        private(set) var isOpen = false
        private(set) var isTurnActive = false
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            calls.append(.open)
            isOpen = true
            handler = onEvent
        }
        func close() { calls.append(.close); isOpen = false; isTurnActive = false; handler = nil }
        func beginUserTurn() { calls.append(.beginUserTurn); isTurnActive = true }
        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            calls.append(.endUserTurn)
            isTurnActive = false
            // This backend NEVER creates a response — simulates the empty-turn guard,
            // or a transcript-only backend.
            return false
        }
        func sendAudio(_ chunk: VoiceAudioChunk) { calls.append(.sendAudio(chunk.data.count)) }
        func requestResponse(text: String) { calls.append(.requestResponse(text)) }
        func cancelResponse() { calls.append(.cancelResponse) }
        func setNativeTurnDetection(_ enabled: Bool) {}

        func emit(_ event: VoiceBackendEvent) { handler?(event) }
    }

    func testNoResponseCreatedNextStartBeginsTurnImmediately() async {
        let backend = NoResponseBackend()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            idleSleep: { _ in },
            diagnosticSink: sink)
        var received: [VoiceCommand] = []

        // Window 1: coordinator commits the turn, but the backend creates no response
        // (e.g. the OpenAI empty-turn guard fires).
        provider.start { received.append($0) }
        await settle()
        provider.endActiveTurn()
        XCTAssertTrue(sink.names.contains("turn.committed_by_coordinator"))

        // Close the window.
        provider.stop()

        // Window 2: must start immediately — no response was created, so no deferral.
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isTurnActive,
                      "turn must start immediately — endUserTurn reported no response created")
        XCTAssertTrue(backend.isOpen, "session survived")
        XCTAssertFalse(sink.names.contains("turn.deferred_response_in_flight"),
                       "no deferral — the backend reported no response")

        backend.emit(.transcriptFinal("no"))
        XCTAssertEqual(received, [.no])
    }

    // MARK: - A window opening never cuts a sentence off (2026-08-27)

    /// The chop, in one test. A voice-session boundary closes the window, TapQ speaks a
    /// summary in the backend's own voice, and the loop's next eight-second listening window
    /// comes due while that sentence is still playing. The window used to cancel the
    /// response — nobody had spoken, nobody had asked for anything new, the only event was a
    /// clock — and the wearer heard their answer stop mid-word.
    private func makeSpeakingConversation(
        backend: RespondingAwareBackend,
        playback: FakePlayback,
        sink: RecordingSink
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
    }

    func testAWindowComingDueWaitsForTheBackendToFinishSpeaking() async {
        let backend = RespondingAwareBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeSpeakingConversation(
            backend: backend, playback: playback, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.stop()
        XCTAssertTrue(provider.speakViaBackend(
            "Claude Code finished the refactor, and the tests are green."))
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                            format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        // The next listening window opens while the sentence is still being spoken.
        provider.start { received.append($0) }
        await settle()

        XCTAssertFalse(backend.calls.contains(.cancelResponse),
                       "a window coming due is not a reason to stop a sentence")
        XCTAssertTrue(backend.isResponding, "the response is still the backend's to finish")
        XCTAssertFalse(backend.isTurnActive, "and the turn waits for it")
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))
        XCTAssertEqual(playback.stopAndFlushCount, 1,
                       "only the window close flushed; the new window flushed nothing")

        // The rest of the sentence still reaches the speaker.
        backend.emit(.audio(VoiceAudioChunk(data: Data([3, 4]),
                                            format: .pcm16Mono24k, timestamp: 2)))
        XCTAssertEqual(playback.enqueued.count, 1,
                       "audio between windows is dropped; audio inside this one is not")

        // The response ends by itself, which is what the window was waiting for.
        backend.emit(.responseCompleted)
        XCTAssertTrue(backend.isTurnActive, "the deferred turn starts once the voice stops")
        XCTAssertTrue(sink.names.contains("turn.started_after_deferred"))

        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
    }

    /// The other half of the rule: the wearer talking over the backend is not a clock, and
    /// it still cuts the sentence off at once. The turn it was waiting on opens here rather
    /// than one `responseCompleted` later — the wearer is already speaking.
    func testTheWearerTalkingOverTheBackendStillCancelsImmediately() async {
        let backend = RespondingAwareBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeSpeakingConversation(
            backend: backend, playback: playback, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.stop()
        XCTAssertTrue(provider.speakViaBackend("A long answer nobody wants to hear out."))
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                            format: .pcm16Mono24k, timestamp: 1)))
        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(sink.names.contains("turn.deferred_response_in_flight"))

        provider.cancelActiveResponse()

        XCTAssertTrue(backend.calls.contains(.cancelResponse))
        XCTAssertFalse(backend.isResponding, "barge-in stops the sentence now")
        XCTAssertTrue(sink.names.contains("response.cancelled_by_coordinator"))
        XCTAssertTrue(backend.isTurnActive, "and the deferred turn opens with it")
        XCTAssertTrue(sink.names.contains("turn.started_after_barge_in"))

        // The cancelled response still owes a terminal frame. It must open nothing twice:
        // a second `beginUserTurn` is `turnAlreadyInProgress`, which is a dead session.
        backend.emit(.responseCompleted)
        XCTAssertEqual(backend.calls.filter { $0 == .beginUserTurn }.count, 2,
                       "one turn for the first window, one for the barge-in")

        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes])
    }

    /// And the third cancel, unchanged: a window that resolves while the response it created
    /// is still arriving suppresses it immediately. That response has lost its audience —
    /// this is not a wait, it is a discard.
    func testAResolvedWindowStillSuppressesItsOwnResponseImmediately() async {
        let backend = RespondingAwareBackend(respondsToEveryCommit: true)
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeSpeakingConversation(
            backend: backend, playback: playback, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        provider.endActiveTurn()
        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2]),
                                            format: .pcm16Mono24k, timestamp: 1)))
        XCTAssertTrue(provider.isResponseInFlight)

        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(received, [.yes])
        XCTAssertTrue(backend.calls.contains(.cancelResponse))
        XCTAssertTrue(sink.names.contains("response.suppressed_match_resolved"))
        XCTAssertFalse(backend.isResponding)
    }

    // MARK: - windowPaused cleared on stop/endWindowKeepSession (defect 4)

    func testWindowPausedClearedByStopSoNewWindowIsNotTreatedAsResume() async {
        let backend = RespondingAwareBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // pauseListening sets windowPaused = true.
        provider.pauseListening()
        XCTAssertTrue(sink.names.contains("listening.paused"))

        // stop() must clear windowPaused.
        provider.stop()

        // A genuinely new window: must be a fresh start (beginUserTurn), not a
        // resume of the paused one (which would check for in-flight responses).
        provider.start { received.append($0) }
        await settle()

        XCTAssertTrue(backend.isTurnActive,
                      "a genuinely new window must begin a turn, not defer as a resume")
        XCTAssertTrue(backend.isOpen)

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    // MARK: - Free-form (WP8)

    private func makeFreeformProvider(
        backend: ScriptedVoiceBackend,
        freeformEnabled: Bool = true,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            freeformEnabled: freeformEnabled,
            idleSleep: { _ in },
            diagnosticSink: sink)
    }

    func testFreeformDeliveredForUnmatchedFinalWhenEnabled() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeFreeformProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("deploy the blue canary"))

        XCTAssertEqual(received, [.freeform("deploy the blue canary")])
        XCTAssertTrue(sink.names.contains("freeform.delivered"))
    }

    func testFreeformNotDeliveredWhenDisabled() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeFreeformProvider(backend: backend, freeformEnabled: false, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("deploy the blue canary"))

        XCTAssertEqual(received, [],
                       "freeform must not be delivered when disabled")
        XCTAssertFalse(sink.names.contains("freeform.delivered"))
    }

    func testFreeformNotDeliveredForMatchedFinal() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeFreeformProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(received, [.yes],
                       "a matching transcript must produce the command, never freeform")
    }

    func testFreeformNotDeliveredForPartials() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeFreeformProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptPartial("hello world"))

        XCTAssertEqual(received, [],
                       "partials never produce freeform even when enabled")
    }

    func testFreeformEmptyWhitespaceTranscriptNotDelivered() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeFreeformProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("   \n  "))

        XCTAssertEqual(received, [],
                       "empty/whitespace-only transcripts must not produce freeform")
        XCTAssertFalse(sink.names.contains("freeform.delivered"))
    }

    func testFreeformDeliveredOnlyOncePerTurn() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeFreeformProvider(backend: backend, sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("first answer"))
        backend.emit(.transcriptFinal("second answer"))

        XCTAssertEqual(received, [.freeform("first answer")],
                       "freeform must be delivered exactly once per turn")
        XCTAssertEqual(sink.names.filter { $0 == "freeform.delivered" }.count, 1)
    }

    func testFreeformResetOnNewTurn() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeFreeformProvider(backend: backend)
        var received: [VoiceCommand] = []

        // First turn
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("answer one"))
        XCTAssertEqual(received, [.freeform("answer one")])
        // Close the window (arbiter resolves or times out -> stop)
        provider.stop()

        // Second turn
        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("answer two"))
        XCTAssertEqual(received, [.freeform("answer one"), .freeform("answer two")],
                       "freeform must be available again on the next turn")
    }

    func testFreeformTrimsWhitespace() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeFreeformProvider(backend: backend)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        backend.emit(.transcriptFinal("  padded answer  "))

        XCTAssertEqual(received, [.freeform("padded answer")],
                       "freeform text must be trimmed")
    }

    func testFreeformOnTranscriptFinalStillFires() async {
        let backend = ScriptedVoiceBackend()
        let provider = makeFreeformProvider(backend: backend)
        var finals: [(String, Bool)] = []
        provider.onTranscriptFinal = { text, matched in finals.append((text, matched)) }

        provider.start { _ in }
        await settle()
        backend.emit(.transcriptFinal("freeform text"))

        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals[0].0, "freeform text")
        XCTAssertFalse(finals[0].1, "freeform text is unmatched")
    }

    // MARK: - Playback activity must not self-cancel (defect 1 fix)

    /// Full-composition test proving that backend audio can play to completion on the
    /// composed --voice-backend openai-realtime path:
    ///   SpeechGatedVoice(
    ///     CombinedSpeechActivity(tts, fakePlayback),
    ///     provider(responseAudio: fakePlayback, .conversation, supportsBargeIn: true)
    ///   )
    ///
    /// Before the fix, the first enqueue raised isPlaying synchronously, which
    /// CombinedSpeechActivity relayed to SpeechGatedVoice, which called provider.stop(),
    /// which called endWindowKeepSession() -> responseAudio.stopAndFlush(), flushing the
    /// chunk just enqueued. The falling edge then reopened the mic, which called
    /// provider.start() -> cancelResponse(), killing the cloud response. Every chunk
    /// repeated this cascade: enqueue, stopAndFlush, cancelResponse, beginUserTurn,
    /// endUserTurn — per chunk. Net effect: no audio ever played.
    func testPlaybackActivityDoesNotFlushOrCancelResponse() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        let tts = FakeSpeechActivity()
        let combinedActivity = CombinedSpeechActivity(tts: tts, playback: playback)
        let gated = SpeechGatedVoice(
            wrapping: provider, activity: combinedActivity, diagnosticSink: sink)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // Backend sends audio: this makes playback.isPlaying = true via enqueue,
        // which triggers CombinedSpeechActivity -> SpeechGatedVoice -> pauseListening.
        // The response must NOT be cancelled or flushed.
        let chunk1 = VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                      format: .pcm16Mono24k, timestamp: 1)
        backend.emit(.audio(chunk1))

        XCTAssertTrue(playback.isPlaying,
                      "playback must stay busy — the audio must not be flushed")
        XCTAssertEqual(playback.stopAndFlushCount, 0,
                       "stopAndFlush must NOT be called by the activity-driven pause")
        XCTAssertFalse(backend.calls.contains(.cancelResponse),
                       "cancelResponse must NOT be called — the response is the answer")
        XCTAssertEqual(playback.enqueued.count, 1, "the first chunk must be enqueued")

        // More chunks should still reach the player despite the pause.
        let chunk2 = VoiceAudioChunk(data: Data([5, 6, 7, 8]),
                                      format: .pcm16Mono24k, timestamp: 2)
        backend.emit(.audio(chunk2))
        XCTAssertEqual(playback.enqueued.count, 2,
                       "subsequent chunks must route to the player during the pause")

        // Response completes: finishStream called, then playback drains.
        backend.emit(.responseCompleted)
        XCTAssertEqual(playback.finishStreamCount, 1)

        // Simulate playback drain (all buffers completed).
        // This triggers CombinedSpeechActivity -> SpeechGatedVoice.speakingChanged(false)
        // -> startInner() -> provider.start().
        playback.completeDrain()
        await settle()

        // A fresh turn should have started on the still-open session.
        XCTAssertTrue(backend.isOpen, "session must stay open")
        XCTAssertTrue(backend.isTurnActive, "fresh turn started after playback drain")
        XCTAssertFalse(backend.calls.contains(.cancelResponse),
                       "still no cancelResponse — the response completed naturally")
    }

    /// Same composition as above, but with WearerGatedVoice in the chain:
    ///   SpeechGatedVoice(WearerGatedVoice(provider))
    /// Verifies that pauseListening propagates through the full gate stack.
    func testPlaybackActivityPropagatesThroughWearerGate() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        let fakeSignal = FakeWearerSpeechSignal()
        let wearerGated = WearerGatedVoice(
            wrapping: provider, signal: fakeSignal, diagnosticSink: sink)
        let tts = FakeSpeechActivity()
        let combinedActivity = CombinedSpeechActivity(tts: tts, playback: playback)
        let gated = SpeechGatedVoice(
            wrapping: wearerGated, activity: combinedActivity, diagnosticSink: sink)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        await settle()

        backend.emit(.audio(VoiceAudioChunk(data: Data([1, 2, 3, 4]),
                                             format: .pcm16Mono24k, timestamp: 1)))

        XCTAssertTrue(playback.isPlaying, "playback must stay busy through the gate stack")
        XCTAssertEqual(playback.stopAndFlushCount, 0,
                       "stopAndFlush must not be called through WearerGatedVoice")
        XCTAssertFalse(backend.calls.contains(.cancelResponse))
    }

    /// When TTS speaks during an open turn (e.g. notification), pauseListening must still
    /// end the turn — the "turn never spans a TTS-busy interval" invariant must hold even
    /// with the new pauseListening path. This test uses the conversation-mode provider with
    /// a FakePlayback (not playing) to verify the TTS case.
    func testPauseListeningEndsTurnWhenTTSNotPlayback() async {
        let backend = ScriptedVoiceBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            idleSleep: { _ in },
            diagnosticSink: sink)
        let tts = FakeSpeechActivity()
        let combinedActivity = CombinedSpeechActivity(tts: tts, playback: playback)
        let gated = SpeechGatedVoice(
            wrapping: provider, activity: combinedActivity, diagnosticSink: sink)
        var received: [VoiceCommand] = []

        gated.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // TTS starts (notification). Playback is NOT active — the pause should end the turn.
        tts.setSpeaking(true)
        XCTAssertFalse(backend.isTurnActive,
                       "turn must end when TTS starts (not playback)")
        XCTAssertTrue(backend.isOpen, "session stays open")
        XCTAssertTrue(sink.names.contains("listening.paused"))

        // The backend completes the response that endUserTurn triggered. On the real
        // OpenAI path, commit + response.create run when the turn is ended, and
        // responseCompleted arrives after the model finishes — typically while TTS is
        // still speaking. Modeling it here keeps the test honest about the turn-end →
        // response lifecycle that the session-death-race fix tracks.
        backend.emit(.responseCompleted)

        // TTS finishes: a fresh turn starts.
        tts.setSpeaking(false)
        await settle()
        XCTAssertTrue(backend.isTurnActive, "fresh turn after TTS drain")

        backend.emit(.transcriptPartial("no"))
        XCTAssertEqual(received, [.no])
    }

    /// A fake WearerSpeechSignaling for composition tests. Always reports signal
    /// unavailable so the gate fails open (all commands pass through).
    @MainActor
    private final class FakeWearerSpeechSignal: WearerSpeechSignaling {
        var isWearerSpeaking = false
        var isSignalAvailable = false
        var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?
    }

    // MARK: - Turn detection mode

    /// The realtime shape: the only capabilities under which the question is asked at all.
    private static let realtimeCapabilities = VoiceBackendCapabilities(
        supportsBargeIn: true, producesAudio: true, duplex: true,
        supportsNativeTurnDetection: true)

    /// A settable answer to "is TapQ's own turn signal live", so a test can put the AirPods
    /// in and take them out between windows.
    @MainActor
    private final class LivenessBox {
        var isLive: Bool
        init(_ isLive: Bool) { self.isLive = isLive }
    }

    private func makeConversationProvider(
        backend: ScriptedVoiceBackend,
        liveness: LivenessBox,
        sink: RecordingSink = RecordingSink()
    ) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: Self.match,
            sessionPolicy: .conversation(idleClose: 3_600),
            supportsBargeIn: true,
            isWearerTurnSignalLive: { liveness.isLive },
            idleSleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            diagnosticSink: sink
        )
    }

    /// No wearer turn signal: the window opens with the backend's own VAD doing the
    /// endpointing, and the log says why.
    func testAWindowWithNoWearerTurnSignalDegradesToNativeTurnDetection() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(false), sink: sink)

        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.nativeTurnDetection, [true])
        XCTAssertEqual(sink.events.first { $0.name == "turn_detection.native" }?
            .fields["reason"], "no_wearer_turn_signal")
    }

    /// The IMU-armed run, unchanged. This is the assertion that the carve-out stayed a
    /// carve-out: a wearer with working AirPods must reach the same wire traffic they always
    /// did, and the remote endpoint must not be told where their sentences end.
    func testAWindowWithALiveWearerTurnSignalKeepsTurnArbitrationOnTapQsSide() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(true), sink: sink)

        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.nativeTurnDetection, [false])
        XCTAssertEqual(sink.events.first { $0.name == "turn_detection.manual" }?
            .fields["reason"], "wearer_turn_signal_live")
        XCTAssertTrue(sink.names.filter { $0 == "turn_detection.native" }.isEmpty)
    }

    /// AirPods go in and come out mid-run, and each window is endpointed by whichever of the
    /// two endpointers is actually working. Only the windows where the answer *changed* send
    /// anything: the provider asks every time, the backend hears about it only when it
    /// matters.
    func testTheModeFollowsTheSignalFromOneWindowToTheNext() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let liveness = LivenessBox(false)
        let provider = makeConversationProvider(backend: backend, liveness: liveness)

        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.nativeTurnDetection, [true])

        // The wearer puts their AirPods in: the next window is TapQ's again.
        provider.stop()
        liveness.isLive = true
        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.nativeTurnDetection, [true, false])

        // A window with no change sends nothing.
        provider.stop()
        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.nativeTurnDetection, [true, false])

        // And out again.
        provider.stop()
        liveness.isLive = false
        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.nativeTurnDetection, [true, false, true])
    }

    /// The motion-loss path: the *first* window of a run started with `--imu-turn-control`
    /// and no AirPods. The flag says AirPods are expected, so the window opens in manual
    /// mode; the detector discovers the availability lie a moment later and the host
    /// re-asks, on the live session, inside the window a wearer is waiting on.
    func testRefreshSwitchesTheLiveWindowWhenMotionIsConfirmedGone() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let liveness = LivenessBox(true)
        let provider = makeConversationProvider(backend: backend, liveness: liveness)

        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.nativeTurnDetection, [false])

        liveness.isLive = false
        provider.refreshTurnDetectionMode()
        XCTAssertEqual(backend.nativeTurnDetection, [false, true],
                       "the window already open is degraded in place")
    }

    /// A backend that cannot do it is never asked, whatever the signal says.
    func testABackendWithoutTheCapabilityIsNeverAsked() async {
        let backend = ScriptedVoiceBackend()
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(false), sink: sink)

        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.nativeTurnDetection, [])
        XCTAssertEqual(sink.events.first { $0.name == "turn_detection.manual" }?
            .fields["reason"], "unsupported")
    }

    /// The default composition — no liveness source at all — keeps turn arbitration, which
    /// is what makes this change inert for every caller that has not opted in.
    func testWithNoLivenessSourceTheProviderNeverDegrades() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let provider = VoiceBackendCommandProvider(backend: backend, match: Self.match)

        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.nativeTurnDetection, [false])
    }

    /// The degraded endpoint firing, end to end at this layer: the commit arrives, the turn
    /// stays open, and the transcript that follows resolves the window.
    func testANativeCommitLeavesTheTurnOpenAndItsTranscriptResolvesTheWindow() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(false), sink: sink)
        var received: [VoiceCommand] = []

        provider.start { received.append($0) }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        backend.emit(.userAudioCommittedByBackend)
        XCTAssertTrue(provider.isUserTurnActiveForCoordination,
                      "the wearer may still be talking; the turn is not TapQ's to close here")
        XCTAssertTrue(backend.isTurnActive)
        XCTAssertEqual(received, [], "a commit is not a decision")
        XCTAssertTrue(sink.names.contains("turn.committed_by_backend"))

        backend.emit(.transcriptFinal("yes"))
        XCTAssertEqual(received, [.yes], "the post-commit transcript resolves the window")
        XCTAssertEqual(backend.endUserTurnExpectations, [false],
                       "and the window's own turn end never asks for a spoken reply")
    }

    // MARK: - VoiceTurnTiming

    /// The two facts the arbiter's clock reads. Listening begins with the backend turn, not
    /// with `start`; a sentence is unresolved from its onset until its commit lands.
    func testTimingReportsListeningWithTheTurnAndASentenceUntilItsCommit() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(false), sink: RecordingSink())

        XCTAssertFalse(provider.isListening, "nothing is open yet")
        provider.start { _ in }
        await settle()
        XCTAssertTrue(provider.isListening, "the turn began: the wearer can be heard")
        XCTAssertFalse(provider.isWearerTurnUnresolved)

        backend.emit(.nativeSpeechStarted(selfAudio: false))
        XCTAssertTrue(provider.isWearerTurnUnresolved, "mid-sentence")

        backend.emit(.userAudioCommittedByBackend)
        XCTAssertFalse(provider.isWearerTurnUnresolved,
                       "committed on the grammar path: nothing is with the model")

        provider.stop()
        XCTAssertFalse(provider.isListening)
    }

    // MARK: - Carried turn (grammar path)

    /// The grammar path's half of the carry: a transcript that settles between two windows
    /// is the one thing that can resolve the next window outright, so it is held and
    /// replayed into it rather than dropped on the floor with nobody listening.
    func testATranscriptSettledBetweenWindowsResolvesTheNextWindow() async {
        let backend = ScriptedVoiceBackend(capabilities: Self.realtimeCapabilities)
        let sink = RecordingSink()
        let provider = makeConversationProvider(backend: backend,
                                                liveness: LivenessBox(false), sink: sink)
        var first: [VoiceCommand] = []
        var second: [VoiceCommand] = []

        provider.start { first.append($0) }
        await settle()
        backend.emit(.nativeSpeechStarted(selfAudio: false))
        provider.stopUnresolved()
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(.transcriptFinal("yes"))

        XCTAssertEqual(backend.calls, [.open, .beginUserTurn],
                       "the turn was ended under a sentence still being spoken")
        XCTAssertEqual(first, [], "the window that timed out is over")

        provider.start { second.append($0) }
        await settle()

        XCTAssertEqual(second, [.yes], "the sentence resolved the window that took it over")
        XCTAssertEqual(backend.calls, [.open, .beginUserTurn, .endUserTurn],
                       "one turn, taken over rather than reopened, ended by the match")
        XCTAssertTrue(sink.names.contains("window.resumed_carried_turn"))
    }
}
