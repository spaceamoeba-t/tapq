import Foundation
import TapQContracts

/// Coordinates IMU-driven turn control: endpointing (wearer speech-end commits the user
/// turn) and barge-in (wearer speech-onset during response playback interrupts audio).
///
/// Both features are additive — they only *add* calls to the existing resolution paths
/// (match-on-transcript and window timeout), never gate them. A dead, stale, or unavailable
/// signal simply means neither feature fires, and the window resolves exactly as it did
/// before the coordinator existed. This is the fail-open contract.
///
/// ## Endpointing
///
/// After observing a `startedSpeaking` transition within the current turn (the warm-up
/// guard — the detector needs approximately one `windowSeconds` of samples before its first
/// transition is meaningful), a subsequent `stoppedSpeaking` starts an endpoint-delay timer.
/// If the wearer resumes speaking before the timer fires, the timer is cancelled. On expiry
/// the coordinator calls `endpoint()` exactly once per turn. The delay sits on top of the
/// detector's own hangover (default 0.6 s), so total silence-to-commit is approximately
/// hangover + endpointDelay.
///
/// ## Barge-in
///
/// A `startedSpeaking` transition while `isResponsePlaying()` returns true calls
/// `interruptPlayback()` once per response. The coordinator does not reopen the microphone
/// or manage the gate — `SpeechGatedVoice` handles that through the combined activity
/// signal once playback stops.
///
/// ## Lifecycle
///
/// `start()` arms the coordinator at the beginning of a window; `stop()` disarms it at
/// the end. Between `stop()` and the next `start()`, signal transitions are ignored.
/// The coordinator does not own the signal child — composition passes it in, and its
/// lifetime is tied to the runtime, not the coordinator.
@MainActor public final class WearerTurnCoordinator {
    /// Seconds of silence (after the detector's own hangover) before the endpoint fires.
    /// Provisional; the capture study will replace it.
    public nonisolated static let defaultEndpointDelay: TimeInterval = 0.4

    private let signal: any WearerSpeechSignaling
    private let endpoint: @MainActor () -> Void
    private let interruptPlayback: @MainActor () -> Void
    private let isResponsePlaying: @MainActor () -> Bool
    private let isUserTurnActive: @MainActor () -> Bool
    private let endpointDelay: TimeInterval
    private let delaySleep: @MainActor (TimeInterval) async -> Void

    /// True between `start()` and `stop()`.
    private var armed = false
    /// True after observing a `startedSpeaking` in the current armed session. The warm-up
    /// guard: do not honour a `stoppedSpeaking` unless a `startedSpeaking` preceded it
    /// within this window, because the detector's first quiet state during warm-up is not
    /// a meaningful silence.
    private var hasObservedOnset = false
    /// Whether the endpoint has already fired for this turn. Reset on `start()`.
    private var endpointFired = false
    /// Whether barge-in has already fired for the current response. Reset when the
    /// response ends (tracked via `lastKnownResponsePlaying`).
    private var bargeInFiredForResponse = false
    /// Generation counter for the endpoint-delay timer, so a resume cancels the pending
    /// timer without requiring cooperative cancellation of a Task.
    private var endpointGeneration: UInt64 = 0
    /// Tracks the last known response-playing state to detect edges for resetting the
    /// barge-in flag.
    private var lastKnownResponsePlaying = false
    /// Set in `fireEndpoint` when the endpoint call actually ended the turn
    /// (i.e., `isUserTurnActive()` returns false after calling `endpoint()`). The next
    /// speech transition that sees an active turn clears this flag and re-arms per-turn
    /// state, enabling endpointing for the new window.
    private var needsRearmOnNextActiveTurn = false

