import Foundation
import TapQContracts

/// Whether a backend session spans a single window or a whole conversation.
///
/// `.perWindow` — the M1 default: every `start()`/`stop()` cycle opens and closes the
/// backend session. Existing behavior, byte-identical.
///
/// `.conversation(idleClose:)` — the session is opened on the first `start()` and
/// outlives individual windows. Turns are per-window; the session is per-conversation.
/// After a window closes, an idle timer starts; if no new `start()` arrives before the
/// timer expires and no window is open, the session is closed. A subsequent `start()` after
/// idle-close reopens from scratch.
public enum SessionPolicy: Sendable, Equatable {
    case perWindow
    case conversation(idleClose: TimeInterval)
}

/// Presents any `VoiceBackend` as the `VoiceCommandProviding` the arbiter already consumes,
/// so swapping the speech pipe underneath TapQ never reaches the interaction layer.
///
/// The window shape is the one `VoiceListener` established and every composition above
/// depends on: one `start` opens a session and exactly one user turn, the first matched
/// transcript resolves the window and tears it down, and `stop` closes everything. Turns
/// are opened only inside `start`, which is what keeps the microphone from being live
/// between windows no matter which backend is plugged in.
///
/// In conversation mode (`SessionPolicy.conversation`), `start` opens a new turn on the
/// existing session rather than opening a new session each time. The session stays open
/// across windows so WebSocket reconnect churn is eliminated. The backend session is closed
/// either by `shutdown()` or by the idle timer when no window is open.
///
/// Every degraded path fails open in the same direction as the rest of the voice channel:
/// a session that cannot be opened, or one that dies mid-window, delivers nothing and
/// stays quiet. The window still resolves by gesture, tap, or timeout — a voice backend
/// must never be able to make a window hang.
@MainActor public final class VoiceBackendCommandProvider: VoiceCommandProviding {
    /// The keyword grammar, injected rather than defaulted.
    ///
    /// `VoiceCommandMatcher` lives in `TapQDetectionBaseline`, and this module deliberately
    /// depends on nothing but `TapQContracts`; composition passes `VoiceCommandMatcher.match`.
    public typealias TranscriptMatching = @MainActor (String) -> VoiceCommand?

    private let backend: any VoiceBackend
    private let match: TranscriptMatching
    private let diagnostics: TapQDiagnosticEmitter
    private let sessionPolicy: SessionPolicy
    private let supportsBargeIn: Bool
    private let monotonicNow: @MainActor () -> TimeInterval
    private let responseAudio: (any VoiceResponseAudioPlaying)?
    private let freeformEnabled: Bool
    private let idleSleep: @MainActor (TimeInterval) async -> Void

    private var handler: (@MainActor (VoiceCommand) -> Void)?
    private var sessionOpen = false
    private var turnActive = false

    /// In `.perWindow` mode this serves as both session and window identity. In
    /// `.conversation` mode only `sessionGeneration` guards backend events; this counter
    /// is bumped on each window cycle but is not used in the event handler.
    private var windowGeneration: UInt64 = 0
    /// Guards backend events in `.conversation` mode. Bumped only when the session is
    /// opened or torn down, so events from the live session are never dropped between
    /// windows.
    private var sessionGeneration: UInt64 = 0

    // -- Conversation mode state --
    /// Generation counter for the idle-close task.
    private var idleGeneration: UInt64 = 0
    /// True when `shutdown()` has been called. Prevents further opens.
    private var isShutDown = false
    /// When true, the next `responseCompleted` event should begin a deferred user turn.
    private var pendingUserTurn = false
    /// True after an idle-close: the next `openWindow` fires `onConversationReopened`.
    private var sessionIdleClosed = false
    /// Whether a freeform command has been delivered in the current turn.
    /// Prevents multiple freeform deliveries per turn (one-shot per turn).
    private var freeformDeliveredThisTurn = false
    /// True while the window is paused by `pauseListening()` (activity-driven mic close).
    /// Audio routing continues so response playback is not interrupted; transcripts and
    /// command delivery are suspended. Cleared by the next `start()`.
    private var windowPaused = false

    /// Observer fired after match evaluation for every final transcript in the current turn.
    /// The callback receives the transcript text and whether it matched a command.
    /// Needed by WP8 (free-form answers); inert until assigned.
    public var onTranscriptFinal: ((@MainActor (String, _ matched: Bool) -> Void))?

    /// Observer fired when the session reopens after an idle-close. The host uses this to
    /// call `FailThroughVoiceBackend.resetStickiness()` so the primary is re-probed on a
    /// new conversation (decision 3).
    public var onConversationReopened: (@MainActor () -> Void)?

