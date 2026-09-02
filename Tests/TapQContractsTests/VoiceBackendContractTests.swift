import XCTest
@testable import TapQContracts

final class VoiceBackendContractTests: XCTestCase {

    // MARK: - Legality matrix

    /// Every operation the turn protocol exposes, so the matrix below can be exhaustive
    /// by construction rather than by whoever wrote the test remembering all seven.
    private enum Operation: String, CaseIterable {
        case open
        case beginUserTurn
        case sendAudio
        case endUserTurn
        case requestResponse
        case cancelResponse
        case responseCompleted

        func apply(to machine: inout VoiceTurnStateMachine) throws {
            switch self {
            case .open: try machine.open()
            case .beginUserTurn: try machine.beginUserTurn()
            case .sendAudio: try machine.sendAudio()
            case .endUserTurn: try machine.endUserTurn()
            case .requestResponse: try machine.requestResponse()
            case .cancelResponse: try machine.cancelResponse()
            case .responseCompleted: try machine.responseCompleted()
            }
        }
    }

    private enum Outcome: Equatable {
        case allowed(VoiceTurnStateMachine.State)
        case rejected(VoiceTurnViolation)
    }

    /// The whole contract in one table. A transcript-only backend — the default shape,
    /// and the one the Apple adapter uses — so `cancelResponse` is illegal everywhere.
    private let transcriptOnlyMatrix: [VoiceTurnStateMachine.State: [Operation: Outcome]] = [
        .idle: [
            .open: .allowed(.open),
            .beginUserTurn: .rejected(.notOpen),
            .sendAudio: .rejected(.notOpen),
            .endUserTurn: .rejected(.notOpen),
            .requestResponse: .rejected(.notOpen),
            .cancelResponse: .rejected(.notOpen),
            .responseCompleted: .rejected(.notOpen),
        ],
        .open: [
            .open: .rejected(.alreadyOpen),
            .beginUserTurn: .allowed(.userTurn),
            .sendAudio: .rejected(.noUserTurn),
            .endUserTurn: .rejected(.noUserTurn),
            .requestResponse: .allowed(.responding),
            .cancelResponse: .rejected(.bargeInUnsupported),
            .responseCompleted: .rejected(.noResponseInFlight),
        ],
        .userTurn: [
            .open: .rejected(.alreadyOpen),
            .beginUserTurn: .rejected(.turnAlreadyInProgress),
            .sendAudio: .allowed(.userTurn),
            .endUserTurn: .allowed(.committed),
            .requestResponse: .rejected(.responseDuringUserTurn),
            .cancelResponse: .rejected(.bargeInUnsupported),
            .responseCompleted: .rejected(.noResponseInFlight),
        ],
        .committed: [
            .open: .rejected(.alreadyOpen),
            // Legal: a transcript-only backend runs turn after turn without ever
            // producing a response to complete.
            .beginUserTurn: .allowed(.userTurn),
            .sendAudio: .rejected(.noUserTurn),
            .endUserTurn: .rejected(.noUserTurn),
            .requestResponse: .allowed(.responding),
            .cancelResponse: .rejected(.bargeInUnsupported),
            .responseCompleted: .allowed(.open),
        ],
        .responding: [
            .open: .rejected(.alreadyOpen),
            .beginUserTurn: .rejected(.responseAlreadyInFlight),
            .sendAudio: .rejected(.noUserTurn),
            .endUserTurn: .rejected(.noUserTurn),
            .requestResponse: .rejected(.responseAlreadyInFlight),
            .cancelResponse: .rejected(.bargeInUnsupported),
            .responseCompleted: .allowed(.open),
        ],
    ]

    func testLegalityMatrixCoversEveryStateAndOperation() throws {
        // Guards the table itself: a new state or operation must be given a verdict here
        // rather than slipping through untested.
        XCTAssertEqual(transcriptOnlyMatrix.count, 5)
        for (state, row) in transcriptOnlyMatrix {
            XCTAssertEqual(row.count, Operation.allCases.count,
                           "state \(state.rawValue) is missing an operation verdict")
        }
    }

