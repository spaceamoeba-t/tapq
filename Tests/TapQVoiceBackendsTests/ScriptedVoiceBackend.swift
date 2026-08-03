import XCTest
import Foundation
import TapQContracts

/// A `VoiceBackend` that records its call sequence and replays scripted events.
///
/// Like the realtime fake, it polices the turn protocol from the backend's side — a turn
/// call on a closed session, a double begin, or an end with nothing open fails the test
/// where it happens rather than somewhere downstream. It never ends a turn on its own.
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
    let name: String
    private(set) var calls: [Call] = []
    private(set) var handlers: [(@MainActor (VoiceBackendEvent) -> Void)] = []
    private(set) var isOpen = false
    private(set) var isTurnActive = false
    /// Set to make `open` throw; cleared to let a retry succeed.
    var openFailure: VoiceBackendFailure?
    /// When set, `open` suspends on it.
    var openGate: (@MainActor () async -> Void)?

    init(name: String = "backend",
         capabilities: VoiceBackendCapabilities = .transcriptOnly) {
        self.name = name
        self.capabilities = capabilities
    }

    func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        calls.append(.open)
        if let openGate { await openGate() }
        if let openFailure { throw openFailure }
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
        XCTAssertTrue(isOpen, "\(name): beginUserTurn on a closed session")
        XCTAssertFalse(isTurnActive, "\(name): double beginUserTurn")
        isTurnActive = true
    }

    func endUserTurn() {
        calls.append(.endUserTurn)
        XCTAssertTrue(isOpen, "\(name): endUserTurn on a closed session")
        XCTAssertTrue(isTurnActive, "\(name): endUserTurn with no turn open")
        isTurnActive = false
    }

    func sendAudio(_ chunk: VoiceAudioChunk) {
        calls.append(.sendAudio(chunk.data.count))
        XCTAssertTrue(isTurnActive, "\(name): audio outside a turn")
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
        guard !handlers.isEmpty else { return XCTFail("\(name): no window is listening") }
        handlers[index ?? handlers.count - 1](event)
    }
}