    public init(backend: any VoiceBackend,
                match: @escaping TranscriptMatching,
                sessionPolicy: SessionPolicy = .perWindow,
                supportsBargeIn: Bool = false,
                responseAudio: (any VoiceResponseAudioPlaying)? = nil,
                freeformEnabled: Bool = false,
                monotonicNow: @escaping @MainActor () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                idleSleep: @escaping @MainActor (TimeInterval) async -> Void = {
                    try? await Task.sleep(for: .seconds($0))
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.backend = backend
        self.match = match
        self.sessionPolicy = sessionPolicy
        self.supportsBargeIn = supportsBargeIn
        self.responseAudio = responseAudio
        self.freeformEnabled = freeformEnabled
        self.monotonicNow = monotonicNow
        self.idleSleep = idleSleep
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceBackend", sink: diagnosticSink)
    }

    var isWindowOpenForTesting: Bool { handler != nil }
    var isSessionOpenForTesting: Bool { sessionOpen }

    // MARK: - VoiceCommandProviding

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        guard handler == nil else {
            diagnostics.record("start.skipped", fields: ["reason": "already_running"])
            return
        }
        guard !isShutDown else {
            diagnostics.record("start.skipped", fields: ["reason": "shutdown"])
            return
        }
        windowGeneration &+= 1
        handler = onCommand
        // Cancel any pending idle-close: a window is opening.
        idleGeneration &+= 1

        switch sessionPolicy {
        case .perWindow:
            let generation = windowGeneration
            Task { @MainActor [weak self] in
                await self?.openWindow(generation: generation)
            }
        case .conversation:
            let resuming = windowPaused
            windowPaused = false
            if sessionOpen {
                // Session already open: begin a new turn, but a response may still be in
                // flight from the prior window's commit. Calling beginUserTurn while the
                // adapter is in .responding would cause a protocol violation → session death.
                //
                // _responseInFlight is confirmed by audio; _responsePendingFromTurn is set
                // when the provider's own endUserTurn/endActiveTurn fires, bridging the gap
                // between the commit and the first audio delta (the session-death race).
                if _responseInFlight || _responsePendingFromTurn {
                    if resuming {
                        // Resuming after an activity-driven pause (e.g. playback started).
                        // The response is still completing; do not cancel it — defer the
                        // turn start until responseCompleted arrives.
                        pendingUserTurn = true
                        diagnostics.record("turn.deferred_resume_response_in_flight")
                        return
                    }
                    if supportsBargeIn, _responseInFlight {
                        // Cancel only when audio has confirmed the response is in flight.
                        // _responsePendingFromTurn alone means the adapter may be
                        // responding but we cannot be sure; cancelling from .committed or
                        // .idle would violate the turn state machine.
                        backend.cancelResponse()
                        _responseInFlight = false
                        _responsePendingFromTurn = false
                        responseAudio?.stopAndFlush()
                        diagnostics.record("response.cancelled_for_new_window")
                    } else {
                        // Defer the turn until responseCompleted arrives.
                        pendingUserTurn = true
                        diagnostics.record("turn.deferred_response_in_flight")
                        return
                    }
                }
                if turnActive {
                    // The turn was preserved across an activity-driven pause (response
                    // playback started while the turn was still open). No new
                    // beginUserTurn needed.
                    freeformDeliveredThisTurn = false
                    diagnostics.record("window.resumed")
                    return
                }
                backend.beginUserTurn()
                turnActive = true
                freeformDeliveredThisTurn = false
                _responseSuppressed = false
                diagnostics.record("window.started")
            } else {
                let generation = windowGeneration
                Task { @MainActor [weak self] in
                    await self?.openWindow(generation: generation)
                }
            }
        }
    }

    public func stop() {
        switch sessionPolicy {
        case .perWindow:
            teardown()
        case .conversation:
            endWindowKeepSession()
        }
    }

