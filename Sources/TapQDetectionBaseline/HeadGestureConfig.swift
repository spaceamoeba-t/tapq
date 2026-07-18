import Foundation
import TapQContracts

/// Tunable thresholds for nod/shake detection. Defaults are starting points to be
/// refined against real AirPods data once the M0 spike confirms the sample stream.
public struct HeadGestureConfig: Sendable, Codable, Equatable {
    /// Minimum peak-to-peak amplitude (radians) of the dominant axis to count as a gesture.
    public var amplitudeThreshold: Double
    /// How much the dominant axis must exceed the other to disambiguate nod vs shake.
    public var dominanceRatio: Double
    /// Sliding window over which oscillation is measured.
    public var windowSeconds: Double
    /// Minimum direction reversals in the window (a real nod/shake repeats; a glance doesn't).
    public var minReversals: Int
    /// Ignore further gestures for this long after one fires.
    public var debounceSeconds: Double
    /// Minimum samples in the window before attempting detection.
    public var minSamples: Int
    /// Maximum interval between two consecutive nod detections for them to count as a
    /// double-nod. Must stay well above `minDoubleNodGap` and is deliberately independent
    /// of `debounceSeconds`, which only spaces out *emitted* gestures.
    public var doubleNodWindowSeconds: Double
    /// Minimum interval between the two nod detections — rejects an echo of the first
    /// nod's own motion re-triggering detection (mirrors `TapConfig.minDoubleTapGap`).
    public var minDoubleNodGap: Double

    public init(
        amplitudeThreshold: Double = 0.30,
        dominanceRatio: Double = 2.0,
        windowSeconds: Double = 1.2,
        minReversals: Int = 2,
        debounceSeconds: Double = 1.0,
        minSamples: Int = 6,
        doubleNodWindowSeconds: Double = 1.5,
        minDoubleNodGap: Double = 0.3
    ) {
        self.amplitudeThreshold = amplitudeThreshold
        self.dominanceRatio = dominanceRatio
        self.windowSeconds = windowSeconds
        self.minReversals = minReversals
        self.debounceSeconds = debounceSeconds
        self.minSamples = minSamples
        self.doubleNodWindowSeconds = doubleNodWindowSeconds
        self.minDoubleNodGap = minDoubleNodGap
    }

    /// Tolerant decoding: configs persisted before the double-nod pairing knobs existed
    /// must still decode (otherwise a saved calibration would be silently discarded).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amplitudeThreshold = try c.decode(Double.self, forKey: .amplitudeThreshold)
        dominanceRatio = try c.decode(Double.self, forKey: .dominanceRatio)
        windowSeconds = try c.decode(Double.self, forKey: .windowSeconds)
        minReversals = try c.decode(Int.self, forKey: .minReversals)
        debounceSeconds = try c.decode(Double.self, forKey: .debounceSeconds)
        minSamples = try c.decode(Int.self, forKey: .minSamples)
        doubleNodWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .doubleNodWindowSeconds) ?? 1.5
        minDoubleNodGap = try c.decodeIfPresent(Double.self, forKey: .minDoubleNodGap) ?? 0.3
    }
}
