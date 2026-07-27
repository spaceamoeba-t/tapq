import Foundation
import TapQContracts

/// Detections produced while ingesting one platform-neutral motion sample.
public struct MotionDetectionResult: Sendable, Equatable {
    public let gesture: HeadGesture?
    public let tap: TapCommand?
    public let tilt: TiltCommand?
    public let swipe: MotionSwipeCommand?

    public init(gesture: HeadGesture? = nil, tap: TapCommand? = nil,
                tilt: TiltCommand? = nil, swipe: MotionSwipeCommand? = nil) {
        self.gesture = gesture
        self.tap = tap
        self.tilt = tilt
        self.swipe = swipe
    }
}

/// Stateful, hardware-independent motion pipeline. It owns sliding windows, debounce,
/// double-nod/double-shake/double-tap/double-tilt pairing, and tilt and swipe detection;
/// CoreMotion is only an input adapter.
public struct MotionGesturePipeline {
    public var config: HeadGestureConfig {
        didSet { gestureAnalyzer = GestureAnalyzer(config: config) }
    }
    public var tapConfig: TapConfig {
        didSet { tapAnalyzer = TapAnalyzer(config: tapConfig) }
    }
    public var tiltConfig: TiltConfig {
        didSet { tiltAnalyzer = TiltAnalyzer(config: tiltConfig) }
    }
    public var swipeConfig: SwipeConfig {
        didSet { swipeAnalyzer = SwipeAnalyzer(config: swipeConfig) }
    }
    public var tapDetectionEnabled: Bool
    /// Swipe detection is experimental and stays off until capture-study validation;
    /// when off, no per-axis swipe windows are even accumulated.
    public var swipeDetectionEnabled: Bool

    private var gestureAnalyzer: GestureAnalyzer
    private var tapAnalyzer: TapAnalyzer
    private var tiltAnalyzer: TiltAnalyzer
    private var swipeAnalyzer: SwipeAnalyzer
    private var pitch: [(time: TimeInterval, value: Double)] = []
    private var yaw: [(time: TimeInterval, value: Double)] = []
    private var acceleration: [(time: TimeInterval, value: Double)] = []
    private var rotation: [(time: TimeInterval, value: Double)] = []
    private var tiltRoll: [(time: TimeInterval, value: Double)] = []
    private var tiltPitch: [(time: TimeInterval, value: Double)] = []
    private var tiltYaw: [(time: TimeInterval, value: Double)] = []
    private var swipeAcceleration: [(time: TimeInterval, value: MotionVector)] = []
    private var swipeGravity: [(time: TimeInterval, value: MotionVector)] = []
    private var swipeRotation: [(time: TimeInterval, value: Double)] = []
    private var lastGestureEmit: TimeInterval = -.greatestFiniteMagnitude
    private var lastTapEmit: TimeInterval = -.greatestFiniteMagnitude
    private var lastTiltEmit: TimeInterval = -.greatestFiniteMagnitude
    private var lastSwipeEmit: TimeInterval = -.greatestFiniteMagnitude
    private var pendingFirstTap: TimeInterval?
    private var pendingFirstNod: TimeInterval?
    private var pendingFirstShake: TimeInterval?
    private var pendingFirstTilt: (time: TimeInterval, direction: TiltCommand)?
    private var tapDiagnosticCandidateStartedAt: TimeInterval?
    private var tapDiagnosticBaselineWaitLogged = false
    private var tapSampleTraceStartedAt: TimeInterval?
    private var tapSampleTraceSampleCount = 0
    private let diagnostics: TapQDiagnosticEmitter
    private static let tapSampleTraceDurationSeconds: TimeInterval = 0.6

    public init(
        config: HeadGestureConfig = .init(),
        tapConfig: TapConfig = .init(),
        tiltConfig: TiltConfig = .init(),
        swipeConfig: SwipeConfig = .init(),
        tapDetectionEnabled: Bool = true,
        swipeDetectionEnabled: Bool = false,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.config = config
        self.tapConfig = tapConfig
        self.tiltConfig = tiltConfig
        self.swipeConfig = swipeConfig
        self.gestureAnalyzer = GestureAnalyzer(config: config)
        self.tapAnalyzer = TapAnalyzer(config: tapConfig)
        self.tiltAnalyzer = TiltAnalyzer(config: tiltConfig)
        self.swipeAnalyzer = SwipeAnalyzer(config: swipeConfig)
        self.tapDetectionEnabled = tapDetectionEnabled
        self.swipeDetectionEnabled = swipeDetectionEnabled
        self.diagnostics = TapQDiagnosticEmitter(category: "MotionPipeline", sink: diagnosticSink)
    }