    /// Suspends command delivery without tearing down backend state.
    ///
    /// In `.perWindow` mode this is identical to `stop()`. In `.conversation` mode, the
    /// handler is cleared (transcripts are dropped) but the session, the in-flight response,
    /// and response audio playback are left untouched. This is the correct behavior when the
    /// activity signal rises because backend audio *started playing*: tearing down playback
    /// would silence the response that was just enqueued.
    ///
    /// When the pause is caused by TTS rather than backend playback (TTS starts while a turn
    /// is open), the turn is ended to uphold the invariant "a turn never spans a TTS-busy
    /// interval". The distinction is made by checking `responseAudio?.isPlaying`: if playback
    /// is active, the activity rise came from playback; otherwise it came from TTS.
    public func pauseListening() {
        switch sessionPolicy {
        case .perWindow:
            stop()
        case .conversation:
            guard handler != nil else { return }
            windowPaused = true
            handler = nil
            // End the turn only when the pause is NOT caused by response playback.
            // Backend audio starting: the turn was already committed (or is about to be
            // via the coordinator), and flushing the response would silence the answer.
            // TTS starting (e.g. notification): the turn must not span the TTS interval.
            if turnActive, !(responseAudio?.isPlaying ?? false) {
                turnActive = false
                _responsePendingFromTurn = backend.endUserTurn(expectingResponse: false)
            }
            diagnostics.record("listening.paused")
        }
    }

    /// Tears down the entire session. For host teardown at serve exit.
    /// Idempotent.
    public func shutdown() {
        isShutDown = true
        idleGeneration &+= 1
        teardown()
    }

    // MARK: - Turn coordination hooks (for WP7)

    /// Whether a user turn is currently active — read hook for `WearerTurnCoordinator`.
    public var isUserTurnActiveForCoordination: Bool { turnActive }

    /// Whether a response is in flight — read hook for `WearerTurnCoordinator`.
    public var isResponseInFlight: Bool { _responseInFlight }
    private var _responseInFlight = false

    /// True after the backend reports that `endUserTurn(expectingResponse: true)` actually
    /// created a response. Derived exclusively from the backend's ground-truth return value
    /// — never from proxies like `supportsBargeIn` or turn-active state.
    ///
    /// In the gap between the commit+response.create and the first `.audio` delta,
    /// `start()` must not call `beginUserTurn()` — the adapter would reject it with
    /// `responseAlreadyInFlight`, killing the session.
    ///
    /// Cleared when `.audio` promotes it to `_responseInFlight`, when `.responseCompleted`
    /// settles the response, on session teardown, on idle-close, and on a fresh `openWindow`.
    private var _responsePendingFromTurn = false

    /// Armed when a match resolves a window while a response is pending or in flight.
    /// The response was created by a prior `endActiveTurn` (coordinator endpoint) and cannot
    /// be cancelled immediately because `turnActive` is already false and/or no `.audio` has
    /// arrived yet. On the first `.audio` (or on `responseCompleted`), the provider cancels
    /// the response instead of enqueueing. Cleared on the next `beginUserTurn`.
    private var _responseSuppressed = false

    /// Commits the current user turn without tearing down the window.
    ///
    /// Transcripts for the committed audio still route to the armed handler, so a match
    /// arriving after the commit resolves the window normally (the OpenAI flow: transcript
    /// only exists post-commit).
    ///
    /// Calling with no active turn is a recorded no-op — never a protocol violation surfaced
    /// to the window.
    public func endActiveTurn() {
        guard turnActive else {
            diagnostics.record("endActiveTurn.skipped", fields: ["reason": "no_active_turn"])
            return
        }
        turnActive = false
        _responsePendingFromTurn = backend.endUserTurn(expectingResponse: true)
        diagnostics.record("turn.committed_by_coordinator")
    }

    /// Cancels the active backend response (barge-in). Only fires when a response is in
    /// flight and the inner pipe supports barge-in (via the `supportsBargeIn` hint).
    public func cancelActiveResponse() {
        guard _responseInFlight, supportsBargeIn else {
            diagnostics.record("cancelActiveResponse.skipped",
                               fields: ["reason": _responseInFlight ? "barge_in_unsupported" : "no_response"])
            return
        }
        backend.cancelResponse()
        _responseInFlight = false
        _responsePendingFromTurn = false
        responseAudio?.stopAndFlush()
        diagnostics.record("response.cancelled_by_coordinator")
    }

    // MARK: - Window lifecycle