    func testTranscriptOnlyLegalityMatrix() throws {
        for (state, row) in transcriptOnlyMatrix {
            for (operation, expected) in row {
                var machine = try makeMachine(in: state)
                let label = "\(operation.rawValue) from \(state.rawValue)"
                switch expected {
                case .allowed(let next):
                    XCTAssertNoThrow(try operation.apply(to: &machine), label)
                    XCTAssertEqual(machine.state, next, label)
                case .rejected(let violation):
                    XCTAssertThrowsError(try operation.apply(to: &machine), label) { error in
                        XCTAssertEqual(error as? VoiceTurnViolation, violation, label)
                    }
                    // A rejected move must be inert: an adapter that reports the
                    // violation and carries on must still be in a state it can use.
                    XCTAssertEqual(machine.state, state, "\(label) mutated state")
                }
            }
        }
    }

    // MARK: - Named invariants (the ones worth failing loudly by name)

    func testSendAudioBeforeOpenIsRejected() {
        var machine = VoiceTurnStateMachine()
        XCTAssertThrowsError(try machine.sendAudio()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .notOpen)
        }
        XCTAssertFalse(machine.isOpen)
    }

    func testEndUserTurnBeforeBeginUserTurnIsRejected() throws {
        var machine = try makeMachine(in: .open)
        XCTAssertThrowsError(try machine.endUserTurn()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .noUserTurn)
        }
        XCTAssertEqual(machine.state, .open)
    }

    func testDoubleBeginUserTurnIsRejected() throws {
        var machine = try makeMachine(in: .userTurn)
        XCTAssertThrowsError(try machine.beginUserTurn()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .turnAlreadyInProgress)
        }
        XCTAssertTrue(machine.isUserTurnActive)
    }

    func testRequestResponseDuringUserTurnIsRejectedByHalfDuplexPolicy() throws {
        // Even a fully duplex-capable backend: half-duplex is TapQ policy, not a
        // transport limitation.
        var machine = try makeMachine(
            in: .userTurn,
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true))
        XCTAssertThrowsError(try machine.requestResponse()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .responseDuringUserTurn)
        }
        XCTAssertEqual(machine.state, .userTurn)
    }

    func testCancelResponseWithoutBargeInCapabilityIsRejectedEvenWhileResponding() throws {
        var machine = try makeMachine(in: .responding)
        XCTAssertFalse(machine.capabilities.supportsBargeIn)
        XCTAssertThrowsError(try machine.cancelResponse()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .bargeInUnsupported)
        }
        XCTAssertEqual(machine.state, .responding)
    }

    func testCancelResponseWithBargeInCapability() throws {
        let duplex = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true)
        var responding = try makeMachine(in: .responding, capabilities: duplex)
        XCTAssertNoThrow(try responding.cancelResponse())
        XCTAssertEqual(responding.state, .open)

        for state in [VoiceTurnStateMachine.State.open, .userTurn, .committed] {
            var machine = try makeMachine(in: state, capabilities: duplex)
            XCTAssertThrowsError(try machine.cancelResponse(), state.rawValue) { error in
                XCTAssertEqual(error as? VoiceTurnViolation, .noResponseInFlight, state.rawValue)
            }
            XCTAssertEqual(machine.state, state)
        }

        var idle = VoiceTurnStateMachine(capabilities: duplex)
        XCTAssertThrowsError(try idle.cancelResponse()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .notOpen)
        }
    }

    func testBackendCannotEndATurnNobodyOpened() throws {
        // The hole the design rule forbids: a backend VAD deciding the wearer stopped
        // talking. Routed through the machine it is a violation, not a resolved window.
        var machine = try makeMachine(in: .open)
        XCTAssertThrowsError(try machine.endUserTurn()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .noUserTurn)
        }
        // And it cannot complete a response nobody requested either.
        XCTAssertThrowsError(try machine.responseCompleted()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .noResponseInFlight)
        }
        XCTAssertEqual(machine.state, .open)
    }

    // MARK: - Happy paths

    func testTranscriptOnlyTurnCycleRepeats() throws {
        var machine = VoiceTurnStateMachine()
        try machine.open()
        for _ in 0..<3 {
            try machine.beginUserTurn()
            XCTAssertTrue(machine.isUserTurnActive)
            try machine.sendAudio()
            try machine.sendAudio()
            try machine.endUserTurn()
            XCTAssertEqual(machine.state, .committed)
            XCTAssertFalse(machine.isUserTurnActive)
            try machine.responseCompleted()
            XCTAssertEqual(machine.state, .open)
        }
    }

    func testSpeakingBackendTurnCycle() throws {
        let duplex = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true)
        var machine = VoiceTurnStateMachine(capabilities: duplex)
        try machine.open()
        try machine.beginUserTurn()
        try machine.sendAudio()
        try machine.endUserTurn()
        try machine.requestResponse()
        XCTAssertTrue(machine.isResponding)
        try machine.responseCompleted()
        XCTAssertEqual(machine.state, .open)
        XCTAssertFalse(machine.isResponding)
    }

    func testConsecutiveTurnsWithoutARequestedResponse() throws {
        // The transcript-only path never asks for a response, so `.committed` must lead
        // straight into the next turn.
        var machine = VoiceTurnStateMachine()
        try machine.open()
        try machine.beginUserTurn()
        try machine.endUserTurn()
        try machine.beginUserTurn()
        XCTAssertEqual(machine.state, .userTurn)
    }

    // MARK: - Teardown is always legal

    func testCloseIsLegalAndIdempotentFromEveryState() throws {
        for state in allStates {
            var machine = try makeMachine(in: state)
            machine.close()
            XCTAssertEqual(machine.state, .idle, state.rawValue)
            machine.close()
            XCTAssertEqual(machine.state, .idle, state.rawValue)
            XCTAssertFalse(machine.isOpen)
        }
    }

    func testSessionFailedIsLegalFromEveryStateAndSessionCanReopen() throws {
        for state in allStates {
            var machine = try makeMachine(in: state)
            machine.sessionFailed()
            XCTAssertEqual(machine.state, .idle, state.rawValue)
            XCTAssertNoThrow(try machine.open(), state.rawValue)
            XCTAssertEqual(machine.state, .open, state.rawValue)
        }
    }

    func testCapabilitiesSurviveTeardown() throws {
        let duplex = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true)
        var machine = try makeMachine(in: .responding, capabilities: duplex)
        machine.close()
        XCTAssertTrue(machine.capabilities.supportsBargeIn)
    }

    // MARK: - Capabilities

    func testCapabilityDefaultsAreTheLeastABackendCanBe() {
        let defaults = VoiceBackendCapabilities()
        XCTAssertFalse(defaults.supportsBargeIn)
        XCTAssertFalse(defaults.producesAudio)
        XCTAssertFalse(defaults.duplex)
        XCTAssertEqual(defaults, .transcriptOnly)
        XCTAssertEqual(VoiceTurnStateMachine().capabilities, .transcriptOnly)
    }

    func testCapabilitiesEquatable() {
        XCTAssertNotEqual(VoiceBackendCapabilities(supportsBargeIn: true), .transcriptOnly)
        XCTAssertNotEqual(VoiceBackendCapabilities(producesAudio: true), .transcriptOnly)
        XCTAssertNotEqual(VoiceBackendCapabilities(duplex: true), .transcriptOnly)
        XCTAssertEqual(VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true),
                       VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true))
    }

    // MARK: - Audio value types

    func testAudioFormatDefaultsToMonoPCM16() {
        let format = VoiceAudioFormat(sampleRate: 16_000)
        XCTAssertEqual(format.channels, 1)
        XCTAssertTrue(format.pcm16)
        XCTAssertEqual(format, .pcm16Mono16k)
        XCTAssertEqual(VoiceAudioFormat.pcm16Mono24k.sampleRate, 24_000)
        XCTAssertNotEqual(VoiceAudioFormat.pcm16Mono24k, .pcm16Mono16k)
    }

    func testChunkDurationMatchesPCM16FrameCount() {
        // 100 ms of mono 24 kHz PCM16 = 2400 frames = 4800 bytes.
        let chunk = VoiceAudioChunk(data: Data(count: 4_800), format: .pcm16Mono24k, timestamp: 1)
        XCTAssertEqual(try XCTUnwrap(chunk.durationSeconds), 0.1, accuracy: 1e-9)

        let stereo = VoiceAudioChunk(
            data: Data(count: 4_800),
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 2),
            timestamp: 1)
        XCTAssertEqual(try XCTUnwrap(stereo.durationSeconds), 0.05, accuracy: 1e-9)

        XCTAssertEqual(VoiceAudioChunk(data: Data(), format: .pcm16Mono24k, timestamp: 0).durationSeconds, 0)
    }

    func testChunkDurationIsUnknownForNonPCM16Bytes() {
        let opaque = VoiceAudioChunk(
            data: Data(count: 1_000),
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 1, pcm16: false),
            timestamp: 0)
        XCTAssertNil(opaque.durationSeconds)
    }

    func testChunkEquatableComparesBytesFormatAndTimestamp() {
        let base = VoiceAudioChunk(data: Data([1, 2, 3, 4]), format: .pcm16Mono24k, timestamp: 5)
        XCTAssertEqual(base, VoiceAudioChunk(data: Data([1, 2, 3, 4]), format: .pcm16Mono24k, timestamp: 5))
        XCTAssertNotEqual(base, VoiceAudioChunk(data: Data([1, 2, 3, 9]), format: .pcm16Mono24k, timestamp: 5))
        XCTAssertNotEqual(base, VoiceAudioChunk(data: Data([1, 2, 3, 4]), format: .pcm16Mono16k, timestamp: 5))
        XCTAssertNotEqual(base, VoiceAudioChunk(data: Data([1, 2, 3, 4]), format: .pcm16Mono24k, timestamp: 6))
    }

    // MARK: - Events and failures

    func testEventEquatableDistinguishesPartialFromFinal() {
        XCTAssertEqual(VoiceBackendEvent.transcriptPartial("yes"), .transcriptPartial("yes"))
        XCTAssertNotEqual(VoiceBackendEvent.transcriptPartial("yes"), .transcriptFinal("yes"))
        XCTAssertNotEqual(VoiceBackendEvent.transcriptPartial("yes"), .transcriptPartial("no"))
        XCTAssertEqual(VoiceBackendEvent.responseCompleted, .responseCompleted)
        XCTAssertNotEqual(VoiceBackendEvent.responseCompleted, .transcriptFinal(""))
    }

    func testEventEquatableReachesIntoAudioAndFailurePayloads() {
        let chunk = VoiceAudioChunk(data: Data([7]), format: .pcm16Mono24k, timestamp: 2)
        let other = VoiceAudioChunk(data: Data([8]), format: .pcm16Mono24k, timestamp: 2)
        XCTAssertEqual(VoiceBackendEvent.audio(chunk), .audio(chunk))
        XCTAssertNotEqual(VoiceBackendEvent.audio(chunk), .audio(other))
        XCTAssertEqual(VoiceBackendEvent.sessionFailed(.network("dropped")), .sessionFailed(.network("dropped")))
        XCTAssertNotEqual(VoiceBackendEvent.sessionFailed(.network("dropped")),
                          .sessionFailed(.closed("dropped")))
    }

    func testFailureEquatableSeparatesReasonAndDetail() {
        XCTAssertEqual(VoiceBackendFailure.authorization("401"), .authorization("401"))
        XCTAssertNotEqual(VoiceBackendFailure.authorization("401"), .authorization("403"))
        XCTAssertNotEqual(VoiceBackendFailure.network("timeout"), .protocolViolation("timeout"))
    }

    func testFailureDescriptionsAreHumanReadable() throws {
        let cases: [VoiceBackendFailure] = [
            .network("socket closed"),
            .protocolViolation("unexpected response.created"),
            .authorization("missing key"),
            .closed("peer hung up"),
        ]
        for failure in cases {
            let text = try XCTUnwrap(failure.errorDescription)
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.hasPrefix("Voice backend"), text)
        }
    }

    func testViolationDescriptionsAreHumanReadable() throws {
        let cases: [VoiceTurnViolation] = [
            .notOpen, .alreadyOpen, .turnAlreadyInProgress, .noUserTurn,
            .responseDuringUserTurn, .responseAlreadyInFlight, .noResponseInFlight,
            .bargeInUnsupported,
        ]
        for violation in cases {
            XCTAssertFalse(try XCTUnwrap(violation.errorDescription).isEmpty)
        }
        XCTAssertEqual(VoiceTurnViolation.notOpen, .notOpen)
        XCTAssertNotEqual(VoiceTurnViolation.notOpen, .alreadyOpen)
    }

    // MARK: - Helpers

    private var allStates: [VoiceTurnStateMachine.State] {
        [.idle, .open, .userTurn, .committed, .responding]
    }

    private func makeMachine(
        in state: VoiceTurnStateMachine.State,
        capabilities: VoiceBackendCapabilities = .transcriptOnly
    ) throws -> VoiceTurnStateMachine {
        var machine = VoiceTurnStateMachine(capabilities: capabilities)
        switch state {
        case .idle:
            break
        case .open:
            try machine.open()
        case .userTurn:
            try machine.open()
            try machine.beginUserTurn()
        case .committed:
            try machine.open()
            try machine.beginUserTurn()
            try machine.endUserTurn()
        case .responding:
            try machine.open()
            try machine.beginUserTurn()
            try machine.endUserTurn()
            try machine.requestResponse()
        }
        XCTAssertEqual(machine.state, state)
        return machine
    }
}

