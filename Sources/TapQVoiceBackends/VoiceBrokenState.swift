import Foundation
import TapQContracts

/// The terminal state a specified backend's failure leaves a run in — worn as a
/// `VoiceBackend` so that "no reopen, ever" is structural rather than remembered.
///
/// ## The rule
///
/// **A specified backend never degrades into a different backend.** When the operator asks
/// for `--voice-backend openai-realtime`, that backend is the whole of the voice pipe. If it
/// fails — at open, mid-run, at any severity — hands-free voice breaks completely for the
/// run: loud diagnostics, one locally spoken notice, every held turn boundary released, and
/// a dead voice channel until the runtime is restarted.
///
/// The reason is not squeamishness about degraded modes; TapQ has several and keeps them.
/// It is that a *cross-backend* degrade lies about what the wearer is talking to. The Apple
/// pipe has different capabilities — no free-form, no grounded answers, different
/// endpointing — so swapping it in mid-run silently changes the contract the wearer thinks
/// they are speaking under, and changes what a test run was measuring halfway through it.
/// This is the playback decision ("terminate loudly, never silently fall back") applied to
/// the whole backend boundary rather than to one seam of it.
///
/// ## What is still true after the break
///
/// Everything that was never the backend's. Windows still open, and resolve by gesture, tap,
/// or timeout exactly as they do under `--no-voice`; approvals still fail open to the agent's
/// on-screen prompt; the broker, the wire, and the instruction channel are untouched. What is
/// gone is the microphone: a window opened after the break is refused a session before any
/// traffic reaches the pipe, so it listens to nothing and waits for the channels that remain.
///
/// ## Why the latch is also the backend
///
/// A separate flag would have to be consulted by every caller that might reopen the pipe, and
/// the one that forgot would be the one that reopened it. Wrapping the specified backend
/// instead means the refusal happens at the only door there is.
@MainActor public final class VoiceBrokenState: VoiceBackend {
    /// The one sentence the wearer hears when the pipe dies.
    ///
    /// Spoken through the *local* synthesizer, which is not a backend — the Apple **backend**
    /// is the recognizer, and nothing about announcing a break locally re-opens a speech pipe.
    /// It is the same engine every non-voice announcement already uses, and it is how a wearer
    /// with no screen learns that the microphone stopped listening to them.
    public static let spokenNotice = "Hands-free voice is off. The voice backend failed."

    /// Forwarded verbatim. Capabilities describe the pipe the operator asked for, and the
    /// answer must not change when it dies: a caller that re-read them after the break and
    /// found a different backend's shape is the exact confusion this type exists to prevent.
    public var capabilities: VoiceBackendCapabilities { inner.capabilities }

    /// Forwarded verbatim while the pipe is alive, and `nil` once it is dead — after the
    /// break nothing is being produced, so there is no response to name.
    public var activeResponseIdentity: String? { isBroken ? nil : inner.activeResponseIdentity }

    /// Whether the run's voice channel is terminally down. Never returns to `false`.
    public private(set) var isBroken = false

    /// Says one sentence through the run's local text-to-speech output.
    ///
    /// A closure rather than a dependency because this target is portable and the synthesizer
    /// is not. `nil` — every test and every composition that has no voice of its own — logs
    /// the break and says nothing, which is the honest behavior for a host with no speaker.
    public var speakNotice: (@MainActor (String) -> Void)?

    /// Releases every turn boundary this run is holding open.
    ///
    /// A voice session's whole premise is that TapQ is about to listen. With the microphone
    /// terminally gone, a parked Stop hook would wait out its full budget for a window that
    /// can no longer hear anything, so the boundaries are let go the moment the break lands
    /// rather than at the next timeout. `nil` without `--voice-session`: nothing is held.
    public var releaseHolds: (@MainActor () -> Void)?

    private let inner: any VoiceBackend
    private let provider: VoiceBackendProvider
    private let diagnostics: TapQDiagnosticEmitter

    private var callerOnEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    /// Guards the relay: events from the inner backend are valid only while the session
    /// identity matches, exactly as in the microphone pump and the playback wrapper.
    private var sessionGeneration: UInt64 = 0

    public init(inner: any VoiceBackend,
                provider: VoiceBackendProvider,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.inner = inner
        self.provider = provider
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
    }

    // MARK: - Breaking

    /// Latches the break, once, and drives everything that follows from it.
    ///
    /// - Parameter reason: why the pipe died, for the log only. Causes and codes, never
    ///   anything the wearer or the backend said.
    ///
    /// Idempotent by construction: a second failure of an already-dead pipe is the same
    /// break, and re-speaking the notice or re-releasing the boundaries would say so twice.
    public func noteBackendFailed(reason: String) {
        guard !isBroken else { return }
        isBroken = true
        // Cause then consequence, both at error level and named separately so a log reader
        // never has to infer the second from the first. This is not a degraded response; it
        // is the end of the channel the operator asked for.
        diagnostics.record("voice.pipeline_failed", level: .error,
                           fields: ["backend": provider.rawValue, "reason": reason])
        diagnostics.record("voice.disabled_for_run", level: .error)
        speakNotice?(Self.spokenNotice)
        releaseHolds?()
    }

