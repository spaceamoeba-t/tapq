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
            if sessionOpen {
                // Session already open: begin a new turn, but a response may still be in
                // flight from the prior window's commit. Calling beginUserTurn while the
                // adapter is in .responding would cause a protocol violation → session death.
                if _responseInFlight {
                    if supportsBargeIn {
                        // Cancel the in-flight response, then begin the turn.
                        backend.cancelResponse()
                        _responseInFlight = false
                        responseAudio?.stopAndFlush()
                        diagnostics.record("response.cancelled_for_new_window")
                    } else {
                        // Defer the turn until responseCompleted arrives.
                        pendingUserTurn = true
                        diagnostics.record("turn.deferred_response_in_flight")
                        return
                    }
                }
                backend.beginUserTurn()
                turnActive = true
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
        backend.endUserTurn()
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
        responseAudio?.stopAndFlush()
        diagnostics.record("response.cancelled_by_coordinator")
    }

    // MARK: - Window lifecycle

    private func openWindow(generation: UInt64) async {
        // The generation passed here is the window generation at call time. In per-window
        // mode it also serves as the session identity. In conversation mode we derive the
        // session generation separately.
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
        pendingUserTurn = false
        if sessionIdleClosed {
            sessionIdleClosed = false
            onConversationReopened?()
            diagnostics.record("session.reopened_after_idle")
        }
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
            // Track response-in-flight at session scope, before the window guard. Between
            // windows (handler == nil) the response is still in flight at the adapter level;
            // the next start() must know this to avoid a protocol violation.
            _responseInFlight = true
            guard handler != nil else { return }
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
            responseAudio?.finishStream()
            // A deferred turn was waiting for this response to complete.
            if pendingUserTurn, handler != nil {
                pendingUserTurn = false
                backend.beginUserTurn()
                turnActive = true
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
        pendingUserTurn = false
        responseAudio?.stopAndFlush()
        if turnActive {
            turnActive = false
            backend.endUserTurn()
        }
        if sessionOpen {
            sessionOpen = false
            backend.close()
        }
    }

    /// End the current window but keep the conversation session alive.
    /// Used in `.conversation` mode when `stop()` is called or a match resolves.
    ///
    /// When `suppressResponse` is true and `supportsBargeIn`, the response that
    /// `endUserTurn` may have triggered on the backend (e.g. OpenAI's `response.create`)
    /// is cancelled immediately. This prevents a spurious cloud response per
    /// voice-resolved window in conversation mode.
    private func endWindowKeepSession(suppressResponse: Bool = false) {
        windowGeneration &+= 1
        handler = nil
        pendingUserTurn = false
        responseAudio?.stopAndFlush()
        if turnActive {
            turnActive = false
            backend.endUserTurn()
            if suppressResponse, supportsBargeIn {
                backend.cancelResponse()
                diagnostics.record("response.suppressed_match_resolved")
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
        pendingUserTurn = false
        sessionGeneration &+= 1
        backend.close()
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
