import Foundation
import TapQContracts

/// Maps voice/head-gesture/tilt/volume-swipe/tap into intents for option selection.
/// Navigation channels map to next/previous; nod and tap confirm the current option;
/// shake defers to the on-screen prompt. First input wins per listen window.
@MainActor public final class SelectionArbiter: SelectionArbitrating {
    private let voice: VoiceCommandProviding?
    private let tilts: TiltCommandProviding?
    private let swipes: VolumeSwipeProviding?
    private let taps: TapCommandProviding?
    private let gestures: HeadGestureProviding?
    private var continuation: CheckedContinuation<InputIntent?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let diagnostics: TapQDiagnosticEmitter

    public init(voice: VoiceCommandProviding?, tilts: TiltCommandProviding?,
                swipes: VolumeSwipeProviding?, taps: TapCommandProviding?,
                gestures: HeadGestureProviding? = nil,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.voice = voice
        self.tilts = tilts
        self.swipes = swipes
        self.taps = taps
        self.gestures = gestures
        self.diagnostics = TapQDiagnosticEmitter(category: "SelectionArbiter", sink: diagnosticSink)
    }

    public func listen(timeout: TimeInterval) async -> InputIntent? {
        diagnostics.record("listen.started", fields: ["timeout": "\(timeout)"])
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
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
        if voice == nil, tilts == nil, swipes == nil, taps == nil,
           gestures == nil, timeout <= 0 {
            finish(nil)
            return
        }
        gestures?.start { [weak self] gesture in
            self?.diagnostics.record("input.gesture", fields: ["gesture": "\(gesture)"])
            self?.finish(gesture == .nod ? .select : .deny)
        }
        tilts?.start { [weak self] tilt in
            self?.diagnostics.record("input.tilt", fields: ["tilt": "\(tilt)"])
            self?.finish(tilt == .tiltDown ? .next : .previous)
        }
        swipes?.start { [weak self] swipe in
            self?.diagnostics.record("input.swipe", fields: ["swipe": "\(swipe)"])
            self?.finish(swipe == .swipeDown ? .next : .previous)
        }
        taps?.start { [weak self] tap in
            self?.diagnostics.record("input.tap", fields: ["tap": "\(tap)"])
            self?.finish(tap.intent)
        }
        voice?.start { [weak self] command in
            self?.diagnostics.record("input.voice", fields: ["command": "\(command)"])
            self?.finish(command.intent)
        }
        if timeout > 0 {
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled { self?.finish(nil) }
            }
        }
    }

    private func finish(_ intent: InputIntent?) {
        guard let continuation else { return }
        diagnostics.record("listen.resolved",
                           fields: ["intent": intent.map { "\($0)" } ?? "none"])
        self.continuation = nil
        voice?.stop()
        gestures?.stop()
        tilts?.stop()
        swipes?.stop()
        taps?.stop()
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: intent)
    }
}
