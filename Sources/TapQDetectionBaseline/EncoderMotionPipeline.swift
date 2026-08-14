import Foundation
import TapQGestureContracts

/// Stateful decision layer over a TapQ-1 window scorer. It owns windowing, per-window
/// acceptance (threshold + margin), consecutive-window agreement, atom debounce, and
/// the same double-nod/double-shake/double-tilt pairing semantics as the heuristic
/// `MotionGesturePipeline` — so swapping backends never changes command timing, and the
/// doubling false-positive filter for window-spanning gestures stays deterministic
/// rather than learned. `tap` atoms carry the whole double-tap pattern (both transients
/// fit in one window) and therefore emit directly, as do swipes.
public struct EncoderMotionPipeline {
    public var config: EncoderConfig {
        didSet {
            windowBuilder = EncoderWindowBuilder(
                windowLength: config.windowLength,
                hopSamples: config.hopSamples,
                gapResetSeconds: config.gapResetSeconds
            )
        }
    }

    private let scorer: any MotionWindowScoring
    private var windowBuilder: EncoderWindowBuilder
    private var streakClass: GestureClass?
    private var streakCount = 0
    private var lastAtomTime: TimeInterval = -.greatestFiniteMagnitude
    private var lastEventTime: TimeInterval = -.greatestFiniteMagnitude
    private var pendingFirstNod: TimeInterval?
    private var pendingFirstShake: TimeInterval?
    private var pendingFirstTilt: (time: TimeInterval, direction: TiltCommand)?
    private var scoringFailureCount = 0
    private var missingPerAxisLogged = false
    private let diagnostics: TapQDiagnosticEmitter

    public init(
        scorer: any MotionWindowScoring,
        config: EncoderConfig = .init(),
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.scorer = scorer
        self.config = config
        self.windowBuilder = EncoderWindowBuilder(
            windowLength: config.windowLength,
            hopSamples: config.hopSamples,
            gapResetSeconds: config.gapResetSeconds
        )
        self.diagnostics = TapQDiagnosticEmitter(category: "EncoderPipeline", sink: diagnosticSink)
    }

    /// Clears all temporal state while retaining configuration, scorer, and sink.
    public mutating func reset() {
        windowBuilder.reset()
        streakClass = nil
        streakCount = 0
        lastAtomTime = -.greatestFiniteMagnitude
        lastEventTime = -.greatestFiniteMagnitude
        pendingFirstNod = nil
        pendingFirstShake = nil
        pendingFirstTilt = nil
        missingPerAxisLogged = false
    }

    public mutating func ingest(_ sample: HeadMotionSample) -> MotionDetectionResult {
        guard sample.hasPerAxisData else {
            if !missingPerAxisLogged {
                diagnostics.record("encoder.per_axis_missing", level: .warning)
                missingPerAxisLogged = true
            }
            return MotionDetectionResult()
        }

        expirePendings(at: sample.timestamp)

        guard let window = windowBuilder.push(sample) else {
            return MotionDetectionResult()
        }
        guard let atom = classify(window) else { return MotionDetectionResult() }
        return route(atom: atom, at: window.endTime)
    }

    /// Scores one window and applies acceptance plus agreement; returns an atom the
    /// moment the streak requirement is met.
    private mutating func classify(_ window: EncoderInputWindow) -> GestureClass? {
        let scores: GestureScores
        do {
            scores = try scorer.score(window)
        } catch {
            scoringFailureCount += 1
            if scoringFailureCount == 1 || scoringFailureCount % 100 == 0 {
                diagnostics.record("encoder.scoring_failed", level: .error, fields: [
                    "error": String(describing: error),
                    "failures": "\(scoringFailureCount)",
                ])
            }
            return nil
        }

        let ranked = scores.ranked
        guard let top = ranked.first, top.gestureClass != .quiet,
              Double(top.probability) >= config.classThreshold,
              ranked.count < 2 || Double(top.probability - ranked[1].probability)
                >= config.minMargin else {
            streakClass = nil
            streakCount = 0
            return nil
        }

        if streakClass == top.gestureClass {
            streakCount += 1
        } else {
            streakClass = top.gestureClass
            streakCount = 1
        }
        guard streakCount >= config.agreementWindows else { return nil }

        // Re-arming requires a fresh streak: a sustained motion must not emit again on
        // every following hop.
        streakClass = nil
        streakCount = 0
        diagnostics.record("encoder.atom", fields: [
            "class": top.gestureClass.rawValue,
            "probability": String(format: "%.3f", top.probability),
        ])
        return top.gestureClass
    }

