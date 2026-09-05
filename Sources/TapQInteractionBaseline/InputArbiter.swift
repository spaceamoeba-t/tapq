import Foundation
import TapQContracts

/// Opens the head-gesture, voice, and tap channels together for one input window and resolves
/// the first confident intent (first-wins), cancelling the other channels and the timeout.
@MainActor public final class InputArbiter: InputArbitrating {
    private let gestures: HeadGestureProviding?
    private let voice: VoiceCommandProviding?
    private let taps: TapCommandProviding?
    private var continuation: CheckedContinuation<ResolvedInput?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let diagnostics: TapQDiagnosticEmitter
    private let timeoutSleep: @MainActor (TimeInterval) async -> Void

    /// How long a listen will wait for the voice channel to actually start hearing the
    /// wearer before its clock begins. A cold realtime session takes a few seconds to open
    /// and the window's cue is spoken before the turn begins; fifteen seconds is far past
    /// both, so a session that never opens still ends the listen.
    public nonisolated static let maxListenPreRoll: TimeInterval = 15
    /// How long a listen whose clock ran out will wait for a sentence in progress — the
    /// wearer still speaking, or their committed sentence with the model — before giving
    /// up on it. Bounded so a detector stuck on "speaking" costs one window, not the run.
    public nonisolated static let maxMidSentenceExtension: TimeInterval = 10
    /// The poll the two waits above run at.
    public nonisolated static let timingPollInterval: TimeInterval = 0.25

    /// Pre-roll credited plus mid-sentence wait, for the most recent listen. See
    /// `InputArbitrating.lastListenExtension`.
    public private(set) var lastListenExtension: TimeInterval = 0

    /// - Parameter timeoutSleep: Injectable sleep for testing (virtual clock). The default
    ///   is the real timer, so runtime behavior is unchanged.
    public init(gestures: HeadGestureProviding?, voice: VoiceCommandProviding?,
                taps: TapCommandProviding? = nil,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                timeoutSleep: @escaping @MainActor (TimeInterval) async -> Void = {
                    try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.gestures = gestures
        self.voice = voice
        self.taps = taps
        self.diagnostics = TapQDiagnosticEmitter(category: "InputArbiter", sink: diagnosticSink)
        self.timeoutSleep = timeoutSleep
    }

    public func listen(timeout: TimeInterval) async -> InputIntent? {
        await listenForInput(timeout: timeout)?.intent
    }

    public func listenForInput(timeout: TimeInterval) async -> ResolvedInput? {
        diagnostics.record("listen.started", fields: ["timeout": "\(timeout)"])
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                // Backstop (the InteractionGate should prevent this): a second listen
                // while one is pending resolves the stale window as a timeout instead
                // of leaking its continuation and hanging that request's hook.
                if self.continuation != nil {
                    self.diagnostics.record("listen.overlap", level: .warning)
                    self.finish(nil)
                }
                self.continuation = continuation
                self.begin(timeout: timeout)
            }
        }
    }

    /// Resolves any pending window as a timeout (nil): used when an input channel dies
    /// mid-window (AirPods disconnect) and waiting out the timeout would strand the
    /// user in silence. No-op when nothing is pending.
    public func cancel() {
        guard continuation != nil else { return }
        diagnostics.record("listen.cancelled", level: .warning)
        finish(nil)
    }

    private func begin(timeout: TimeInterval) {
        if gestures == nil, voice == nil, taps == nil, timeout <= 0 {
            finish(nil)
            return
        }
        gestures?.start { [weak self] gesture in
            self?.diagnostics.record("input.gesture", fields: ["gesture": "\(gesture)"])
            self?.finish(.init(intent: gesture == .nod ? .allow : .deny, channel: .gesture))
        }
        taps?.start { [weak self] tap in
            self?.diagnostics.record("input.tap", fields: ["tap": "\(tap)"])
            self?.finish(.init(intent: tap.intent, channel: .tap))
        }
        voice?.start { [weak self] command in
            self?.diagnostics.record("input.voice", fields: ["command": "\(command)"])
            self?.finish(.init(intent: command.intent, channel: .voice))
        }
        if timeout > 0 {
            lastListenExtension = 0
            let sleep = timeoutSleep
            let timing = voice as? VoiceTurnTiming
            timeoutTask = Task { @MainActor [weak self] in
                // The clock starts when the wearer can be heard, not when the window asked.
                // Before that the voice channel may still be opening a session or speaking
                // the window's own cue, and a timer running through that was charging the
                // wearer for silence they could not fill (2026-09-04, the first wake-word
                // window: twenty seconds, of which the microphone had eight).
                var preRoll: TimeInterval = 0
                if let timing {
                    while !timing.isListening, preRoll < Self.maxListenPreRoll,
                          !Task.isCancelled {
                        await sleep(Self.timingPollInterval)
                        preRoll += Self.timingPollInterval
                    }
                    if preRoll > 0 {
                        self?.diagnostics.record("listen.preroll_credited", fields: [
                            "ms": "\(Int((preRoll * 1_000).rounded()))",
                            "listening": "\(timing.isListening)",
                        ])
                    }
                }
                guard !Task.isCancelled else { return }
                await sleep(timeout)
                // The clock ran out, but the wearer is mid-sentence, or the sentence they
                // finished is with the model and no answer is back. Closing now would throw
                // that sentence away; waiting is bounded so a stuck signal costs one window.
                var extended: TimeInterval = 0
                if let timing {
                    while timing.isWearerTurnUnresolved,
                          extended < Self.maxMidSentenceExtension, !Task.isCancelled {
                        await sleep(Self.timingPollInterval)
                        extended += Self.timingPollInterval
                    }
                    if extended > 0 {
                        self?.diagnostics.record("listen.extended_for_turn", fields: [
                            "ms": "\(Int((extended * 1_000).rounded()))",
                            "resolved": "\(!timing.isWearerTurnUnresolved)",
                        ])
                    }
                }
                guard !Task.isCancelled else { return }
                self?.lastListenExtension = preRoll + extended
                self?.finish(nil)
            }
        }
    }

    private func finish(_ input: ResolvedInput?) {
        guard let continuation else { return }
        diagnostics.record("listen.resolved",
                           fields: ["intent": input.map { "\($0.intent)" } ?? "none"])
        self.continuation = nil
        gestures?.stop()
        // A window nothing resolved is ended differently from one the wearer resolved, and
        // the voice channel is the only one that can tell the difference apart. `nil` here
        // is the timeout (or a channel dying mid-window): no gesture, no tap, no command.
        // A conversation-mode backend may still be mid-sentence, and a clock coming round
        // is not a reason to stop it — see `VoiceCommandProviding.stopUnresolved`.
        if input == nil { voice?.stopUnresolved() } else { voice?.stop() }
        taps?.stop()
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: input)
    }
}