/// Proves the protocol is implementable as written — a contract nobody can conform to is
/// a contract that fails in WP7, not here — and that an adapter routing every call
/// through `VoiceTurnStateMachine` gets the turn discipline for free.
@MainActor
final class VoiceBackendConformanceTests: XCTestCase {

    /// The minimum honest adapter: a transcript-only pipe that checks every call against
    /// the state machine and reports violations the way a real adapter does.
    private final class ScriptedBackend: VoiceBackend {
        let capabilities: VoiceBackendCapabilities
        private var machine: VoiceTurnStateMachine
        private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?
        private(set) var violations: [VoiceTurnViolation] = []
        private(set) var sentBytes = 0
        private(set) var spoken: [String] = []

        init(capabilities: VoiceBackendCapabilities = .transcriptOnly) {
            self.capabilities = capabilities
            self.machine = VoiceTurnStateMachine(capabilities: capabilities)
        }

        var state: VoiceTurnStateMachine.State { machine.state }

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            do {
                try machine.open()
            } catch let violation as VoiceTurnViolation {
                throw VoiceBackendFailure.protocolViolation(violation.rawDetail)
            }
            self.onEvent = onEvent
        }

        func close() {
            machine.close()
            onEvent = nil
        }

        func beginUserTurn() { guarded { try machine.beginUserTurn() } }
        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            guarded { try machine.endUserTurn() }
            return false
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {
            guarded {
                try machine.sendAudio()
                sentBytes += chunk.data.count
            }
        }