    /// Clears all temporal state while retaining configuration and the diagnostic sink.
    public mutating func reset() {
        if pendingFirstTap != nil {
            diagnostics.record("tap.pending_cancelled", fields: ["reason": "pipeline_reset"])
        }
        if tapDiagnosticCandidateStartedAt != nil {
            diagnostics.record("tap.candidate_cancelled", fields: ["reason": "pipeline_reset"])
        }
        if tapSampleTraceStartedAt != nil {
            diagnostics.record("tap.sample_trace_cancelled", fields: [
                "reason": "pipeline_reset",
                "samples": "\(tapSampleTraceSampleCount)",
            ])
        }
        pitch.removeAll()
        yaw.removeAll()
        acceleration.removeAll()
        rotation.removeAll()
        tiltRoll.removeAll()
        tiltPitch.removeAll()
        tiltYaw.removeAll()
        swipeAcceleration.removeAll()
        swipeGravity.removeAll()
        swipeRotation.removeAll()
        lastGestureEmit = -.greatestFiniteMagnitude
        lastTapEmit = -.greatestFiniteMagnitude
        lastTiltEmit = -.greatestFiniteMagnitude
        lastSwipeEmit = -.greatestFiniteMagnitude
        pendingFirstTap = nil
        pendingFirstNod = nil
        pendingFirstShake = nil
        pendingFirstTilt = nil
        tapDiagnosticCandidateStartedAt = nil
        tapDiagnosticBaselineWaitLogged = false
        tapSampleTraceStartedAt = nil
        tapSampleTraceSampleCount = 0
    }

    public mutating func ingest(_ sample: HeadMotionSample) -> MotionDetectionResult {
        MotionDetectionResult(
            gesture: ingestGesture(pitch: sample.pitch, yaw: sample.yaw,
                                   time: sample.timestamp),
            tap: ingestTap(acceleration: sample.accelerationMagnitude,
                           rotation: sample.rotationMagnitude,
                           time: sample.timestamp),
            tilt: ingestTilt(roll: sample.roll, pitch: sample.pitch, yaw: sample.yaw,
                             time: sample.timestamp),
            swipe: ingestSwipe(sample)
        )
    }

    public mutating func ingestGesture(pitch newPitch: Double, yaw newYaw: Double,
                                       time: TimeInterval) -> HeadGesture? {
        pitch.append((time, newPitch))
        yaw.append((time, newYaw))
        let cutoff = time - config.windowSeconds
        pitch.removeAll { $0.time < cutoff }
        yaw.removeAll { $0.time < cutoff }

        guard time - lastGestureEmit > config.debounceSeconds else { return nil }

        if let first = pendingFirstNod,
           time - first > config.doubleNodWindowSeconds {
            pendingFirstNod = nil
        }
        if let first = pendingFirstShake,
           time - first > config.doubleShakeWindowSeconds {
            diagnostics.record("gesture.shake_pending_expired")
            pendingFirstShake = nil
        }

        guard let gesture = gestureAnalyzer.detect(
            pitch: pitch.map(\.value), yaw: yaw.map(\.value)
        ) else { return nil }

        if gesture == .nod {
            pendingFirstShake = nil
            if let first = pendingFirstNod {
                let gap = time - first
                guard gap >= config.minDoubleNodGap else {
                    diagnostics.record("gesture.rejected", fields: ["reason": "double_nod_echo"])
                    pitch.removeAll()
                    yaw.removeAll()
                    return nil
                }
                pendingFirstNod = nil
                lastGestureEmit = time
                let pitchValues = pitch.map(\.value)
                let yawValues = yaw.map(\.value)
                pitch.removeAll()
                yaw.removeAll()
                recordGesture(gesture, pitch: pitchValues, yaw: yawValues,
                              extraFields: ["gap": "\(gap)"])
                return .nod
            }

            diagnostics.record("gesture.nod_pending")
            pendingFirstNod = time
            pitch.removeAll()
            yaw.removeAll()
            return nil
        }

        pendingFirstNod = nil
        if let first = pendingFirstShake {
            let gap = time - first
            guard gap >= config.minDoubleShakeGap else {
                diagnostics.record("gesture.rejected", fields: ["reason": "double_shake_echo"])
                pitch.removeAll()
                yaw.removeAll()
                return nil
            }
            pendingFirstShake = nil
            lastGestureEmit = time
            let pitchValues = pitch.map(\.value)
            let yawValues = yaw.map(\.value)
            pitch.removeAll()
            yaw.removeAll()
            recordGesture(gesture, pitch: pitchValues, yaw: yawValues,
                          extraFields: ["gap": "\(gap)"])
            return .shake
        }

        diagnostics.record("gesture.shake_pending")
        pendingFirstShake = time
        pitch.removeAll()
        yaw.removeAll()
        return nil
    }

