import Foundation
import TapQContracts

struct TapAnalysis: Sendable, Equatable {
    enum Rejection: String, Sendable, Equatable {
        case insufficientSamples = "insufficient_samples"
        case belowAmplitude = "below_amplitude"
        case rotationNotQuiet = "rotation_not_quiet"
        case spikeTooWide = "spike_too_wide"
        case notReturnedToBaseline = "not_returned_to_baseline"
    }

    let rejection: Rejection?
    let accelerationSamples: Int
    let rotationSamples: Int
    let peakAcceleration: Double
    let maximumRotation: Double
    let elevatedSamples: Int
    let tailAcceleration: Double
    let elevatedLevel: Double

    var detected: Bool { rejection == nil }
    var returnedToBaseline: Bool { tailAcceleration < elevatedLevel }
}

/// Pure tap detector over a trailing window of acceleration/rotation magnitudes. Separated
/// from CoreMotion so the logic is unit-testable with synthetic data, mirroring
/// `GestureAnalyzer`.
///
/// A tap fires when, within the window:
///   1. peak `|accel|` clears `amplitudeThreshold` (a real spike happened),
///   2. max `|rot|` stays under `rotationQuiet` (the head was still — rejects shake
///      turnarounds, whose lone low-rot sample is flanked by high rotation),
///   3. the elevated region is *brief* (few samples above half-threshold, not a plateau), and
///   4. `|accel|` has returned to baseline at the window's end — so we fire just after the
///      spike subsides rather than on a rising plateau.
public struct TapAnalyzer {
    public let config: TapConfig

    /// Fraction of the amplitude threshold that counts a sample as "elevated" for the
    /// brevity check and the returned-to-baseline check.
    private static let elevatedFraction = 0.5

    public init(config: TapConfig = .init()) {
        self.config = config
    }

    /// `accel` and `rot` are `|userAcceleration|` (g) and `|rotationRate|` (rad/s) over the
    /// same trailing window, oldest first. Returns true when the window ends in a tap.
    public func detect(accel: [Double], rot: [Double]) -> Bool {
        analyze(accel: accel, rot: rot).detected
    }

    /// Produces the same decision as `detect` plus generic signal metrics for diagnostics.
    /// Keeping assessment separate from logging leaves policy and thresholds unchanged.
    func analyze(accel: [Double], rot: [Double]) -> TapAnalysis {
        let peak = accel.max() ?? 0
        let maximumRotation = rot.max() ?? 0
        let elevatedLevel = config.amplitudeThreshold * Self.elevatedFraction
        let elevated = accel.lazy.filter { $0 >= elevatedLevel }.count
        let tail = accel.last ?? 0

        let rejection: TapAnalysis.Rejection?
        if accel.count < config.minSamples || rot.count < config.minSamples {
            rejection = .insufficientSamples
        } else if peak < config.amplitudeThreshold {
            rejection = .belowAmplitude
        } else if maximumRotation >= config.rotationQuiet {
            // Windowed rotation gate: the head must be still across the whole neighborhood.
            rejection = .rotationNotQuiet
        } else if elevated > config.maxSpikeSamples {
            // Brevity: a tap is a short transient, not a sustained plateau.
            rejection = .spikeTooWide
        } else if tail >= elevatedLevel {
            // Returned to baseline: fire just after the spike, never on its rising edge.
            rejection = .notReturnedToBaseline
        } else {
            rejection = nil
        }

        return TapAnalysis(
            rejection: rejection,
            accelerationSamples: accel.count,
            rotationSamples: rot.count,
            peakAcceleration: peak,
            maximumRotation: maximumRotation,
            elevatedSamples: elevated,
            tailAcceleration: tail,
            elevatedLevel: elevatedLevel
        )
    }
}
