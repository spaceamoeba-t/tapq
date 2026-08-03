import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

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

        func endUserTurn() {
            calls.append(.endUserTurn)
            XCTAssertTrue(isOpen, "endUserTurn on a closed session")
            XCTAssertTrue(isTurnActive, "endUserTurn with no turn open")
            isTurnActive = false
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
}
