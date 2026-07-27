import Foundation
import TapQContracts

/// Tunable thresholds for motion-based ear/earbud swipe detection. A swipe is the shape
/// `TapAnalyzer` rejects as `spike_too_wide`: a sustained, gentle acceleration plateau
/// with a still head, rather than a tap's brief sharp spike. Experimental — defaults are
/// placeholders pending a per-axis capture study; the channel ships disabled.
public struct SwipeConfig: Sendable, Codable, Equatable {
    /// Minimum `|userAcceleration|` (g) for a sample to count as part of the drag. Drags
    /// are gentler than taps, so this sits well below `TapConfig.amplitudeThreshold`.
    public var elevatedLevel: Double
    /// Peak `|userAcceleration|` (g) above which the transient is tap-class, not a drag.
    public var peakCeiling: Double
    /// The window's max `|rotationRate|` (rad/s) must stay below this — the head was
    /// still, separating a drag from head-gesture motion (same gate as taps).
    public var rotationQuiet: Double
    /// Contiguous elevated run length, in samples, that reads as a drag (~160–560 ms at
    /// 25 Hz). Shorter is tap territory; longer is an adjustment or sustained motion.
    public var minElevatedSamples: Int
    public var maxElevatedSamples: Int
    /// Trailing window over which the drag and its rotation are judged.
    public var windowSeconds: Double
    /// Minimum samples in the window before attempting detection.
    public var minSamples: Int
    /// Ignore further swipes for this long after one fires.
    public var debounceSeconds: Double
    /// The gravity-aligned component of the drag's mean acceleration must exceed the
    /// residual (non-vertical) component by this ratio for a direction to be reported.
    public var directionDominance: Double

    public init(
        elevatedLevel: Double = 0.12,
        peakCeiling: Double = 0.45,
        rotationQuiet: Double = 0.6,
        minElevatedSamples: Int = 4,
        maxElevatedSamples: Int = 14,
        windowSeconds: Double = 0.8,
        minSamples: Int = 8,
        debounceSeconds: Double = 0.8,
        directionDominance: Double = 1.4
    ) {
        self.elevatedLevel = elevatedLevel
        self.peakCeiling = peakCeiling
        self.rotationQuiet = rotationQuiet
        self.minElevatedSamples = minElevatedSamples
        self.maxElevatedSamples = maxElevatedSamples
        self.windowSeconds = windowSeconds
        self.minSamples = minSamples
        self.debounceSeconds = debounceSeconds
        self.directionDominance = directionDominance
    }
}

/// Pure swipe detector over a trailing window of per-axis samples. Separated from
/// CoreMotion so the logic is unit-testable with synthetic data, mirroring
/// `GestureAnalyzer` and `TapAnalyzer`.
///
/// A swipe fires when, within the window:
///   1. `|accel|` holds a contiguous elevated run of drag length (not a tap's brief
///      spike, not a long adjustment),
///   2. the peak stays below tap amplitude and rotation stays quiet (head still),
///   3. `|accel|` has returned below the elevated level at the window's end, and
///   4. the mean drag acceleration projects dominantly onto gravity — up (against
///      gravity) is `.swipeUp`, down is `.swipeDown`. No dominant vertical component
///      means no direction can be trusted, so nothing fires.
///
/// Direction is a heuristic pending capture-study validation: the bud's reaction to a
/// finger drag need not align with the drag itself. Presence detection (conditions 1–3)
/// is the load-bearing part.
public struct SwipeAnalyzer {
    public let config: SwipeConfig

    public init(config: SwipeConfig = .init()) {
        self.config = config
    }

    /// `acceleration` and `gravity` are per-axis samples over the same trailing window,
    /// oldest first; `rotation` is `|rotationRate|` over that window.
    public func detect(acceleration: [MotionVector], gravity: [MotionVector],
                       rotation: [Double]) -> MotionSwipeCommand? {
        guard acceleration.count >= config.minSamples,
              rotation.count >= config.minSamples else { return nil }

        let magnitudes = acceleration.map(\.magnitude)
        guard let peak = magnitudes.max(), peak < config.peakCeiling,
              let maxRotation = rotation.max(), maxRotation < config.rotationQuiet,
              let tail = magnitudes.last, tail < config.elevatedLevel else { return nil }

        guard let run = longestElevatedRun(magnitudes),
              run.length >= config.minElevatedSamples,
              run.length <= config.maxElevatedSamples else { return nil }

        // Mean drag acceleration and mean gravity over the elevated run only, so quiet
        // lead-in/lead-out samples don't dilute the direction estimate.
        let slice = run.range
        let meanAcceleration = Self.mean(Array(acceleration[slice]))
        let meanGravity = Self.mean(Array(gravity[slice]))
        let gravityMagnitude = meanGravity.magnitude
        guard gravityMagnitude > 1e-6 else { return nil }

        // Gravity points down, so a positive component against gravity is "up".
        let vertical = -(meanAcceleration.x * meanGravity.x
            + meanAcceleration.y * meanGravity.y
            + meanAcceleration.z * meanGravity.z) / gravityMagnitude
        let total = meanAcceleration.magnitude
        let residual = max(0, total * total - vertical * vertical).squareRoot()
        guard abs(vertical) >= config.directionDominance * max(residual, 1e-6)
        else { return nil }

        return vertical > 0 ? .swipeUp : .swipeDown
    }

    private func longestElevatedRun(
        _ magnitudes: [Double]
    ) -> (range: Range<Int>, length: Int)? {
        var best: Range<Int>?
        var currentStart: Int?
        for (index, value) in magnitudes.enumerated() {
            if value >= config.elevatedLevel {
                if currentStart == nil { currentStart = index }
            } else if let start = currentStart {
                if best == nil || (index - start) > best!.count { best = start..<index }
                currentStart = nil
            }
        }
        if let start = currentStart {
            let end = magnitudes.count
            if best == nil || (end - start) > best!.count { best = start..<end }
        }
        guard let range = best else { return nil }
        return (range, range.count)
    }

    private static func mean(_ vectors: [MotionVector]) -> MotionVector {
        guard !vectors.isEmpty else { return .zero }
        let count = Double(vectors.count)
        return MotionVector(
            x: vectors.reduce(0) { $0 + $1.x } / count,
            y: vectors.reduce(0) { $0 + $1.y } / count,
            z: vectors.reduce(0) { $0 + $1.z } / count
        )
    }
}
