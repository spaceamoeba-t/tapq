import Foundation
import TapQContracts
import TapQDetectionBaseline

/// Deterministic synthetic AirPods motion traces at the 25 Hz headphone sample rate.
///
/// Every waveform is a closed-form function of the sample index and a caller-supplied
/// start time: no `Date.now`, no randomness, so a failure always reproduces. Timestamps
/// are absolute and begin at `epoch` unless the caller says otherwise.
///
/// Amplitudes default to well above the threshold each channel measures — see the
/// per-generator notes — because a suite that generates at the margin reports config
/// drift and scheduler noise with the same red X.
///
/// Each generator drives only the axis its channel reads and leaves the others at rest,
/// so a nod trace cannot accidentally satisfy the tap or tilt analyzer. These traces are
/// shaped by construction and prove wiring, not real-world accuracy — the capture study
/// remains the accuracy gate for every IMU default.
enum TraceGenerators {
    /// Headphone motion arrives at ~25 Hz.
    static let sampleInterval: TimeInterval = 0.04
    /// Fixed, arbitrary, non-zero start time: nothing downstream may assume a zero origin.
    static let epoch: TimeInterval = 1_000

    /// Gravity for an upright, worn earbud. Present on every sample so traces carry
    /// per-axis data (`hasPerAxisData`) exactly as the CoreMotion adapter produces it.
    static let uprightGravity = MotionVector(x: 0, y: 0, z: -1)

    // MARK: - Head gestures (nod / shake)

    /// One nod excursion: a pitch zigzag of `amplitude` radians peak-to-peak.
    ///
    /// `amplitude` is directly comparable to `HeadGestureConfig.amplitudeThreshold`
    /// (0.30 rad), which the analyzer also measures peak-to-peak. The default is 2x it.
    /// A single excursion never emits — the pipeline pairs two into a nod.
    static func nod(startingAt start: TimeInterval = epoch,
                    amplitude: Double = 0.60,
                    duration: TimeInterval = 0.24) -> [HeadMotionSample] {
        oscillation(on: .pitch, startingAt: start, amplitude: amplitude, duration: duration)
    }

    /// One shake excursion: the same zigzag on yaw. See `nod(startingAt:amplitude:duration:)`.
    static func shake(startingAt start: TimeInterval = epoch,
                      amplitude: Double = 0.60,
                      duration: TimeInterval = 0.24) -> [HeadMotionSample] {
        oscillation(on: .yaw, startingAt: start, amplitude: amplitude, duration: duration)
    }

    /// The paired trace the pipeline turns into exactly one `.nod`.
    ///
    /// `separation` is the interval between the two excursion starts, and because both
    /// excursions are detected on their own final sample it is also the pair gap the
    /// pipeline measures. It must sit inside
    /// [`minDoubleNodGap`, `doubleNodWindowSeconds`] = [0.3 s, 1.5 s].
    static func doubleNod(startingAt start: TimeInterval = epoch,
                          amplitude: Double = 0.60,
                          separation: TimeInterval = 0.8) -> [HeadMotionSample] {
        nod(startingAt: start, amplitude: amplitude)
            + nod(startingAt: start + separation, amplitude: amplitude)
    }

    /// The paired trace the pipeline turns into exactly one `.shake`. `separation` must
    /// sit inside [`minDoubleShakeGap`, `doubleShakeWindowSeconds`] = [0.3 s, 1.5 s].
    static func doubleShake(startingAt start: TimeInterval = epoch,
                            amplitude: Double = 0.60,
                            separation: TimeInterval = 0.8) -> [HeadMotionSample] {
        shake(startingAt: start, amplitude: amplitude)
            + shake(startingAt: start + separation, amplitude: amplitude)
    }

    // MARK: - Lateral tilt

    /// One lateral (roll-axis) tilt excursion: out to `amplitude` radians and back to
    /// neutral, which is the shape `TiltAnalyzer` requires — it fires only once the head
    /// has returned. `amplitude` is peak deviation, comparable to
    /// `TiltConfig.amplitudeThreshold` (0.18 rad); the default is ~1.7x it.
    /// A single excursion never emits — the pipeline pairs two same-direction tilts.
    static func tilt(_ direction: TiltCommand,
                     startingAt start: TimeInterval = epoch,
                     amplitude: Double = 0.30,
                     duration: TimeInterval = 0.96) -> [HeadMotionSample] {
        let count = sampleCount(for: duration, minimum: 10)
        let sign = direction == .tiltRight ? 1.0 : -1.0
        return (0..<count).map { index in
            let phase = Double(index) / Double(count - 1)
            return sample(at: start + Double(index) * sampleInterval,
                          roll: sign * amplitude * sin(phase * .pi))
        }
    }

    /// The paired trace the pipeline turns into exactly one tilt command. `separation`
    /// is the interval between excursion starts and, since both excursions are detected
    /// at the same offset within themselves, also the pair gap: it must sit inside
    /// [`minDoubleTiltGap`, `doubleTiltWindowSeconds`] = [0.25 s, 1.6 s].
    static func doubleTilt(_ direction: TiltCommand,
                           startingAt start: TimeInterval = epoch,
                           amplitude: Double = 0.30,
                           separation: TimeInterval = 1.28) -> [HeadMotionSample] {
        tilt(direction, startingAt: start, amplitude: amplitude)
            + tilt(direction, startingAt: start + separation, amplitude: amplitude)
    }