    private mutating func route(atom: GestureClass, at time: TimeInterval) -> MotionDetectionResult {
        guard time - lastEventTime > config.eventDebounceSeconds,
              time - lastAtomTime > config.atomDebounceSeconds else {
            return MotionDetectionResult()
        }
        lastAtomTime = time

        switch atom {
        case .quiet:
            return MotionDetectionResult()
        case .nod:
            // A nod atom is one excursion; the heuristics require two, so the encoder
            // must as well or the same motion would mean different things per backend.
            pendingFirstShake = nil
            guard let paired = pairNod(at: time) else { return MotionDetectionResult() }
            return emit(.init(gesture: .nod), channel: "nod", gap: paired, at: time)
        case .shake:
            pendingFirstNod = nil
            guard let paired = pairShake(at: time) else { return MotionDetectionResult() }
            return emit(.init(gesture: .shake), channel: "shake", gap: paired, at: time)
        case .tiltLeft, .tiltRight:
            let direction: TiltCommand = atom == .tiltLeft ? .tiltLeft : .tiltRight
            guard let gap = pairTilt(direction: direction, at: time) else {
                return MotionDetectionResult()
            }
            return emit(.init(tilt: direction), channel: "tilt", gap: gap, at: time)
        case .tap:
            // A tap atom is the full double-tap pattern; nothing further to pair.
            return emit(.init(tap: .tap), channel: "tap", gap: nil, at: time)
        case .swipeUp:
            return emit(.init(swipe: .swipeUp), channel: "swipe", gap: nil, at: time)
        case .swipeDown:
            return emit(.init(swipe: .swipeDown), channel: "swipe", gap: nil, at: time)
        }
    }

    /// First atom arms the pending state; a second inside the pair window (but past the
    /// echo gap) completes it. Echoes are dropped with the pending kept, mirroring the
    /// heuristic pipeline.
    private mutating func pairNod(at time: TimeInterval) -> TimeInterval? {
        if let first = pendingFirstNod {
            let gap = time - first
            guard gap >= config.minNodPairGap else {
                diagnostics.record("encoder.rejected", fields: [
                    "channel": "nod", "reason": "pair_echo",
                ])
                return nil
            }
            pendingFirstNod = nil
            return gap
        }
        diagnostics.record("encoder.pending", fields: ["channel": "nod"])
        pendingFirstNod = time
        return nil
    }

    private mutating func pairShake(at time: TimeInterval) -> TimeInterval? {
        if let first = pendingFirstShake {
            let gap = time - first
            guard gap >= config.minShakePairGap else {
                diagnostics.record("encoder.rejected", fields: [
                    "channel": "shake", "reason": "pair_echo",
                ])
                return nil
            }
            pendingFirstShake = nil
            return gap
        }
        diagnostics.record("encoder.pending", fields: ["channel": "shake"])
        pendingFirstShake = time
        return nil
    }

    private mutating func pairTilt(direction: TiltCommand, at time: TimeInterval) -> TimeInterval? {
        if let first = pendingFirstTilt {
            guard first.direction == direction else {
                diagnostics.record("encoder.pending_replaced", fields: [
                    "channel": "tilt", "was": "\(first.direction)", "now": "\(direction)",
                ])
                pendingFirstTilt = (time, direction)
                return nil
            }
            let gap = time - first.time
            guard gap >= config.minTiltPairGap else {
                diagnostics.record("encoder.rejected", fields: [
                    "channel": "tilt", "reason": "pair_echo",
                ])
                return nil
            }
            pendingFirstTilt = nil
            return gap
        }
        diagnostics.record("encoder.pending", fields: [
            "channel": "tilt", "direction": "\(direction)",
        ])
        pendingFirstTilt = (time, direction)
        return nil
    }

    private mutating func emit(
        _ result: MotionDetectionResult, channel: String,
        gap: TimeInterval?, at time: TimeInterval
    ) -> MotionDetectionResult {
        lastEventTime = time
        var fields = ["channel": channel]
        if let gap { fields["gap"] = String(format: "%.3f", gap) }
        diagnostics.record("encoder.detected", fields: fields)
        return result
    }

    private mutating func expirePendings(at time: TimeInterval) {
        if let first = pendingFirstNod, time - first > config.nodPairWindowSeconds {
            diagnostics.record("encoder.pending_expired", fields: ["channel": "nod"])
            pendingFirstNod = nil
        }
        if let first = pendingFirstShake, time - first > config.shakePairWindowSeconds {
            diagnostics.record("encoder.pending_expired", fields: ["channel": "shake"])
            pendingFirstShake = nil
        }
        if let pending = pendingFirstTilt,
           time - pending.time > config.tiltPairWindowSeconds {
            diagnostics.record("encoder.pending_expired", fields: ["channel": "tilt"])
            pendingFirstTilt = nil
        }
    }
}