    // MARK: - VoiceBackend

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        guard !isBroken else {
            // Warning rather than error, deliberately. The break was reported once, loudly,
            // by the pair above; every later window that asks for a microphone is a
            // consequence of a failure already on the record, and an error line per window
            // would bury the one that explained it.
            diagnostics.record("open.refused", level: .warning,
                               fields: ["reason": "voice_disabled_for_run"])
            throw VoiceBackendFailure.closed("hands-free voice is disabled for this run")
        }
        sessionGeneration &+= 1
        let sessGen = sessionGeneration
        callerOnEvent = onEvent
        do {
            try await inner.open { [weak self] event in
                self?.relay(event, sessionGeneration: sessGen)
            }
        } catch {
            // Nothing is open; leave no callback behind for a late inner event to reach.
            if sessionGeneration == sessGen { callerOnEvent = nil }
            // An open that failed after startup is a failure of the specified backend like
            // any other. A configuration mistake never reaches here — it is refused before
            // the first window, by the factory.
            noteBackendFailed(reason: Self.describe(error))
            throw error
        }
    }

    public func close() {
        sessionGeneration &+= 1
        callerOnEvent = nil
        inner.close()
    }

    public func beginUserTurn() {
        guard !isBroken else { return }
        inner.beginUserTurn()
    }

    @discardableResult
    public func endUserTurn(expectingResponse: Bool) -> Bool {
        guard !isBroken else { return false }
        return inner.endUserTurn(expectingResponse: expectingResponse)
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        guard !isBroken else { return }
        inner.sendAudio(chunk)
    }

    public func requestResponse(text: String) {
        guard !isBroken else { return }
        inner.requestResponse(text: text)
    }

    /// Forwarded until the break, and silent after it — the same refusal every other call
    /// gets. Explicit rather than inherited from the protocol's default, which would route
    /// a scripted sentence through `requestResponse` and lose the inner adapter's verbatim
    /// channel.
    ///
    /// Silence here is not a lost sentence: the caller learns the pipe is dead from the
    /// `sessionFailed` that latched the break, and the one thing the wearer is owed
    /// afterwards — the notice that hands-free voice is off — is spoken locally by
    /// `noteBackendFailed`, which is the sole utterance in the run that may be.
    public func requestScriptedSpeech(text: String) {
        guard !isBroken else { return }
        inner.requestScriptedSpeech(text: text)
    }

    public func cancelResponse() {
        guard !isBroken else { return }
        inner.cancelResponse()
    }

    /// Forwarded until the break, and inert after it. Which endpointer owns a turn is a
    /// question about a session, and after the break there will never be another one.
    public func setNativeTurnDetection(_ enabled: Bool) {
        guard !isBroken else { return }
        inner.setNativeTurnDetection(enabled)
    }

    /// Forwarded until the break, inert after it, and explicit rather than inherited for the
    /// reason `requestScriptedSpeech` is: the protocol's defaults are no-ops, and a latch
    /// that inherited them would leave a *healthy* pipe with no tools declared and no
    /// grounding — the wearer heard, the model mute on what to do about it.
    ///
    /// After the break there is nothing to declare to, nothing to ground, and no call
    /// outstanding: a session that could have produced one no longer exists.
    public func declareTools(_ tools: [VoiceToolDeclaration]) {
        guard !isBroken else { return }
        inner.declareTools(tools)
    }

    public func updateInstructions(_ instructions: String) {
        guard !isBroken else { return }
        inner.updateInstructions(instructions)
    }

    public func sendToolResult(callID: String, output: String) {
        guard !isBroken else { return }
        inner.sendToolResult(callID: callID, output: output)
    }

    /// Forwarded until the break, and refused after it: there is no session left to take a
    /// turn on, and reporting `false` is what stops a caller waiting for a response that can
    /// never arrive.
    @discardableResult
    public func requestModelTurn() -> Bool {
        guard !isBroken else { return false }
        return inner.requestModelTurn()
    }

    // MARK: - Event relay

    private func relay(_ event: VoiceBackendEvent, sessionGeneration sessGen: UInt64) {
        guard self.sessionGeneration == sessGen else { return }
        guard case .sessionFailed(let failure) = event else {
            callerOnEvent?(event)
            return
        }
        // Retire the session identity before anything else, so nothing arriving afterwards —
        // a late inner event, a playback report racing the same teardown — relays a second
        // failure for a session that is already gone.
        let callback = callerOnEvent
        sessionGeneration &+= 1
        callerOnEvent = nil
        // Broken before the caller hears about it: the caller's own reaction is to tear its
        // window down, which closes this wrapper, and that close must find a pipe already
        // known dead rather than one it could be talked into reopening.
        noteBackendFailed(reason: Self.describe(failure))
        callback?(event)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