    // MARK: - Tap

    /// One tap: a single-sample acceleration spike bracketed by rest, with the head still.
    ///
    /// `amplitude` is peak `|userAcceleration|` in g, comparable to
    /// `TapConfig.amplitudeThreshold` (0.45 g); the default is ~1.6x it. `rotation` is the
    /// concurrent `|rotationRate|` in rad/s and stays far below `TapConfig.rotationQuiet`
    /// (0.6) unless a caller is deliberately contaminating the spike.
    /// A single tap never emits — the pipeline pairs two into a double-tap.
    static func tap(startingAt start: TimeInterval = epoch,
                    amplitude: Double = 0.70,
                    rotation: Double = 0.05) -> [HeadMotionSample] {
        [0.0, amplitude, 0.0, 0.0].enumerated().map { index, level in
            sample(at: start + Double(index) * sampleInterval,
                   userAcceleration: MotionVector(x: 0, y: 0, z: level),
                   rotationRate: MotionVector(x: rotation, y: 0, z: 0))
        }
    }

    /// The paired trace the pipeline turns into exactly one `.tap`. `separation` is the
    /// interval between spike starts and also the pair gap, so it must sit inside
    /// [`minDoubleTapGap`, `doubleTapWindowSeconds`] = [0.1 s, 0.5 s].
    static func doubleTap(startingAt start: TimeInterval = epoch,
                          amplitude: Double = 0.70,
                          rotation: Double = 0.05,
                          separation: TimeInterval = 0.36) -> [HeadMotionSample] {
        tap(startingAt: start, amplitude: amplitude, rotation: rotation)
            + tap(startingAt: start + separation, amplitude: amplitude, rotation: rotation)
    }

    // MARK: - Rest

    /// A still, worn earbud: gravity only. Used to keep the stream continuous between
    /// gestures so pair windows and debounce expire the way they do on hardware.
    static func quiet(startingAt start: TimeInterval,
                      duration: TimeInterval) -> [HeadMotionSample] {
        let count = max(0, Int((duration / sampleInterval).rounded()))
        return (0..<count).map { sample(at: start + Double($0) * sampleInterval) }
    }

    // MARK: - Timeline

    /// Rebases a trace so its first sample lands on `start`, preserving every interval.
    /// Detection reads only differences, so a rebased trace detects identically.
    static func shift(_ trace: [HeadMotionSample],
                      to start: TimeInterval) -> [HeadMotionSample] {
        guard let first = trace.first else { return [] }
        let offset = start - first.timestamp
        return trace.map { $0.restamped(to: $0.timestamp + offset) }
    }

    // MARK: - Private

    private enum Axis { case pitch, yaw }

    /// The zigzag both head gestures share: rest, alternating peaks, rest. Four direction
    /// reversals at the default six samples, comfortably past `minReversals` (2), and a
    /// peak-to-peak swing of exactly `amplitude` on the driven axis with the other axis
    /// flat, which is what makes the analyzer's dominance test unambiguous.
    private static func oscillation(on axis: Axis,
                                    startingAt start: TimeInterval,
                                    amplitude: Double,
                                    duration: TimeInterval) -> [HeadMotionSample] {
        let count = sampleCount(for: duration, minimum: 6)
        let peak = amplitude / 2
        return (0..<count).map { index in
            let value: Double
            if index == 0 || index == count - 1 {
                value = 0
            } else {
                value = index.isMultiple(of: 2) ? -peak : peak
            }
            return sample(at: start + Double(index) * sampleInterval,
                          pitch: axis == .pitch ? value : 0,
                          yaw: axis == .yaw ? value : 0)
        }
    }

    /// Durations are quantized to the 25 Hz grid; `minimum` is the analyzer's `minSamples`
    /// for the channel, below which no waveform can be detected at all.
    private static func sampleCount(for duration: TimeInterval, minimum: Int) -> Int {
        max(minimum, Int((duration / sampleInterval).rounded()))
    }

    private static func sample(at time: TimeInterval,
                               pitch: Double = 0, yaw: Double = 0, roll: Double = 0,
                               userAcceleration: MotionVector = .zero,
                               rotationRate: MotionVector = .zero) -> HeadMotionSample {
        HeadMotionSample(timestamp: time, pitch: pitch, yaw: yaw, roll: roll,
                         userAcceleration: userAcceleration,
                         rotationRate: rotationRate,
                         gravity: uprightGravity)
    }
}

extension HeadMotionSample {
    /// The same sample on a new clock. Magnitude-only samples stay magnitude-only: the
    /// per-axis initializer derives magnitudes from vectors and would zero them.
    func restamped(to timestamp: TimeInterval) -> HeadMotionSample {
        guard hasPerAxisData else {
            return HeadMotionSample(timestamp: timestamp, pitch: pitch, yaw: yaw,
                                    accelerationMagnitude: accelerationMagnitude,
                                    rotationMagnitude: rotationMagnitude)
        }
        return HeadMotionSample(timestamp: timestamp, pitch: pitch, yaw: yaw, roll: roll,
                                userAcceleration: userAcceleration,
                                rotationRate: rotationRate,
                                gravity: gravity)
    }
}