    public mutating func ingestTap(acceleration newAcceleration: Double,
                                   rotation newRotation: Double,
                                   time: TimeInterval) -> TapCommand? {
        acceleration.append((time, newAcceleration))
        rotation.append((time, newRotation))
        let cutoff = time - tapConfig.windowSeconds
        acceleration.removeAll { $0.time < cutoff }
        rotation.removeAll { $0.time < cutoff }

        recordTapSampleIfTracing(
            acceleration: newAcceleration,
            rotation: newRotation,
            time: time
        )

        guard tapDetectionEnabled,
              time - lastTapEmit > tapConfig.debounceSeconds else { return nil }

        if let first = pendingFirstTap,
           time - first > tapConfig.doubleTapWindowSeconds {
            diagnostics.record("tap.pending_expired", fields: [
                "gap_ms": Self.milliseconds(time - first),
                "pair_window_ms": Self.milliseconds(tapConfig.doubleTapWindowSeconds),
            ])
            pendingFirstTap = nil
        }

        let analysis = tapAnalyzer.analyze(
            accel: acceleration.map(\.value), rot: rotation.map(\.value)
        )
        let pairGap = pendingFirstTap.map { time - $0 }

        if newAcceleration >= analysis.elevatedLevel,
           tapDiagnosticCandidateStartedAt == nil {
            tapDiagnosticCandidateStartedAt = time
            tapDiagnosticBaselineWaitLogged = false
        }

        if analysis.rejection == .notReturnedToBaseline,
           !tapDiagnosticBaselineWaitLogged {
            var fields = tapDiagnosticFields(
                analysis,
                candidateDuration: tapDiagnosticCandidateStartedAt.map { time - $0 },
                pairGap: pairGap
            )
            fields["reason"] = TapAnalysis.Rejection.notReturnedToBaseline.rawValue
            diagnostics.record("tap.candidate_waiting", fields: fields)
            tapDiagnosticBaselineWaitLogged = true
        }

        let candidateDuration: TimeInterval?
        if tapDiagnosticCandidateStartedAt != nil,
           analysis.returnedToBaseline,
           analysis.rejection != .insufficientSamples {
            candidateDuration = tapDiagnosticCandidateStartedAt.map { time - $0 }
            tapDiagnosticCandidateStartedAt = nil
            tapDiagnosticBaselineWaitLogged = false
        } else {
            candidateDuration = nil
        }

        guard analysis.detected else {
            if let candidateDuration, let rejection = analysis.rejection {
                var fields = tapDiagnosticFields(
                    analysis,
                    candidateDuration: candidateDuration,
                    pairGap: pairGap
                )
                fields["reason"] = rejection.rawValue
                diagnostics.record("tap.candidate_rejected", fields: fields)
            }
            return nil
        }

        // A detection describes the one transient currently retained in the trailing
        // window. Consume that window immediately so the same physical impact cannot be
        // reconsidered on later samples and satisfy both halves of the double-tap pair.
        // The next confirmation must therefore contain a fresh acceleration spike.
        acceleration.removeAll()
        rotation.removeAll()

        if let first = pendingFirstTap {
            let gap = time - first
            guard gap >= tapConfig.minDoubleTapGap else {
                var fields = tapDiagnosticFields(
                    analysis,
                    candidateDuration: candidateDuration,
                    pairGap: gap
                )
                fields["reason"] = "double_tap_echo"
                fields["minimum_pair_gap_ms"] = Self.milliseconds(tapConfig.minDoubleTapGap)
                diagnostics.record("tap.rejected", fields: fields)
                return nil
            }
            pendingFirstTap = nil
            lastTapEmit = time
            diagnostics.record(
                "tap.detected",
                fields: tapDiagnosticFields(
                    analysis,
                    candidateDuration: candidateDuration,
                    pairGap: gap
                )
            )
            return .tap
        }

        var fields = tapDiagnosticFields(
            analysis,
            candidateDuration: candidateDuration,
            pairGap: nil
        )
        fields["pair_window_ms"] = Self.milliseconds(tapConfig.doubleTapWindowSeconds)
        fields["minimum_pair_gap_ms"] = Self.milliseconds(tapConfig.minDoubleTapGap)
        diagnostics.record("tap.pending", fields: fields)
        pendingFirstTap = time
        startTapSampleTrace(
            acceleration: newAcceleration,
            rotation: newRotation,
            time: time
        )
        return nil
    }

