import Foundation
import TapQContracts

/// Two backends, one contract: the primary while it works, the fallback the moment it
/// does not.
///
/// This is TapQ's fail-open guarantee written as code. A cloud speech pipe can be down,
/// throttled, or unreachable on hotel wifi; when that happens the wearer must still be
/// able to answer an approval, so the session moves to the on-device stack rather than the
/// window going dead. The caller above never learns any of it happened — it holds one
/// `VoiceBackend` and keeps talking to it.
///
/// What is *not* replayed on failover is audio. Only session state moves: if a user turn
/// was open, a fresh one is opened on the fallback, and whatever the wearer said into the
/// dead socket is gone. Buffering audio to re-send would mean holding the wearer's speech
/// in memory against a failure that may never come, and the recovered turn is a fresh
/// listen window anyway — the wearer is still mid-sentence into a live microphone.
///
/// Failover happens exactly once per `open`. A fallback that fails too is reported as this
/// wrapper's own `sessionFailed`: there is nothing left to fall through to, and pretending
/// otherwise would hide a broken voice channel behind an endless reconnect.
@MainActor public final class FailThroughVoiceBackend: VoiceBackend {
    /// The conservative intersection of both backends.
    ///
    /// Capabilities are static for an instance's lifetime by contract, but which backend is
    /// active is not, so the only honest answer is what *both* can do. Advertising the
    /// primary's barge-in would strand a caller mid-failover holding a capability the
    /// fallback never had.
    public let capabilities: VoiceBackendCapabilities

    private let primary: any VoiceBackend
    private let fallback: any VoiceBackend
    private let diagnostics: TapQDiagnosticEmitter

    private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    private var active: (any VoiceBackend)?
    private var primaryOpen = false
    private var fallbackOpen = false
    /// True from the primary's failure until the fallback is open (or has failed too).
    /// Calls arriving in that gap have no backend to reach.
    private var failingOver = false
    /// Tracked here rather than read off a backend, because it is what gets replayed.
    private var turnActive = false
    private var generation: UInt64 = 0

    public init(primary: any VoiceBackend,
                fallback: any VoiceBackend,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.primary = primary
        self.fallback = fallback
        self.capabilities = VoiceBackendCapabilities(
            supportsBargeIn: primary.capabilities.supportsBargeIn
                && fallback.capabilities.supportsBargeIn,
            producesAudio: primary.capabilities.producesAudio
                && fallback.capabilities.producesAudio,
            duplex: primary.capabilities.duplex && fallback.capabilities.duplex)
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceFailThrough", sink: diagnosticSink)
    }

    var isUsingFallbackForTesting: Bool { fallbackOpen }

    // MARK: - Session lifecycle

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        guard active == nil, !failingOver else {
            throw VoiceBackendFailure.protocolViolation("the fail-through session is already open")
        }
        generation &+= 1
        let generation = self.generation
        self.onEvent = onEvent
        turnActive = false

        do {
            try await primary.open { [weak self] event in
                self?.handlePrimary(event, generation: generation)
            }
            guard self.generation == generation else {
                primary.close()
                throw VoiceBackendFailure.closed("the session was torn down while opening")
            }
            primaryOpen = true
            active = primary
            diagnostics.record("primary.opened")
            return
        } catch {
            guard self.generation == generation else { throw Self.failure(from: error) }
            diagnostics.record("primary.open_failed", level: .warning,
                               fields: ["detail": Self.describe(error)])
        }

        do {
            try await openFallback(generation: generation)
        } catch {
            teardown(expectedGeneration: generation)
            throw error
        }
    }

    public func close() {
        let wasOpen = active != nil || failingOver
        teardown()
        if wasOpen { diagnostics.record("session.closed") }
    }

    // MARK: - Turns

    public func beginUserTurn() {
        turnActive = true
        guard let active, !failingOver else {
            // Recorded, not dropped: the turn is replayed onto the fallback the moment it
            // is open, so the wearer's window survives the switch.
            diagnostics.record("turn.deferred", fields: ["reason": "failing_over"])
            return
        }
        active.beginUserTurn()
    }

    public func endUserTurn() {
        turnActive = false
        guard let active, !failingOver else {
            diagnostics.record("turn.dropped", fields: ["reason": "failing_over"])
            return
        }
        active.endUserTurn()
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        guard let active, !failingOver else {
            diagnostics.record("audio.dropped", fields: ["bytes": "\(chunk.data.count)"])
            return
        }
        active.sendAudio(chunk)
    }

    public func requestResponse(text: String) {
        guard let active, !failingOver else {
            diagnostics.record("response.dropped", fields: ["reason": "failing_over"])
            return
        }
        active.requestResponse(text: text)
    }

    public func cancelResponse() {
        guard let active, !failingOver else {
            diagnostics.record("cancel.dropped", fields: ["reason": "failing_over"])
            return
        }
        active.cancelResponse()
    }

    // MARK: - Event routing

    private func handlePrimary(_ event: VoiceBackendEvent, generation: UInt64) {
        guard self.generation == generation, !fallbackOpen, !failingOver else { return }
        guard case .sessionFailed(let failure) = event else {
            onEvent?(event)
            return
        }
        diagnostics.record("primary.session_failed", level: .warning,
                           fields: ["detail": failure.localizedDescription])
        primary.close()
        primaryOpen = false
        active = nil
        failingOver = true
        Task { @MainActor [weak self] in
            await self?.failOver(generation: generation)
        }
    }

    private func handleFallback(_ event: VoiceBackendEvent, generation: UInt64) {
        guard self.generation == generation else { return }
        guard case .sessionFailed = event else {
            onEvent?(event)
            return
        }
        // Nothing left underneath: the failure is the wrapper's own now.
        let callback = onEvent
        teardown(expectedGeneration: generation)
        callback?(event)
    }

    private func failOver(generation: UInt64) async {
        do {
            try await openFallback(generation: generation)
        } catch {
            guard self.generation == generation else { return }
            let callback = onEvent
            let failure = Self.failure(from: error)
            teardown(expectedGeneration: generation)
            callback?(.sessionFailed(failure))
            return
        }
        guard self.generation == generation else { return }
        failingOver = false
        guard turnActive else { return }
        active?.beginUserTurn()
        diagnostics.record("fallback.turn_resumed")
    }

    private func openFallback(generation: UInt64) async throws {
        do {
            try await fallback.open { [weak self] event in
                self?.handleFallback(event, generation: generation)
            }
        } catch {
            guard self.generation == generation else { throw Self.failure(from: error) }
            let failure = Self.failure(from: error)
            diagnostics.record("fallback.open_failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            throw failure
        }
        guard self.generation == generation else {
            fallback.close()
            throw VoiceBackendFailure.closed("the session was torn down while opening")
        }
        fallbackOpen = true
        failingOver = false
        active = fallback
        diagnostics.record("fallback.opened")
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        generation &+= 1
        onEvent = nil
        active = nil
        failingOver = false
        turnActive = false
        // Only what was actually opened is closed: a fallback that never ran must see no
        // traffic at all, which is the guarantee that a healthy primary costs nothing.
        if primaryOpen {
            primaryOpen = false
            primary.close()
        }
        if fallbackOpen {
            fallbackOpen = false
            fallback.close()
        }
    }

    private static func failure(from error: any Error) -> VoiceBackendFailure {
        (error as? VoiceBackendFailure) ?? .network(String(describing: error))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
