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
            let sleep = timeoutSleep
            timeoutTask = Task { @MainActor [weak self] in
                await sleep(timeout)
                if !Task.isCancelled { self?.finish(nil) }
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
