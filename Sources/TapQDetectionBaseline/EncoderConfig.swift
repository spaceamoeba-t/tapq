import Foundation
import TapQContracts

/// How an encoder backend participates in detection at composition time.
public enum EncoderMode: String, Sendable, Codable, Equatable {
    /// Encoder not consulted.
    case off
    /// Encoder runs on every sample and records detections as diagnostics, but the
    /// deterministic heuristics keep driving events. The validation posture: compare
    /// backends on live motion with zero behavior risk.
    case shadow
    /// Encoder detections drive events; heuristics run silently for comparison
    /// diagnostics and remain the automatic fallback when no model loads.
    case primary
}

/// Tunable thresholds for the encoder decision layer. Windowing values are runtime
/// knobs except `windowLength`, which is part of the model contract
/// (`EncoderFeatureLayout`) and validated at model load. Pairing values deliberately
/// mirror the heuristic configs so a backend swap never changes command timing.
public struct EncoderConfig: Sendable, Codable, Equatable {
    /// Samples per scored window; must equal the loaded model's window length.
    public var windowLength: Int
    /// Samples between consecutive scored windows (~0.32 s at 25 Hz).
    public var hopSamples: Int
    /// A gap between samples longer than this resets the window buffer.
    public var gapResetSeconds: Double
    /// Minimum top-class probability for a window to count as a detection.
    public var classThreshold: Double
    /// The top class must beat the runner-up by at least this much — near-ties are
    /// ambiguity, not detections.
    public var minMargin: Double
    /// Consecutive agreeing windows required before an atom is emitted. Two windows at
    /// the default hop ≈ 0.64 s of sustained agreement.
    public var agreementWindows: Int
    /// Minimum interval between emitted atoms — one physical motion spans several
    /// hops and must not emit twice.
    public var atomDebounceSeconds: Double
    /// Ignore further atoms for this long after a command fires (mirrors the
    /// heuristic pipelines' post-emission debounce).
    public var eventDebounceSeconds: Double
    /// Nod pairing, mirroring `HeadGestureConfig`. Tap has no pairing knobs: a `tap`
    /// atom is already the complete double-tap pattern (see `GestureClass`).
    public var nodPairWindowSeconds: Double
    public var minNodPairGap: Double
    /// Tilt pairing, mirroring `TiltConfig`.
    public var tiltPairWindowSeconds: Double
    public var minTiltPairGap: Double

    public init(
        windowLength: Int = EncoderFeatureLayout.windowLength,
        hopSamples: Int = 8,
        gapResetSeconds: Double = 0.5,
        classThreshold: Double = 0.7,
        minMargin: Double = 0.2,
        agreementWindows: Int = 2,
        atomDebounceSeconds: Double = 0.6,
        eventDebounceSeconds: Double = 1.0,
        nodPairWindowSeconds: Double = 1.5,
        minNodPairGap: Double = 0.3,
        tiltPairWindowSeconds: Double = 1.6,
        minTiltPairGap: Double = 0.25
    ) {
        self.windowLength = windowLength
        self.hopSamples = hopSamples
        self.gapResetSeconds = gapResetSeconds
        self.classThreshold = classThreshold
        self.minMargin = minMargin
        self.agreementWindows = agreementWindows
        self.atomDebounceSeconds = atomDebounceSeconds
        self.eventDebounceSeconds = eventDebounceSeconds
        self.nodPairWindowSeconds = nodPairWindowSeconds
        self.minNodPairGap = minNodPairGap
        self.tiltPairWindowSeconds = tiltPairWindowSeconds
        self.minTiltPairGap = minTiltPairGap
    }
}