    private func openWindow(generation: UInt64) async {
        // The generation passed here is the window generation at call time. In per-window
        // mode it also serves as the session identity. In conversation mode we derive the
        // session generation separately.

        // Decision 3: resetStickiness on idle-close reopen must fire BEFORE backend.open
        // so the new conversation re-probes the primary. Firing after open would bind the
        // reopened conversation to the (possibly stale) fallback.
        if sessionIdleClosed {
            sessionIdleClosed = false
            onConversationReopened?()
            diagnostics.record("session.reopened_after_idle")
        }

        sessionGeneration &+= 1
        let sessGen = sessionGeneration
        do {
            try await backend.open { [weak self] event in
                self?.handleEvent(event, sessionGeneration: sessGen)
            }
        } catch {
            guard windowGeneration == generation else { return }
            diagnostics.record("window.open_failed", level: .warning,
                               fields: ["error": Self.describe(error)])
            teardown(expectedWindowGeneration: generation)
            return
        }
        guard windowGeneration == generation else {
            // `stop()` landed while the handshake was still in flight. The session is ours
            // and nobody else will ever close it.
            backend.close()
            return
        }
        sessionOpen = true
        // A fresh session has no in-flight response and no deferred turn. Clear
        // any stale state carried from a prior conversation that idle-closed while
        // a response was still tracked (e.g. audio arrived between windows, then
        // the session timed out before responseCompleted).
        _responseInFlight = false
        _responsePendingFromTurn = false
        _responseSuppressed = false
        pendingUserTurn = false
        freeformDeliveredThisTurn = false
        backend.beginUserTurn()
        turnActive = true
        diagnostics.record("window.started")
    }

    /// Route backend events. In per-window mode, events are valid only for the session
    /// generation matching the open. In conversation mode, the same session generation
    /// spans many windows; events between windows (handler == nil) are simply ignored.
    private func handleEvent(_ event: VoiceBackendEvent, sessionGeneration sessGen: UInt64) {
        guard sessionGeneration == sessGen else { return }
        switch event {
        case .transcriptPartial(let transcript):
            guard handler != nil else { return }
            consume(transcript, isFinal: false)
        case .transcriptFinal(let transcript):
            guard handler != nil else { return }
            consume(transcript, isFinal: true)
        case .audio(let chunk):
            // A suppressed response: cancel on first audio instead of enqueueing. This
            // handles the real OpenAI ordering where a match resolves after endActiveTurn
            // created a response but before any audio arrived.
            if _responseSuppressed {
                _responseSuppressed = false
                _responsePendingFromTurn = false
                if supportsBargeIn {
                    backend.cancelResponse()
                    diagnostics.record("response.suppressed_on_first_audio")
                }
                // Do not track as in-flight (we just cancelled it) and do not enqueue.
                return
            }
            // Track response-in-flight at session scope, before the window guard. Between
            // windows (handler == nil) the response is still in flight at the adapter level;
            // the next start() must know this to avoid a protocol violation.
            _responseInFlight = true
            // Audio confirms the response exists; the pending-from-turn report is promoted.
            _responsePendingFromTurn = false
            // Allow audio routing when paused: a pause-for-playback must not interrupt the
            // response that caused the pause. Without the windowPaused check, the first
            // enqueue raises isPlaying → CombinedSpeechActivity → SpeechGatedVoice.stop →
            // provider.pauseListening (handler = nil), and every subsequent chunk would be
            // silently dropped.
            guard handler != nil || windowPaused else { return }
            // An .audio event is proof a response is in flight — gate on the event stream,
            // not on composed capabilities (FailThrough intersection reports producesAudio:
            // false even when the active inner pipe is the one producing audio).
            if let responseAudio {
                responseAudio.enqueue(chunk)
            } else {
                diagnostics.record("audio.ignored")
            }
        case .responseCompleted:
            _responseInFlight = false
            _responsePendingFromTurn = false
            _responseSuppressed = false
            responseAudio?.finishStream()
            // A deferred turn was waiting for this response to complete.
            if pendingUserTurn, handler != nil {
                pendingUserTurn = false
                backend.beginUserTurn()
                turnActive = true
                freeformDeliveredThisTurn = false
                diagnostics.record("turn.started_after_deferred")
            } else {
                pendingUserTurn = false
            }
        case .sessionFailed(let failure):
            diagnostics.record("session.failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            // The session is gone: ending its turn would be a call into a dead backend.
            turnActive = false
            _responseInFlight = false
            _responsePendingFromTurn = false
            _responseSuppressed = false
            pendingUserTurn = false
            teardown()
        }
    }

    /// Transcripts are cumulative for a turn — the whole utterance so far, not a delta —
    /// which is exactly what `VoiceListener.handleRecognition` matches against today, so the
    /// grammar sees the same input it always has.
    private func consume(_ transcript: String, isFinal: Bool) {
        let command = match(transcript)
        if let command {
            diagnostics.record("command.matched", fields: ["command": "\(command)"])
            let callback = handler

            switch sessionPolicy {
            case .perWindow:
                teardown()
            case .conversation:
                endWindowKeepSession(suppressResponse: true)
            }

            if isFinal {
                onTranscriptFinal?(transcript, true)
            }
            callback?(command)
        } else {
            if isFinal {
                // The wearer said something the grammar does not know. Logged so a "voice
                // does nothing" report stays diagnosable from the log file alone.
                diagnostics.record("transcript.rejected",
                                   fields: ["reason": "unmatched",
                                            "length": "\(transcript.count)"])
                onTranscriptFinal?(transcript, false)

                // When free-form is enabled, deliver an unmatched final transcript as a
                // .freeform command exactly once per turn. Empty/whitespace-only transcripts
                // are never delivered: nothing useful can be read back or sent.
                if freeformEnabled, !freeformDeliveredThisTurn {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        freeformDeliveredThisTurn = true
                        diagnostics.record("freeform.delivered",
                                           fields: ["length": "\(trimmed.count)"])
                        handler?(.freeform(trimmed))
                    }
                }
            }
        }
    }

