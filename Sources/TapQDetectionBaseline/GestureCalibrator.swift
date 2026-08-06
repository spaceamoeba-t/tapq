import Foundation
import TapQGestureContracts

/// Attitude streams captured during a one-time calibration: a few seconds of rest, a
/// sample nod (pitch swing), and a sample shake (yaw swing). The calibrator turns these
/// into a tuned `HeadGestureConfig` so detection adapts to how big a given person's
/// gestures actually are.
public struct GestureCalibrationSamples: Sendable, Equatable {
    public var restingPitch: [Double]
    public var restingYaw: [Double]
    public var nodPitch: [Double]
    public var shakeYaw: [Double]
    /// `|userAcceleration|` (g) captured during the resting and tap phases — used by
    /// `TapCalibrator`. Defaulted so gesture-only callers and tests are unaffected.
    public var restingAccel: [Double]
    public var tapAccel: [Double]

    public init(
        restingPitch: [Double] = [],
        restingYaw: [Double] = [],
        nodPitch: [Double],
        shakeYaw: [Double],
        restingAccel: [Double] = [],
        tapAccel: [Double] = []
    ) {
        self.restingPitch = restingPitch
        self.restingYaw = restingYaw
        self.nodPitch = nodPitch
        self.shakeYaw = shakeYaw
        self.restingAccel = restingAccel
        self.tapAccel = tapAccel
    }
}

/// Pure calibration logic: given captured samples, suggest an `amplitudeThreshold` that
/// sits comfortably below the user's real gesture amplitude yet above their resting jitter.
/// Stateless and CoreMotion-free so it can be unit-tested with synthetic streams.
public enum GestureCalibrator {
    /// Fraction of the weakest observed gesture the threshold is set to. A real gesture
    /// produces the full peak-to-peak swing, so requiring ~20% of it detects a gentle,
    /// comfortable nod/shake; the reversal + dominance + windowing rules still reject
    /// incidental motion at this lower amplitude.
    static let gestureFraction = 0.2
    /// The threshold must clear resting jitter by at least this multiple.
    static let restingHeadroom = 1.5
    /// Absolute clamp so a degenerate capture can't make gestures impossible or trivial.
    /// The floor sits below `minUsableGesture` so the gentlest accepted calibration gesture
    /// still clears the detection threshold.
    static let minThreshold = 0.05
    static let maxThreshold = 0.60
    /// A gesture peak-to-peak below this (radians, ~4.6°) is too weak to calibrate against.
    static let minUsableGesture = 0.08

    /// Derives a config from captured samples, preserving every field of `base` except
    /// `amplitudeThreshold`. Always returns a usable config; check `isUsable` first if you
    /// want to warn the user that their captured gestures were too small to trust.
    public static func suggestedConfig(
        from samples: GestureCalibrationSamples,
        base: HeadGestureConfig = .init()
    ) -> HeadGestureConfig {
        let nod = GestureAnalyzer.stats(samples.nodPitch).peakToPeak
        let shake = GestureAnalyzer.stats(samples.shakeYaw).peakToPeak
        let weakestGesture = min(nod, shake)
        let restingNoise = max(
            GestureAnalyzer.stats(samples.restingPitch).peakToPeak,
            GestureAnalyzer.stats(samples.restingYaw).peakToPeak)

        let fromGesture = weakestGesture * gestureFraction
        let raised = max(fromGesture, restingNoise * restingHeadroom)
        let threshold = min(max(raised, minThreshold), maxThreshold)

        var config = base
        config.amplitudeThreshold = threshold
        return config
    }

    /// Whether the captured gestures are strong enough, and separated enough from resting
    /// noise, that the suggested threshold can be trusted.
    public static func isUsable(_ samples: GestureCalibrationSamples) -> Bool {
        let nod = GestureAnalyzer.stats(samples.nodPitch).peakToPeak
        let shake = GestureAnalyzer.stats(samples.shakeYaw).peakToPeak
        let restingNoise = max(
            GestureAnalyzer.stats(samples.restingPitch).peakToPeak,
            GestureAnalyzer.stats(samples.restingYaw).peakToPeak)

        guard nod >= minUsableGesture, shake >= minUsableGesture else { return false }
        return min(nod, shake) >= restingNoise * 2
    }
}
