import XCTest
@testable import TapQVoiceBackends
import TapQContracts

@MainActor
final class FailThroughVoiceBackendTests: XCTestCase {
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
    }

    @MainActor
    final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private let chunk = VoiceAudioChunk(data: Data(repeating: 3, count: 64),
                                        format: .pcm16Mono24k, timestamp: 0)

    private func makeBackends(sink: RecordingSink = RecordingSink())
        -> (ScriptedVoiceBackend, ScriptedVoiceBackend, FailThroughVoiceBackend) {
        let primary = ScriptedVoiceBackend(
            name: "primary",
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
        let fallback = ScriptedVoiceBackend(name: "fallback")
        return (primary, fallback,
                FailThroughVoiceBackend(primary: primary, fallback: fallback,
                                        diagnosticSink: sink))
    }

    // MARK: - Healthy primary

    func testAHealthyPrimaryCostsTheFallbackNothing() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        wrapper.sendAudio(chunk)
        primary.emit(.transcriptPartial("yes"))
        wrapper.endUserTurn(expectingResponse: true)
        wrapper.close()

        XCTAssertEqual(primary.calls,
                       [.open, .beginUserTurn, .sendAudio(64), .endUserTurn, .close])
        XCTAssertEqual(fallback.calls, [], "the fallback must be entirely inert until needed")
        XCTAssertEqual(events.events, [.transcriptPartial("yes")])
    }

    func testEveryCallIsForwardedToThePrimary() async throws {
        let (primary, _, wrapper) = makeBackends()
        try await wrapper.open { _ in }

        wrapper.requestResponse(text: "done")
        wrapper.cancelResponse()

        XCTAssertEqual(primary.calls, [.open, .requestResponse("done"), .cancelResponse])
    }

    func testCapabilitiesAreTheIntersectionOfBoth() {
        let (_, _, wrapper) = makeBackends()
        XCTAssertEqual(wrapper.capabilities, .transcriptOnly,
                       "a caller must not be handed a capability the fallback lacks")

        let duplex = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                              duplex: true)
        let both = FailThroughVoiceBackend(
            primary: ScriptedVoiceBackend(capabilities: duplex),
            fallback: ScriptedVoiceBackend(capabilities: duplex))
        XCTAssertEqual(both.capabilities, duplex)
    }

    // MARK: - Open-time failover

    func testPrimaryOpenFailureFallsThroughTransparently() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeBackends(sink: sink)
        primary.openFailure = .network("no route to host")
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        fallback.emit(.transcriptFinal("yes"))

        XCTAssertEqual(primary.calls, [.open], "a session that never opened is not closed")
        XCTAssertEqual(fallback.calls, [.open, .beginUserTurn])
        XCTAssertEqual(events.events, [.transcriptFinal("yes")],
                       "the caller never learns which pipe answered")
        XCTAssertTrue(sink.names.contains("primary.open_failed"))
        XCTAssertTrue(sink.names.contains("fallback.opened"))
    }

    func testBothOpenFailuresSurfaceTheFallbacksFailure() async {
        let (primary, fallback, wrapper) = makeBackends()
        primary.openFailure = .network("no route to host")
        fallback.openFailure = .authorization("speech recognition unavailable")

        do {
            try await wrapper.open { _ in XCTFail("no session was ever established") }
            XCTFail("there is nothing left to fall through to")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure,
                           .authorization("speech recognition unavailable"))
        }
        XCTAssertEqual(primary.calls, [.open])
        XCTAssertEqual(fallback.calls, [.open])
    }

    func testAFailedOpenLeavesNothingBehindForTheNextAttempt() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        primary.openFailure = .network("first attempt")
        fallback.openFailure = .network("first attempt")
        try? await wrapper.open { _ in }

        primary.openFailure = nil
        fallback.openFailure = nil
        try await wrapper.open { _ in }

        XCTAssertEqual(primary.calls, [.open, .open])
        XCTAssertEqual(fallback.calls, [.open], "the retry starts from the primary again")
    }

    func testOpeningTwiceIsAProtocolViolation() async throws {
        let (_, _, wrapper) = makeBackends()
        try await wrapper.open { _ in }

        do {
            try await wrapper.open { _ in }
            XCTFail("a second open on a live session is a programming error")
        } catch {
            guard case .protocolViolation? = error as? VoiceBackendFailure else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    // MARK: - Mid-session failover

    func testMidSessionFailureReopensTheFallbackWithTheActiveTurn() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeBackends(sink: sink)
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        wrapper.sendAudio(chunk)

        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()

        XCTAssertEqual(primary.calls, [.open, .beginUserTurn, .sendAudio(64), .close])
        XCTAssertEqual(fallback.calls, [.open, .beginUserTurn],
                       "the wearer is mid-sentence; the window must survive the switch")
        XCTAssertEqual(events.failures, [], "a recovered session is not a failed one")
        XCTAssertTrue(sink.names.contains("fallback.turn_resumed"))

        fallback.emit(.transcriptFinal("yes"))
        XCTAssertEqual(events.events, [.transcriptFinal("yes")])
    }

    func testMidSessionFailureWithNoTurnOpenDoesNotOpenOne() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        try await wrapper.open { _ in }

        primary.emit(.sessionFailed(.closed("peer hung up")))
        await settle()

        XCTAssertEqual(fallback.calls, [.open], "state is replayed, not invented")
    }

    func testAudioArrivingDuringTheSwitchIsDroppedNotMisrouted() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeBackends(sink: sink)
        fallback.openGate = { await Task.yield() }
        try await wrapper.open { _ in }
        wrapper.beginUserTurn()

        primary.emit(.sessionFailed(.network("socket dropped")))
        wrapper.sendAudio(chunk)
        await settle()

        XCTAssertFalse(primary.calls.contains(.sendAudio(64)),
                       "no audio into a backend that is already gone")
        XCTAssertFalse(fallback.calls.contains(.sendAudio(64)),
                       "and none into one whose turn has not started")
        XCTAssertTrue(sink.names.contains("audio.dropped"))
        XCTAssertEqual(fallback.calls, [.open, .beginUserTurn])
    }

    func testATurnEndedDuringTheSwitchIsNotResumed() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        fallback.openGate = { await Task.yield() }
        try await wrapper.open { _ in }
        wrapper.beginUserTurn()

        primary.emit(.sessionFailed(.network("socket dropped")))
        wrapper.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertEqual(fallback.calls, [.open],
                       "the window closed while switching; reopening it would reopen the mic")
    }

    func testFallbackFailureAfterAFailoverSurfacesToTheCaller() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        fallback.openFailure = .authorization("speech recognition unavailable")
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()

        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()

        XCTAssertEqual(events.failures, [.authorization("speech recognition unavailable")],
                       "with nothing left underneath, the caller has to be told")
    }

    func testAFallbackSessionFailureIsSurfacedRatherThanFailedOverAgain() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        primary.openFailure = .network("no route to host")
        let events = EventLog()
        try await wrapper.open { events.append($0) }

        fallback.emit(.sessionFailed(.network("microphone route changed")))
        await settle()

        XCTAssertEqual(events.failures, [.network("microphone route changed")])
        XCTAssertEqual(primary.calls, [.open], "failover happens once, not in a loop")
    }

    func testLateEventsFromTheDeadPrimaryAreIgnored() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()

        primary.emit(.transcriptFinal("yes"), toHandler: 0)

        XCTAssertEqual(events.events, [], "a transcript from the dead pipe resolves nothing")
        fallback.emit(.transcriptFinal("no"))
        XCTAssertEqual(events.events, [.transcriptFinal("no")])
    }

    // MARK: - Teardown

    func testCloseIsIdempotentAndClosesOnlyWhatWasOpened() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        try await wrapper.open { _ in }

        wrapper.close()
        wrapper.close()

        XCTAssertEqual(primary.calls, [.open, .close])
        XCTAssertEqual(fallback.calls, [])
    }

    func testCloseAfterAFailoverClosesTheFallbackOnly() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        try await wrapper.open { _ in }
        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()

        wrapper.close()

        XCTAssertEqual(primary.calls, [.open, .close], "closed once, when it failed")
        XCTAssertEqual(fallback.calls, [.open, .close])
    }

    func testCloseDuringAFailoverAbandonsTheFallback() async throws {
        let (primary, fallback, wrapper) = makeBackends()
        let gate = AsyncGate()
        fallback.openGate = { await gate.wait() }
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()

        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()
        wrapper.close()
        gate.open()
        await settle()

        XCTAssertEqual(fallback.calls, [.open, .close],
                       "a fallback that finishes opening after close must not be left running")
        XCTAssertEqual(events.events, [])
    }

    func testResponseTrafficDuringTheSwitchIsDropped() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeBackends(sink: sink)
        fallback.openGate = { await Task.yield() }
        try await wrapper.open { _ in }

        primary.emit(.sessionFailed(.network("socket dropped")))
        wrapper.requestResponse(text: "into the void")
        wrapper.cancelResponse()
        await settle()

        XCTAssertEqual(fallback.calls, [.open],
                       "a response addressed to a pipe that no longer exists goes nowhere")
        XCTAssertTrue(sink.names.contains("response.dropped"))
        XCTAssertTrue(sink.names.contains("cancel.dropped"))
    }

    func testCloseWithoutOpenTouchesNeitherBackend() {
        let (primary, fallback, wrapper) = makeBackends()

        wrapper.close()

        XCTAssertEqual(primary.calls, [])
        XCTAssertEqual(fallback.calls, [])
    }

    func testEventsAfterCloseAreDropped() async throws {
        let (primary, _, wrapper) = makeBackends()
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.close()

        primary.emit(.transcriptFinal("yes"), toHandler: 0)

        XCTAssertEqual(events.events, [])
    }

    // MARK: - Composition with the realtime adapter

    /// The shape WP9 composes: a realtime primary that dies mid-window, an on-device
    /// fallback that answers. Proven above the adapter seam, with a scripted socket.
    func testARealtimeSessionThatDiesMidWindowResolvesOnTheFallback() async throws {
        let server = ScriptedRealtimeServer()
        let primary = OpenAIRealtimeVoiceBackend(transport: server, timeout: 1)
        let fallback = ScriptedVoiceBackend(name: "apple")
        let wrapper = FailThroughVoiceBackend(primary: primary, fallback: fallback)
        let events = EventLog()

        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()
        wrapper.sendAudio(VoiceAudioChunk(data: Data(repeating: 5, count: 480),
                                          format: OpenAIRealtimeVoiceBackend.audioFormat,
                                          timestamp: 0))
        await settle()
        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append"])

        server.disconnect()
        await settle()

        XCTAssertEqual(fallback.calls, [.open, .beginUserTurn])
        fallback.emit(.transcriptFinal("yes"))
        XCTAssertEqual(events.events, [.transcriptFinal("yes")])
        XCTAssertEqual(events.failures, [],
                       "a dropped socket must never leave the wearer with a dead window")
    }

    // MARK: - Sticky fail-through

    private func makeStickyBackends(sink: RecordingSink = RecordingSink())
        -> (ScriptedVoiceBackend, ScriptedVoiceBackend, FailThroughVoiceBackend) {
        let primary = ScriptedVoiceBackend(
            name: "primary",
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
        let fallback = ScriptedVoiceBackend(name: "fallback")
        return (primary, fallback,
                FailThroughVoiceBackend(primary: primary, fallback: fallback,
                                        stickiness: .stickyAfterFailure,
                                        diagnosticSink: sink))
    }

    func testStickyAfterOpenFailureSkipsPrimaryOnNextOpen() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeStickyBackends(sink: sink)
        primary.openFailure = .network("dead wifi")

        try await wrapper.open { _ in }
        wrapper.close()

        // Second open: primary should be skipped entirely
        primary.openFailure = nil
        try await wrapper.open { _ in }

        XCTAssertEqual(primary.calls, [.open],
                       "the primary was tried once and then skipped")
        XCTAssertEqual(fallback.calls, [.open, .close, .open],
                       "the fallback is used directly after primary failure")
        XCTAssertTrue(wrapper.isPrimaryStuckForTesting)
        XCTAssertTrue(sink.names.contains("primary.skipped_sticky"))
    }

    func testStickyAfterMidSessionFailureSkipsPrimaryOnNextOpen() async throws {
        let sink = RecordingSink()
        let (primary, fallback, wrapper) = makeStickyBackends(sink: sink)
        let events = EventLog()
        try await wrapper.open { events.append($0) }
        wrapper.beginUserTurn()

        // Mid-session failure
        primary.emit(.sessionFailed(.network("socket dropped")))
        await settle()

        wrapper.close()

        // Next open: primary should be skipped
        try await wrapper.open { _ in }

        // Primary was tried once (the first open), then the mid-session failure stuck it
        let primaryOpens = primary.calls.filter { $0 == .open }.count
        XCTAssertEqual(primaryOpens, 1)
        // Fallback opens: once from failover, once from the second wrapper.open
        let fallbackOpens = fallback.calls.filter { $0 == .open }.count
        XCTAssertEqual(fallbackOpens, 2,
                       "subsequent opens go straight to fallback")
        XCTAssertTrue(wrapper.isPrimaryStuckForTesting)
        XCTAssertTrue(sink.names.contains("primary.skipped_sticky"))
    }

    func testResetStickinessRestoresPrimaryFirst() async throws {
        let (primary, fallback, wrapper) = makeStickyBackends()
        primary.openFailure = .network("dead wifi")

        try await wrapper.open { _ in }
        wrapper.close()
        XCTAssertTrue(wrapper.isPrimaryStuckForTesting)

        wrapper.resetStickiness()
        XCTAssertFalse(wrapper.isPrimaryStuckForTesting)

        // The primary should be tried again
        primary.openFailure = nil
        try await wrapper.open { _ in }

        let primaryOpens = primary.calls.filter { $0 == .open }.count
        XCTAssertEqual(primaryOpens, 2, "resetStickiness restores primary-first behavior")
    }

    func testStickyBothFailStillSurfacesSessionFailed() async throws {
        let (primary, fallback, wrapper) = makeStickyBackends()
        primary.openFailure = .network("primary dead")

        try await wrapper.open { _ in }
        wrapper.close()

        // Now both fail
        fallback.openFailure = .authorization("speech unavailable")
        do {
            try await wrapper.open { _ in XCTFail("no session should be established") }
            XCTFail("both-fail must throw")
        } catch {
            XCTAssertEqual(error as? VoiceBackendFailure,
                           .authorization("speech unavailable"))
        }
    }

    func testRetryEachOpenStickinessNeverSticks() async throws {
        // The default stickiness should never stick
        let (primary, fallback, wrapper) = makeBackends()
        primary.openFailure = .network("dead wifi")

        try await wrapper.open { _ in }
        wrapper.close()

        // Second open: primary should be tried again (default behavior)
        primary.openFailure = nil
        try await wrapper.open { _ in }

        let primaryOpens = primary.calls.filter { $0 == .open }.count
        XCTAssertEqual(primaryOpens, 2,
                       "retryEachOpen always starts with the primary")
        XCTAssertEqual(fallback.calls.filter { $0 == .open }.count, 1,
                       "fallback was only needed once")
    }
}