    // MARK: - Teardown

    /// Full teardown: ends the turn, closes the session, clears the window.
    private func teardown(expectedWindowGeneration: UInt64? = nil) {
        if let expectedWindowGeneration, expectedWindowGeneration != windowGeneration { return }
        windowGeneration &+= 1
        sessionGeneration &+= 1
        handler = nil
        _responseInFlight = false
        _responsePendingFromTurn = false
        _responseSuppressed = false
        pendingUserTurn = false
        windowPaused = false
        responseAudio?.stopAndFlush()
        if turnActive {
            turnActive = false
            backend.endUserTurn(expectingResponse: false)
        }
        if sessionOpen {
            sessionOpen = false
            backend.close()
        }
    }

    /// End the current window but keep the conversation session alive.
    /// Used in `.conversation` mode when `stop()` is called or a match resolves.
    ///
    /// When `suppressResponse` is true, any response already pending or in flight from a
    /// prior `endActiveTurn` is suppressed: if audio has arrived (`_responseInFlight`), the
    /// response is cancelled immediately; if it is still pending (`_responsePendingFromTurn`),
    /// a suppression mark is armed so the first `.audio` (or `responseCompleted`) cancels it
    /// instead of enqueueing. The turn-ending `endUserTurn` itself always passes
    /// `expectingResponse: false`, so no *new* response is created.
    private func endWindowKeepSession(suppressResponse: Bool = false) {
        windowGeneration &+= 1
        handler = nil
        pendingUserTurn = false
        windowPaused = false
        responseAudio?.stopAndFlush()
        if turnActive {
            turnActive = false
            // TapQ does not want a spoken reply for match-resolved or stop-ended windows.
            // expectingResponse: false → commit only (for transcription), no response.create.
            // The return value is the ground truth: false means no response was created.
            _responsePendingFromTurn = backend.endUserTurn(expectingResponse: false)
        }
        // Suppress a response that is already pending or in flight from a prior
        // endActiveTurn (coordinator endpoint). This is the real OpenAI ordering:
        // endActiveTurn → commit+response.create → transcript arrives → match resolves.
        if suppressResponse {
            if _responseInFlight, supportsBargeIn {
                // Audio has confirmed the response — cancel immediately.
                backend.cancelResponse()
                _responseInFlight = false
                _responsePendingFromTurn = false
                responseAudio?.stopAndFlush()
                diagnostics.record("response.suppressed_match_resolved")
            } else if _responsePendingFromTurn {
                // The backend reported it created a response, but no audio has arrived
                // yet. Arm the suppression mark: the first .audio or responseCompleted
                // will cancel instead of enqueueing.
                _responseSuppressed = true
                diagnostics.record("response.suppression_armed")
            }
        }
        // Session and session generation stay: the backend is still alive.
        if sessionOpen {
            startIdleTimer()
        }
    }

    // MARK: - Idle timer (conversation mode)

    private func startIdleTimer() {
        guard case .conversation(let idleClose) = sessionPolicy else { return }
        idleGeneration &+= 1
        let generation = idleGeneration
        let sleep = idleSleep
        Task { @MainActor [weak self] in
            await sleep(idleClose)
            self?.fireIdleClose(generation: generation)
        }
    }

    private func fireIdleClose(generation: UInt64) {
        guard idleGeneration == generation else { return }
        // Only close if no window is currently open.
        guard handler == nil else { return }
        guard sessionOpen else { return }
        diagnostics.record("session.idle_closed")
        sessionOpen = false
        sessionIdleClosed = true
        // Clear session-scoped tracking: the session is ending, so any in-flight
        // response from the prior conversation is gone and a deferred turn waiting
        // on responseCompleted would never fire.
        _responseInFlight = false
        _responsePendingFromTurn = false
        _responseSuppressed = false
        pendingUserTurn = false
        sessionGeneration &+= 1
        backend.close()
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