        func requestResponse(text: String) {
            guarded {
                try machine.requestResponse()
                spoken.append(text)
            }
        }

        func cancelResponse() { guarded { try machine.cancelResponse() } }

        func setNativeTurnDetection(_ enabled: Bool) {
            machine.setNativeTurnDetection(enabled)
        }

        /// Test hook: the transport handing an event up, checked for legality the same
        /// way an inbound call is.
        func deliver(_ event: VoiceBackendEvent) {
            switch event {
            case .responseCompleted:
                guarded { try machine.responseCompleted() }
            case .userAudioCommittedByBackend:
                guarded { try machine.backendCommittedUserTurn() }
            case .sessionFailed:
                machine.sessionFailed()
            case .transcriptPartial, .transcriptFinal, .audio, .toolCall,
                    .spokenByBackend:
                // A tool call is an item inside a response TapQ already asked for, so it
                // moves no turn state: the response that carries it is still in flight and
                // settles on its own `responseCompleted`. So is the settled transcript of
                // what the backend just said — it is a report, and reports move nothing.
                break
            }
            onEvent?(event)
        }

        private func guarded(_ body: () throws -> Void) {
            do {
                try body()
            } catch let violation as VoiceTurnViolation {
                violations.append(violation)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testAdapterDrivesAFullTurnAndReportsTranscripts() async throws {
        let backend = ScriptedBackend()
        var received: [VoiceBackendEvent] = []
        try await backend.open { received.append($0) }

        backend.beginUserTurn()
        backend.sendAudio(VoiceAudioChunk(data: Data(count: 480), format: .pcm16Mono24k, timestamp: 0))
        backend.deliver(.transcriptPartial("ye"))
        backend.endUserTurn(expectingResponse: true)
        backend.deliver(.transcriptFinal("yes"))
        backend.deliver(.responseCompleted)

        XCTAssertEqual(received, [.transcriptPartial("ye"), .transcriptFinal("yes"), .responseCompleted])
        XCTAssertEqual(backend.sentBytes, 480)
        XCTAssertEqual(backend.state, .open)
        XCTAssertTrue(backend.violations.isEmpty)
    }

    func testAdapterRejectsAudioOutsideAUserTurn() async throws {
        let backend = ScriptedBackend()
        try await backend.open { _ in }
        backend.sendAudio(VoiceAudioChunk(data: Data(count: 96), format: .pcm16Mono24k, timestamp: 0))
        XCTAssertEqual(backend.violations, [.noUserTurn])
        XCTAssertEqual(backend.sentBytes, 0)
    }

    func testAdapterRefusesToSpeakOverAnOpenUserTurn() async throws {
        let backend = ScriptedBackend(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true, duplex: true))
        try await backend.open { _ in }
        backend.beginUserTurn()
        backend.requestResponse(text: "Approving.")
        XCTAssertEqual(backend.violations, [.responseDuringUserTurn])
        XCTAssertTrue(backend.spoken.isEmpty)

        backend.endUserTurn(expectingResponse: true)
        backend.requestResponse(text: "Approving.")
        XCTAssertEqual(backend.spoken, ["Approving."])
        XCTAssertEqual(backend.state, .responding)
    }

    func testSecondOpenThrowsTypedFailure() async throws {
        let backend = ScriptedBackend()
        try await backend.open { _ in }
        do {
            try await backend.open { _ in }
            XCTFail("expected the second open to throw")
        } catch let failure as VoiceBackendFailure {
            XCTAssertEqual(failure, .protocolViolation("alreadyOpen"))
        }
    }

    func testSessionFailureClosesTheSessionAndAllowsAFreshOne() async throws {
        let backend = ScriptedBackend()
        var received: [VoiceBackendEvent] = []
        try await backend.open { received.append($0) }
        backend.beginUserTurn()
        backend.deliver(.sessionFailed(.network("socket closed")))
        XCTAssertEqual(backend.state, .idle)
        XCTAssertEqual(received, [.sessionFailed(.network("socket closed"))])

        try await backend.open { _ in }
        backend.beginUserTurn()
        XCTAssertEqual(backend.state, .userTurn)
        XCTAssertTrue(backend.violations.isEmpty)
    }

    func testCloseIsSafeFromAnyStateAndRepeatable() async throws {
        let backend = ScriptedBackend()
        backend.close()
        try await backend.open { _ in }
        backend.beginUserTurn()
        backend.close()
        backend.close()
        XCTAssertEqual(backend.state, .idle)
    }
}

private extension VoiceTurnViolation {
    /// Stable short token for the detail string an adapter attaches to a
    /// `protocolViolation`, so tests can assert on it without matching prose.
    var rawDetail: String {
        switch self {
        case .notOpen: return "notOpen"
        case .alreadyOpen: return "alreadyOpen"
        case .turnAlreadyInProgress: return "turnAlreadyInProgress"
        case .noUserTurn: return "noUserTurn"
        case .responseDuringUserTurn: return "responseDuringUserTurn"
        case .responseAlreadyInFlight: return "responseAlreadyInFlight"
        case .noResponseInFlight: return "noResponseInFlight"
        case .bargeInUnsupported: return "bargeInUnsupported"
        case .unsolicitedBackendCommit: return "unsolicitedBackendCommit"
        }
    }
}

/// The carve-out on `VoiceBackend`, as legality rules.
///
/// The whole feature rests on one asymmetry: a commit the backend made on its own is a
/// legal report when TapQ asked for it and a session-ending violation when it did not. These
/// tests own that asymmetry, and the second-order property it depends on — that a legal
/// native commit does **not** end TapQ's turn.
final class VoiceTurnNativeDetectionTests: XCTestCase {