    /// - Parameters:
    ///   - signal: A `WearerSpeechSignaling` child from a `WearerSpeechSignalSource`.
    ///   - endpoint: Called when the wearer stops speaking and the delay expires. Typically
    ///     wired to `VoiceBackendCommandProvider.endActiveTurn`.
    ///   - interruptPlayback: Called on barge-in. Typically wired to flush playback, cancel
    ///     the backend response, and stop TTS.
    ///   - isResponsePlaying: Read hook; returns true when backend audio or TTS is playing.
    ///   - isUserTurnActive: Read hook; returns true when a user turn is open on the provider.
    ///   - endpointDelay: Seconds of silence after the detector's hangover before committing.
    ///     Default 0.4 s.
    ///   - delaySleep: Injectable sleep for testing (virtual clock).
    public init(
        signal: any WearerSpeechSignaling,
        endpoint: @escaping @MainActor () -> Void,
        interruptPlayback: @escaping @MainActor () -> Void,
        isResponsePlaying: @escaping @MainActor () -> Bool,
        isUserTurnActive: @escaping @MainActor () -> Bool,
        endpointDelay: TimeInterval = WearerTurnCoordinator.defaultEndpointDelay,
        delaySleep: @escaping @MainActor (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0))
        }
    ) {
        self.signal = signal
        self.endpoint = endpoint
        self.interruptPlayback = interruptPlayback
        self.isResponsePlaying = isResponsePlaying
        self.isUserTurnActive = isUserTurnActive
        self.endpointDelay = endpointDelay
        self.delaySleep = delaySleep

        signal.onWearerSpeakingChange = { [weak self] speaking in
            self?.handleTransition(speaking: speaking)
        }
    }

    /// Arms the coordinator for a new window/turn.
    public func start() {
        armed = true
        hasObservedOnset = false
        endpointFired = false
        bargeInFiredForResponse = false
        needsRearmOnNextActiveTurn = false
        endpointGeneration &+= 1
        lastKnownResponsePlaying = isResponsePlaying()
    }

    /// Disarms the coordinator at the end of a window.
    public func stop() {
        armed = false
        hasObservedOnset = false
        endpointFired = false
        bargeInFiredForResponse = false
        needsRearmOnNextActiveTurn = false
        endpointGeneration &+= 1
    }

    // MARK: - Private

    private func handleTransition(speaking: Bool) {
        guard armed else { return }
        guard signal.isSignalAvailable else { return }

        // Per-turn re-arm: when the endpoint fired for a prior turn and actually ended
        // that turn (needsRearmOnNextActiveTurn was set in fireEndpoint because
        // isUserTurnActive() returned false after the endpoint() call), the next speech
        // transition in a new active turn re-arms per-turn state. This is what makes
        // endpointing work across multiple windows when the coordinator is start()-ed
        // once for the serve lifetime. Without this, endpointFired stays true after the
        // first endpoint and blocks all subsequent windows.
        if needsRearmOnNextActiveTurn, isUserTurnActive() {
            hasObservedOnset = false
            endpointFired = false
            endpointGeneration &+= 1
            needsRearmOnNextActiveTurn = false
        }

        if speaking {
            handleOnset()
        } else {
            handleOffset()
        }
    }

    private func handleOnset() {
        hasObservedOnset = true
        // Cancel any pending endpoint-delay timer: the wearer resumed speaking.
        endpointGeneration &+= 1

        // Barge-in: speech onset while a response is playing.
        checkBargeIn()
    }

    private func handleOffset() {
        // Update barge-in tracking: if the response ended while we were speaking,
        // we need to clear the flag for the next response.
        updateBargeInTracking()

        // Endpointing: only after a prior onset in this turn (warm-up guard), and only
        // while a user turn is active (the turn may have been committed by a transcript
        // match already).
        guard hasObservedOnset else { return }
        guard !endpointFired else { return }
        guard isUserTurnActive() else { return }

        startEndpointTimer()
    }

    /// Updates the barge-in response tracking state. Called on every transition to detect
    /// when a response has ended (even if it ended while the wearer was speaking).
    private func updateBargeInTracking() {
        let currentlyPlaying = isResponsePlaying()
        if !currentlyPlaying {
            bargeInFiredForResponse = false
        }
        lastKnownResponsePlaying = currentlyPlaying
    }

    private func checkBargeIn() {
        updateBargeInTracking()

        let currentlyPlaying = isResponsePlaying()
        guard currentlyPlaying else { return }
        guard !bargeInFiredForResponse else { return }

        bargeInFiredForResponse = true
        interruptPlayback()
    }

    private func startEndpointTimer() {
        endpointGeneration &+= 1
        let generation = endpointGeneration
        let sleep = delaySleep
        Task { @MainActor [weak self] in
            await sleep(self?.endpointDelay ?? 0)
            self?.fireEndpoint(generation: generation)
        }
    }

    private func fireEndpoint(generation: UInt64) {
        guard endpointGeneration == generation else { return }
        guard armed else { return }
        guard !endpointFired else { return }
        // Re-check that the turn is still active: a match or timeout may have resolved
        // it while the delay was in flight.
        guard isUserTurnActive() else { return }
        // Re-check that the signal is still available: if it went stale during the delay,
        // do not commit (fail open means "do nothing", not "commit on stale data").
        guard signal.isSignalAvailable else { return }

        endpointFired = true
        endpoint()
        // If the endpoint() call ended the turn (the normal path: endpoint() calls
        // endActiveTurn()), mark that the next active turn should re-arm. Without this
        // the coordinator works only for the first endpoint when start() is called once
        // for the serve lifetime.
        if !isUserTurnActive() {
            needsRearmOnNextActiveTurn = true
        }
    }
}