    /// Lateral (roll-axis) tilt with double-tilt pairing. Mirrors the double-nod flow:
    /// a first tilt arms a pending state, and only a second same-direction tilt within
    /// the pair window emits a command — a lone lateral lean never navigates.
    public mutating func ingestTilt(roll newRoll: Double, pitch newPitch: Double,
                                    yaw newYaw: Double,
                                    time: TimeInterval) -> TiltCommand? {
        tiltRoll.append((time, newRoll))
        tiltPitch.append((time, newPitch))
        tiltYaw.append((time, newYaw))
        let cutoff = time - tiltConfig.windowSeconds
        tiltRoll.removeAll { $0.time < cutoff }
        tiltPitch.removeAll { $0.time < cutoff }
        tiltYaw.removeAll { $0.time < cutoff }

        guard time - lastTiltEmit > tiltConfig.debounceSeconds else { return nil }

        if let pending = pendingFirstTilt,
           time - pending.time > tiltConfig.doubleTiltWindowSeconds {
            diagnostics.record("tilt.pending_expired", fields: [
                "direction": "\(pending.direction)",
            ])
            pendingFirstTilt = nil
        }

        guard let tilt = tiltAnalyzer.detect(
            roll: tiltRoll.map(\.value),
            pitch: tiltPitch.map(\.value),
            yaw: tiltYaw.map(\.value)
        ) else { return nil }

        // Consume the window so this excursion cannot re-trigger on later samples; the
        // confirming tilt must be a fresh motion.
        tiltRoll.removeAll()
        tiltPitch.removeAll()
        tiltYaw.removeAll()

        if let pending = pendingFirstTilt {
            guard pending.direction == tilt else {
                // Opposite direction restarts the pair rather than emitting a garbled
                // command — a left-right wobble is ambiguity, not navigation.
                diagnostics.record("tilt.pending_replaced", fields: [
                    "was": "\(pending.direction)", "now": "\(tilt)",
                ])
                pendingFirstTilt = (time, tilt)
                return nil
            }
            let gap = time - pending.time
            guard gap >= tiltConfig.minDoubleTiltGap else {
                diagnostics.record("tilt.rejected", fields: ["reason": "double_tilt_echo"])
                return nil
            }
            pendingFirstTilt = nil
            lastTiltEmit = time
            diagnostics.record("tilt.detected", fields: [
                "tilt": "\(tilt)", "gap": "\(gap)",
            ])
            return tilt
        }

        diagnostics.record("tilt.pending", fields: ["direction": "\(tilt)"])
        pendingFirstTilt = (time, tilt)
        return nil
    }

    /// Experimental motion-swipe channel; inert unless `swipeDetectionEnabled` and the
    /// samples carry per-axis data (magnitude-only adapters leave vectors at `.zero`).
    public mutating func ingestSwipe(_ sample: HeadMotionSample) -> MotionSwipeCommand? {
        guard swipeDetectionEnabled, sample.hasPerAxisData else { return nil }
        let time = sample.timestamp
        swipeAcceleration.append((time, sample.userAcceleration))
        swipeGravity.append((time, sample.gravity))
        swipeRotation.append((time, sample.rotationMagnitude))
        let cutoff = time - swipeConfig.windowSeconds
        swipeAcceleration.removeAll { $0.time < cutoff }
        swipeGravity.removeAll { $0.time < cutoff }
        swipeRotation.removeAll { $0.time < cutoff }

        guard time - lastSwipeEmit > swipeConfig.debounceSeconds else { return nil }
        guard let swipe = swipeAnalyzer.detect(
            acceleration: swipeAcceleration.map(\.value),
            gravity: swipeGravity.map(\.value),
            rotation: swipeRotation.map(\.value)
        ) else { return nil }

        // Consume the window: one drag, one command.
        swipeAcceleration.removeAll()
        swipeGravity.removeAll()
        swipeRotation.removeAll()
        lastSwipeEmit = time
        diagnostics.record("swipe.detected", fields: ["swipe": "\(swipe)"])
        return swipe
    }