    private func openTurn(native: Bool) -> VoiceTurnStateMachine {
        var machine = VoiceTurnStateMachine()
        try! machine.open()
        machine.setNativeTurnDetection(native)
        try! machine.beginUserTurn()
        return machine
    }

    func testABackendCommitIsAViolationWhileTapQOwnsTurns() {
        var machine = openTurn(native: false)
        XCTAssertThrowsError(try machine.backendCommittedUserTurn()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .unsolicitedBackendCommit)
        }
        XCTAssertEqual(machine.state, .userTurn, "a rejected commit changes nothing")
    }

    /// The load-bearing half: a native commit ends the *utterance*, not the turn.
    ///
    /// If it moved the machine to `.committed`, the very next microphone buffer would be an
    /// illegal `sendAudio` and the session would die under a wearer who did nothing but keep
    /// talking. So the assertion is on both facts together — the commit is legal, and audio
    /// after it still is.
    func testALegalNativeCommitKeepsTheUserTurnOpen() throws {
        var machine = openTurn(native: true)
        XCTAssertTrue(try machine.backendCommittedUserTurn())
        XCTAssertEqual(machine.state, .userTurn)
        XCTAssertNoThrow(try machine.sendAudio())
        XCTAssertTrue(try machine.backendCommittedUserTurn(),
                      "a second utterance in the same turn is committed the same way")
    }

