import Foundation
import TapQContracts

/// Pure single-tilt detector over windowed roll samples, with pitch/yaw passed alongside
/// for crosstalk gating. Separated from CoreMotion so the logic is unit-testable with
/// synthetic data, mirroring `GestureAnalyzer`.
///
/// A lateral tilt fires when, within the window:
///   1. roll deviates from the window's starting posture by at least
///      `amplitudeThreshold` toward exactly one side (both sides exceeded = ambiguous),
///   2. the roll swing dominates pitch and yaw by `dominanceRatio` (a nod or shake can
///      leak into roll; a deliberate lateral tilt is roll-dominant), and
///   3. roll has returned toward neutral at the window's end — the gesture completed.
///
/// Sign convention: positive roll deviation is reported as `.tiltRight`. If a platform's
/// attitude frame inverts this for worn earbuds, flip at the adapter boundary, not here.
///
/// The pitch-displacement tilt this replaces was retired for structural reasons: it
/// listened on the axis nod pairing uses and fired on single glances at the keyboard.
public struct TiltAnalyzer {
    public let config: TiltConfig

    public init(config: TiltConfig = .init()) {
        self.config = config
    }

    /// `roll`, `pitch`, and `yaw` cover the same trailing window, oldest first.
    public func detect(roll: [Double], pitch: [Double], yaw: [Double]) -> TiltCommand? {
        guard roll.count >= config.minSamples, let baseline = roll.first,
              let last = roll.last else { return nil }

        var peakRight = 0.0
        var peakLeft = 0.0
        for value in roll {
            let deviation = value - baseline
            if deviation > peakRight { peakRight = deviation }
            if -deviation > peakLeft { peakLeft = -deviation }
        }

        let dominant = max(peakRight, peakLeft)
        guard dominant >= config.amplitudeThreshold else { return nil }
        if min(peakRight, peakLeft) >= config.amplitudeThreshold { return nil }

        let rollStats = GestureAnalyzer.stats(roll)
        let pitchStats = GestureAnalyzer.stats(pitch)
        let yawStats = GestureAnalyzer.stats(yaw)
        guard rollStats.peakToPeak >= config.dominanceRatio * max(pitchStats.peakToPeak, 1e-6),
              rollStats.peakToPeak >= config.dominanceRatio * max(yawStats.peakToPeak, 1e-6)
        else { return nil }

        guard abs(last - baseline) <= config.amplitudeThreshold * config.returnFraction
        else { return nil }

        return peakRight > peakLeft ? .tiltRight : .tiltLeft
    }
}
