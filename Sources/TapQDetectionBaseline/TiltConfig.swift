import Foundation
import TapQContracts

/// Tunable thresholds for lateral (roll-axis) tilt detection. A tilt is a single
/// ear-toward-shoulder excursion that returns to neutral; the pipeline pairs two
/// same-direction tilts into a command, mirroring double-nod/double-tap. Defaults are
/// conservative uncalibrated starting points pending a per-axis capture study.
public struct TiltConfig: Sendable, Codable, Equatable {
    /// Minimum roll deviation (radians) from the window's starting posture to count as a
    /// deliberate lateral tilt (~10°).
    public var amplitudeThreshold: Double
    /// How much the roll peak-to-peak must exceed pitch and yaw peak-to-peak — rejects
    /// roll crosstalk from vigorous nods and shakes.
    public var dominanceRatio: Double
    /// The window-end deviation must fall below `amplitudeThreshold * returnFraction`,
    /// so a tilt fires only after the head returns toward neutral (completed gesture),
    /// never while the head is parked sideways.
    public var returnFraction: Double
    /// Sliding window over which one tilt excursion is judged.
    public var windowSeconds: Double
    /// Minimum samples in the window before attempting detection.
    public var minSamples: Int
    /// Ignore further tilts for this long after a double-tilt fires.
    public var debounceSeconds: Double
    /// Maximum interval between two same-direction tilts for them to pair.
    public var doubleTiltWindowSeconds: Double
    /// Minimum interval between the two tilts — rejects an echo of the first tilt's own
    /// return motion (mirrors `minDoubleNodGap` / `minDoubleTapGap`).
    public var minDoubleTiltGap: Double

    public init(
        amplitudeThreshold: Double = 0.18,
        dominanceRatio: Double = 1.6,
        returnFraction: Double = 0.4,
        windowSeconds: Double = 0.9,
        minSamples: Int = 8,
        debounceSeconds: Double = 1.0,
        doubleTiltWindowSeconds: Double = 1.6,
        minDoubleTiltGap: Double = 0.25
    ) {
        self.amplitudeThreshold = amplitudeThreshold
        self.dominanceRatio = dominanceRatio
        self.returnFraction = returnFraction
        self.windowSeconds = windowSeconds
        self.minSamples = minSamples
        self.debounceSeconds = debounceSeconds
        self.doubleTiltWindowSeconds = doubleTiltWindowSeconds
        self.minDoubleTiltGap = minDoubleTiltGap
    }
}