    /// The service's VAD runs on the audio stream, not on TapQ's window boundaries, so a
    /// commit can land outside a turn. Tolerated and reported as nothing — there is no
    /// window it could resolve.
    func testANativeCommitOutsideAUserTurnIsToleratedAndReportsNothing() throws {
        var machine = VoiceTurnStateMachine()
        try machine.open()
        machine.setNativeTurnDetection(true)
        XCTAssertFalse(try machine.backendCommittedUserTurn())
        XCTAssertEqual(machine.state, .open)
    }

    func testANativeCommitOnAClosedSessionIsNotOpenWhateverTheMode() {
        var machine = VoiceTurnStateMachine()
        machine.setNativeTurnDetection(true)
        XCTAssertThrowsError(try machine.backendCommittedUserTurn()) { error in
            XCTAssertEqual(error as? VoiceTurnViolation, .notOpen)
        }
    }

    /// Teardown forgets the mode, so a reconnected session is manual until its adapter asks
    /// again. Anything else would let a socket drop silently hand turn arbitration away.
    func testTeardownResetsTheModeSoAReopenedSessionIsManual() throws {
        let teardowns: [(inout VoiceTurnStateMachine) -> Void] = [
            { $0.close() },
            { $0.sessionFailed() },
        ]
        for teardown in teardowns {
            var machine = VoiceTurnStateMachine()
            try machine.open()
            machine.setNativeTurnDetection(true)
            XCTAssertTrue(machine.nativeTurnDetectionEnabled)
            teardown(&machine)
            XCTAssertFalse(machine.nativeTurnDetectionEnabled)

            try machine.open()
            try machine.beginUserTurn()
            XCTAssertThrowsError(try machine.backendCommittedUserTurn())
        }
    }

    func testTheCapabilityIsOffByDefaultAndIsNotTheSameAsTheMode() throws {
        XCTAssertFalse(VoiceBackendCapabilities.transcriptOnly.supportsNativeTurnDetection)
        XCTAssertFalse(VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                duplex: true).supportsNativeTurnDetection)
        // Declaring the capability does not turn the mode on: a fresh session is manual.
        var machine = VoiceTurnStateMachine(
            capabilities: VoiceBackendCapabilities(supportsNativeTurnDetection: true))
        try machine.open()
        XCTAssertFalse(machine.nativeTurnDetectionEnabled)
        try machine.beginUserTurn()
        XCTAssertThrowsError(try machine.backendCommittedUserTurn())
    }
}
