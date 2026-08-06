import Foundation
import TapQGestureContracts

/// Pure nod-vs-shake classifier over windowed attitude samples. Separated from CoreMotion
/// so the detection logic is unit-testable with synthetic data.
public struct GestureAnalyzer {
    public let config: HeadGestureConfig

    public init(config: HeadGestureConfig = .init()) {
        self.config = config
    }

    public func detect(pitch: [Double], yaw: [Double]) -> HeadGesture? {
        guard pitch.count >= config.minSamples, yaw.count >= config.minSamples else { return nil }
        let p = Self.stats(pitch)
        let y = Self.stats(yaw)

        if p.peakToPeak >= config.amplitudeThreshold,
           p.peakToPeak >= config.dominanceRatio * max(y.peakToPeak, 1e-6),
           p.reversals >= config.minReversals {
            return .nod
        }
        if y.peakToPeak >= config.amplitudeThreshold,
           y.peakToPeak >= config.dominanceRatio * max(p.peakToPeak, 1e-6),
           y.reversals >= config.minReversals {
            return .shake
        }
        return nil
    }

    static func stats(_ values: [Double]) -> (peakToPeak: Double, reversals: Int) {
        guard let minValue = values.min(), let maxValue = values.max() else { return (0, 0) }
        let peakToPeak = maxValue - minValue
        // Ignore tiny jitter relative to the swing so noise near turning points isn't
        // miscounted as extra reversals.
        let epsilon = max(1e-4, peakToPeak * 0.05)

        var reversals = 0
        var lastSign = 0
        var previous = values[0]
        for value in values.dropFirst() {
            let delta = value - previous
            if abs(delta) > epsilon {
                let sign = delta > 0 ? 1 : -1
                if lastSign != 0, sign != lastSign { reversals += 1 }
                lastSign = sign
            }
            previous = value
        }
        return (peakToPeak, reversals)
    }
}
