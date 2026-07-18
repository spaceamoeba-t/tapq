import Foundation
import TapQContracts

/// Pure tap-calibration logic: given the acceleration captured during a few firm taps (and a
/// resting baseline), suggest a `TapConfig.amplitudeThreshold` that sits below the user's real
/// tap yet well above their resting jitter. Stateless and CoreMotion-free, mirroring
/// `GestureCalibrator`.
public enum TapCalibrator {
    /// Fraction of the user's tap strength the threshold is set to. Taps are sharp and brief,
    /// so requiring ~half the observed peak still fires comfortably while the rotation + shape
    /// gates reject head motion at this lower amplitude.
    static let tapFraction = 0.5
    /// A saved runtime threshold must clear resting acceleration jitter by this multiple.
    static let thresholdRestingHeadroom = 3.0
    /// Calibration acceptance is stricter than the saved runtime threshold: the observed
    /// tap must have this much separation from rest before it can tune approval input.
    static let usabilityRestingHeadroom = 4.0
    /// Absolute clamp. The floor prevents an unusually quiet baseline from producing a
    /// hair-trigger profile; the ceiling keeps a strong tap detectable.
    static let minThreshold = 0.05
    static let maxThreshold = 0.9
    /// Even with an exceptionally quiet baseline, require a measurable physical impulse.
    /// The old 0.3 g gate came from one 1.24 g hardware spike and rejected lower-amplitude
    /// AirPods streams even when their tap signal was cleanly separated from rest.
    static let minUsableTap = 0.06

    /// Explains both the observed signal and the safety floor used to accept or reject it.
    /// A stem squeeze is not expected to clear this assessment because CoreMotion exposes
    /// acceleration, not the AirPods force/capacitive control state.
    public struct Assessment: Sendable, Equatable {
        public let tapPeak: Double
        public let restingPeak: Double
        public let requiredPeak: Double

        public var isUsable: Bool { tapPeak >= requiredPeak }
    }

    public static func assessment(
        of samples: GestureCalibrationSamples
    ) -> Assessment {
        let tapPeak = samples.tapAccel.max() ?? 0
        let restingPeak = samples.restingAccel.max() ?? 0
        return Assessment(
            tapPeak: tapPeak,
            restingPeak: restingPeak,
            requiredPeak: max(minUsableTap, restingPeak * usabilityRestingHeadroom)
        )
    }

    /// Derives a config from captured tap samples, preserving every field of `base` except
    /// `amplitudeThreshold`. If no tap samples were captured, returns `base` unchanged.
    public static func suggestedTapConfig(
        from samples: GestureCalibrationSamples,
        base: TapConfig = .init()
    ) -> TapConfig {
        guard let tapPeak = samples.tapAccel.max() else { return base }
        let restingNoise = samples.restingAccel.max() ?? 0

        let fromTap = tapPeak * tapFraction
        let raised = max(fromTap, restingNoise * thresholdRestingHeadroom)
        let threshold = min(max(raised, minThreshold), maxThreshold)

        var config = base
        config.amplitudeThreshold = threshold
        return config
    }

    /// Whether the captured taps are strong enough, and separated enough from resting noise,
    /// that the suggested threshold can be trusted.
    public static func isTapUsable(_ samples: GestureCalibrationSamples) -> Bool {
        assessment(of: samples).isUsable
    }
}