    private func recordGesture(_ gesture: HeadGesture, pitch: [Double], yaw: [Double],
                               extraFields: [String: String] = [:]) {
        var fields: [String: String] = [
            "gesture": "\(gesture)",
            "p2p_pitch": "\((pitch.max() ?? 0) - (pitch.min() ?? 0))",
            "p2p_yaw": "\((yaw.max() ?? 0) - (yaw.min() ?? 0))",
            "samples": "\(pitch.count)",
        ]
        fields.merge(extraFields) { _, new in new }
        diagnostics.record("gesture.detected", fields: fields)
    }

    private func tapDiagnosticFields(
        _ analysis: TapAnalysis,
        candidateDuration: TimeInterval?,
        pairGap: TimeInterval?
    ) -> [String: String] {
        var fields: [String: String] = [
            "accel_samples": "\(analysis.accelerationSamples)",
            "baseline_level_g": Self.decimal(analysis.elevatedLevel),
            "elevated_samples": "\(analysis.elevatedSamples)",
            "max_rotation_rad_s": Self.decimal(analysis.maximumRotation),
            "max_spike_samples": "\(tapConfig.maxSpikeSamples)",
            "peak_g": Self.decimal(analysis.peakAcceleration),
            "returned_to_baseline": "\(analysis.returnedToBaseline)",
            "rotation_limit_rad_s": Self.decimal(tapConfig.rotationQuiet),
            "rotation_samples": "\(analysis.rotationSamples)",
            "tail_g": Self.decimal(analysis.tailAcceleration),
            "threshold_g": Self.decimal(tapConfig.amplitudeThreshold),
        ]
        if let candidateDuration {
            fields["candidate_duration_ms"] = Self.milliseconds(candidateDuration)
        }
        if let pairGap {
            fields["pair_gap_ms"] = Self.milliseconds(pairGap)
        }
        return fields
    }

    /// Records the raw motion values delivered by CoreMotion for a short, bounded period
    /// after a valid first tap. This is diagnostics only: it neither buffers extra samples
    /// for the analyzer nor changes any tap state or threshold.
    private mutating func startTapSampleTrace(
        acceleration: Double,
        rotation: Double,
        time: TimeInterval
    ) {
        tapSampleTraceStartedAt = time
        tapSampleTraceSampleCount = 0
        diagnostics.record("tap.sample_trace_started", fields: [
            "duration_ms": Self.milliseconds(Self.tapSampleTraceDurationSeconds),
            "start_timestamp_s": Self.timestamp(time),
            "threshold_g": Self.decimal(tapConfig.amplitudeThreshold),
        ])
        recordTapSampleIfTracing(
            acceleration: acceleration,
            rotation: rotation,
            time: time
        )
    }

    private mutating func recordTapSampleIfTracing(
        acceleration: Double,
        rotation: Double,
        time: TimeInterval
    ) {
        guard let startedAt = tapSampleTraceStartedAt else { return }
        let elapsed = time - startedAt
        guard elapsed >= 0 else { return }
        guard elapsed <= Self.tapSampleTraceDurationSeconds + 1e-9 else {
            diagnostics.record("tap.sample_trace_finished", fields: [
                "duration_ms": Self.milliseconds(Self.tapSampleTraceDurationSeconds),
                "samples": "\(tapSampleTraceSampleCount)",
            ])
            tapSampleTraceStartedAt = nil
            tapSampleTraceSampleCount = 0
            return
        }

        diagnostics.record("tap.sample", fields: [
            "acceleration_g": Self.decimal(acceleration),
            "elevated_level_g": Self.decimal(tapConfig.amplitudeThreshold * 0.5),
            "offset_ms": Self.milliseconds(elapsed),
            "rotation_rad_s": Self.decimal(rotation),
            "sample_index": "\(tapSampleTraceSampleCount)",
            "timestamp_s": Self.timestamp(time),
            "threshold_g": Self.decimal(tapConfig.amplitudeThreshold),
        ])
        tapSampleTraceSampleCount += 1
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func timestamp(_ value: TimeInterval) -> String {
        String(format: "%.6f", value)
    }

    private static func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.0f", max(0, value) * 1_000)
    }
}
