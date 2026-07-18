import Foundation
import TapQContracts

/// Tunable thresholds for AirPod tap detection. A tap is a sharp `userAcceleration` spike
/// while the head is *not* rotating; the rotation gate is what separates a tap from a
/// vigorous head shake, whose turnaround produces comparable acceleration. The default is
/// a conservative uncalibrated fallback; `amplitudeThreshold` is normally adapted to the
/// observed tap-to-rest separation by `TapCalibrator`.
public struct TapConfig: Sendable, Codable, Equatable {
    /// Minimum `|userAcceleration|` (g) of the spike to count as a tap.
    public var amplitudeThreshold: Double
    /// The window's max `|rotationRate|` (rad/s) must stay below this — i.e. the head was
    /// still around the spike. Windowed (not instantaneous) so a shake's single low-rot
    /// turnaround sample, flanked by high rotation, is still rejected.
    public var rotationQuiet: Double
    /// Trailing window over which the spike, its rotation, and its shape are judged.
    public var windowSeconds: Double
    /// Ignore further taps for this long after a double-tap fires.
    public var debounceSeconds: Double
    /// Maximum interval between two consecutive taps for them to count as a double-tap.
    public var doubleTapWindowSeconds: Double
    /// Minimum interval between first and second tap — rejects false double-taps from a
    /// single continuous motion (e.g. a head tilt generating two acceleration spikes).
    public var minDoubleTapGap: Double
    /// Minimum samples in the window before attempting detection.
    public var minSamples: Int
    /// Max samples allowed above half the amplitude threshold — caps the elevated region so
    /// a sustained acceleration plateau (a shake) is rejected while a brief tap passes.
    public var maxSpikeSamples: Int

    public init(
        amplitudeThreshold: Double = 0.45,
        rotationQuiet: Double = 0.6,
        windowSeconds: Double = 0.25,
        debounceSeconds: Double = 0.8,
        doubleTapWindowSeconds: Double = 0.5,
        minDoubleTapGap: Double = 0.1,
        minSamples: Int = 4,
        maxSpikeSamples: Int = 4
    ) {
        self.amplitudeThreshold = amplitudeThreshold
        self.rotationQuiet = rotationQuiet
        self.windowSeconds = windowSeconds
        self.debounceSeconds = debounceSeconds
        self.doubleTapWindowSeconds = doubleTapWindowSeconds
        self.minDoubleTapGap = minDoubleTapGap
        self.minSamples = minSamples
        self.maxSpikeSamples = maxSpikeSamples
    }
}
