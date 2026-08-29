import Foundation
import TapQContracts

/// A `VoiceBackend` wrapper that ends the session when nothing can play what the session
/// says back.
///
/// The gap this fills: a backend whose `capabilities.producesAudio` is true has no voice of
/// its own on this machine — it emits `.audio` events and something else renders them. When
/// that renderer cannot start (a `-10868` output bus, an occupied device) or dies mid-run,
/// nothing about the session looks broken. The microphone keeps pumping, transcripts keep
/// arriving, commands keep matching — and every sentence routed to the backend's voice is
/// silently inaudible, including the one that says the session ended. A wearer with no
/// screen has no way to learn any of that happened.
///
/// So the failure is not absorbed. `notePlaybackUnavailable` ends the session the same way
/// `MicrophonePumpVoiceBackend` ends one on a dead microphone: close the inner backend and
/// relay `.sessionFailed` through this wrapper's own event path. Above it sits
/// `VoiceBrokenState`, for which that event means what every other failure of the specified
/// backend means — hands-free voice breaks completely for the run, loudly and once. A dead
/// output does not get a second backend any more than a dead socket does.
///
/// What it deliberately does **not** do is re-speak the sentence that was lost. A quiet
/// fallback to the local synthesizer for one utterance would restore the audio and hide the
/// state change, which is the half-alive run this exists to prevent.
///
/// ## Run-lifetime, not per-session
///
/// A machine that cannot play 24 kHz audio now will not be able to a minute from now, so the
/// verdict sticks for the life of the instance: a later `open` is refused before any traffic
/// reaches the inner backend. Under the break policy the wrapper above refuses first and
/// this guard is never reached in the shipping composition — it is kept because the
/// invariant is this wrapper's own, and a composition that omitted the latch must still not
/// hand back a session nobody can hear. It mirrors the `never_streamed` motion downgrade:
/// one confirmed absence, one run-lifetime consequence, no re-probing a capability that
/// failed for structural reasons.
///
/// ## What counts as unavailable
///
/// The host decides, and it is deliberately narrow: only a renderer that has given up on
/// audio it was handed. A route change that costs the remainder of one response is not this
/// — the renderer starts a fresh engine for the next response, and if *that* cannot start,
/// the host reports it here and the session ends then.
@MainActor public final class PlaybackDependentVoiceBackend: VoiceBackend {
    public var capabilities: VoiceBackendCapabilities { inner.capabilities }

    /// Forwarded rather than defaulted, for the reason the requirement gives: a wrapper that
    /// took the `nil` default would report a naming peer as an anonymous one.
    public var activeResponseIdentity: String? { inner.activeResponseIdentity }

    private let inner: any VoiceBackend
    private let diagnostics: TapQDiagnosticEmitter

    private var callerOnEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    /// Guards the relay: events from the inner backend are valid only while the session
    /// identity matches, exactly as in the microphone pump.
    private var sessionGeneration: UInt64 = 0
    /// Set once, never cleared. See "Run-lifetime" above.
    private var playbackUnavailable = false

    public init(inner: any VoiceBackend,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.inner = inner
        self.diagnostics = TapQDiagnosticEmitter(category: "VoicePlayback", sink: diagnosticSink)
    }

    var isPlaybackUnavailableForTesting: Bool { playbackUnavailable }

    // MARK: - The one call the host makes

    /// Reports that response audio can no longer be rendered, and ends the session on it.
    ///
    /// - Parameter detail: why the renderer gave up, for the log only. Counts and causes,
    ///   never anything the wearer or the backend said.
    ///
    /// Idempotent: the second report of the same dead output is not a second termination.
    public func notePlaybackUnavailable(detail: String) {
        if !playbackUnavailable {
            playbackUnavailable = true
            // The cause. Error level rather than warning: this is not a degraded response,
            // it is the end of the pipe the operator asked for.
            diagnostics.record("playback.unavailable", level: .error,
                               fields: ["detail": detail,
                                        "consequence": "voice_disabled_for_run"])
        }
        guard callerOnEvent != nil else { return }
        // The consequence, named separately so a log reader never has to infer it.
        diagnostics.record("session.terminated", level: .error,
                           fields: ["reason": "playback_unavailable"])
        endSession(.network("response audio playback is unavailable"))
    }

    // MARK: - VoiceBackend forwarding

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        guard !playbackUnavailable else {
            // Refused before a socket is opened or a microphone is touched: a session whose
            // answers nobody can hear is not worth the traffic. The caller records its own
            // open failure; under the break policy the run's voice is already down.
            diagnostics.record("open.refused", level: .error,
                               fields: ["reason": "playback_unavailable"])
            throw VoiceBackendFailure.network("response audio playback is unavailable")
        }
        sessionGeneration &+= 1
        let sessGen = sessionGeneration
        callerOnEvent = onEvent
        do {
            try await inner.open { [weak self] event in
                self?.relayEvent(event, sessionGeneration: sessGen)
            }
        } catch {
            // Nothing is open; leave no callback behind for a late inner event to reach.
            if sessionGeneration == sessGen { callerOnEvent = nil }
            throw error
        }
        // Playback can die during the await. Refusing to hand back a session that is
        // already known-mute costs one close and saves a silent window.
        guard sessionGeneration == sessGen, !playbackUnavailable else {
            inner.close()
            throw VoiceBackendFailure.network("response audio playback is unavailable")
        }
    }

    public func close() {
        sessionGeneration &+= 1
        callerOnEvent = nil
        inner.close()
    }

    public func beginUserTurn() {
        inner.beginUserTurn()
    }

    @discardableResult
    public func endUserTurn(expectingResponse: Bool) -> Bool {
        inner.endUserTurn(expectingResponse: expectingResponse)
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        inner.sendAudio(chunk)
    }

    public func requestResponse(text: String) {
        inner.requestResponse(text: text)
    }

    /// Forwarded explicitly rather than left to the protocol's default, which would send a
    /// scripted sentence down `requestResponse` and lose the inner adapter's verbatim
    /// channel. An output device has no opinion about the wording either way.
    public func requestScriptedSpeech(text: String) {
        inner.requestScriptedSpeech(text: text)
    }

    public func cancelResponse() {
        inner.cancelResponse()
    }

    /// Forwarded verbatim: where a sentence ended is the inner pipe's business, and an
    /// output device has no opinion about it.
    public func setNativeTurnDetection(_ enabled: Bool) {
        inner.setNativeTurnDetection(enabled)
    }

    /// The three tool-path calls, forwarded for the reason `requestScriptedSpeech` is
    /// forwarded: the protocol's defaults are no-ops, and inheriting them would silently
    /// disarm intent on a session the composition above believes is tool-driven. Whether the
    /// speaker works has nothing to do with any of them.
    public func declareTools(_ tools: [VoiceToolDeclaration]) {
        inner.declareTools(tools)
    }

    public func updateInstructions(_ instructions: String) {
        inner.updateInstructions(instructions)
    }

    public func sendToolResult(callID: String, output: String) {
        inner.sendToolResult(callID: callID, output: output)
    }

    @discardableResult
    public func requestModelTurn() -> Bool {
        inner.requestModelTurn()
    }

    // MARK: - Event relay

    private func relayEvent(_ event: VoiceBackendEvent, sessionGeneration sessGen: UInt64) {
        guard self.sessionGeneration == sessGen else { return }
        guard case .sessionFailed = event else {
            callerOnEvent?(event)
            return
        }
        // The inner backend died on its own. Retire the session identity so nothing that
        // arrives afterwards — including a playback report racing the same teardown —
        // relays a second failure for the same session.
        let callback = callerOnEvent
        sessionGeneration &+= 1
        callerOnEvent = nil
        callback?(event)
    }

    /// Closes the inner backend and reports the failure upward, in that order: the caller
    /// acts the moment it sees the event, and it must not tear a run's voice down around a
    /// pipe that is still holding a microphone.
    private func endSession(_ failure: VoiceBackendFailure) {
        let callback = callerOnEvent
        inner.close()
        sessionGeneration &+= 1
        callerOnEvent = nil
        callback?(.sessionFailed(failure))
    }
}
