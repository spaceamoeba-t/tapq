import Foundation

/// The closed label set of the TapQ-1 stage-1 encoder. `allCases` order is the model's
/// output-vector order.
///
/// Classes are gesture *atoms at window time-scale*. For motions longer than a window
/// (nod, tilt) an atom is one excursion and `EncoderMotionPipeline` pairs two atoms
/// deterministically, keeping the doubling false-positive filter structural. `tap` is
/// the exception: both transients of a double tap fit inside one window (≤0.5 s apart
/// vs a 1.28 s window), so `tap` means the complete double-tap pattern and training
/// labels must mark full double taps — lone bumps belong to `quiet`. `shake` is
/// inherently oscillatory and `swipe*` is a single sustained drag; both emit directly.
public enum GestureClass: String, CaseIterable, Sendable, Codable, Equatable {
    case quiet
    case nod
    case shake
    case tiltLeft = "tilt_left"
    case tiltRight = "tilt_right"
    case tap
    case swipeUp = "swipe_up"
    case swipeDown = "swipe_down"
}

/// The versioned feature contract between the Swift runtime and the Python training
/// pipeline (`ml/tapq1/layout.py` mirrors these values). A trained model embeds the
/// version in its metadata and `CoreMLMotionScorer` refuses to load a mismatch, so the
/// two sides can never drift silently. Any change to channels, order, scaling, or
/// window length is a new version.
public enum EncoderFeatureLayout {
    public static let version = "tapq1-features-v1"

    /// Per-sample channels, in input order. Signed per-axis data only — attitude is
    /// deliberately absent (yaw drifts with body heading; gravity plus rotation rate
    /// carries the same orientation information without the drift).
    public static let channelNames = [
        "user_acceleration_x", "user_acceleration_y", "user_acceleration_z",
        "rotation_rate_x", "rotation_rate_y", "rotation_rate_z",
        "gravity_x", "gravity_y", "gravity_z",
    ]
    public static var channelCount: Int { channelNames.count }

    /// Samples per window: 1.28 s at the ~25 Hz headphone motion rate — long enough
    /// for one gesture atom, short enough that double-gesture pairing stays responsive.
    public static let windowLength = 32

    /// Fixed physical full-scale values used to normalize each channel into [-1, 1].
    /// Fixed rather than dataset statistics so training and runtime cannot skew.
    public static let accelerationFullScale = 2.0
    public static let rotationFullScale = 8.0

    /// One scaled, clipped feature row for a sample, in `channelNames` order.
    public static func featureRow(for sample: HeadMotionSample) -> [Float] {
        [
            scaled(sample.userAcceleration.x, fullScale: accelerationFullScale),
            scaled(sample.userAcceleration.y, fullScale: accelerationFullScale),
            scaled(sample.userAcceleration.z, fullScale: accelerationFullScale),
            scaled(sample.rotationRate.x, fullScale: rotationFullScale),
            scaled(sample.rotationRate.y, fullScale: rotationFullScale),
            scaled(sample.rotationRate.z, fullScale: rotationFullScale),
            scaled(sample.gravity.x, fullScale: 1.0),
            scaled(sample.gravity.y, fullScale: 1.0),
            scaled(sample.gravity.z, fullScale: 1.0),
        ]
    }

    private static func scaled(_ value: Double, fullScale: Double) -> Float {
        Float(min(1.0, max(-1.0, value / fullScale)))
    }
}

/// Creator-defined metadata keys a TapQ-1 model must carry so the runtime can verify
/// it speaks the same contract. Written by `ml/tapq1/export.py`.
public enum TapQ1ModelMetadata {
    public static let featureLayoutKey = "com.tapq.tapq1.feature_layout"
    public static let classesKey = "com.tapq.tapq1.classes"
    public static let windowLengthKey = "com.tapq.tapq1.window_length"

    /// The exact class list a conforming model must declare.
    public static var expectedClasses: String {
        GestureClass.allCases.map(\.rawValue).joined(separator: ",")
    }
}

/// One fixed-size encoder input: `features` is time-major, oldest sample first, each
/// row in `EncoderFeatureLayout.channelNames` order.
public struct EncoderInputWindow: Sendable, Equatable {
    public let features: [[Float]]
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(features: [[Float]], startTime: TimeInterval, endTime: TimeInterval) {
        self.features = features
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Per-class probabilities for one window. Probabilities are expected to come from an
/// in-model softmax; absent classes read as zero.
public struct GestureScores: Sendable, Equatable {
    public let values: [GestureClass: Float]

    public init(values: [GestureClass: Float]) {
        self.values = values
    }

    public func probability(of gestureClass: GestureClass) -> Float {
        values[gestureClass] ?? 0
    }

    /// Classes ranked by descending probability; ties broken by `allCases` order so
    /// ranking is deterministic.
    public var ranked: [(gestureClass: GestureClass, probability: Float)] {
        GestureClass.allCases
            .map { ($0, probability(of: $0)) }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.1 != rhs.element.1
                    ? lhs.element.1 > rhs.element.1
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// A model backend that scores one encoder window. Production is Core ML in
/// `TapQAppleAdapters`; tests use scripted scorers. Throwing signals a backend
/// failure — the pipeline records it and skips the window.
public protocol MotionWindowScoring {
    func score(_ window: EncoderInputWindow) throws -> GestureScores
}

/// Accumulates per-axis samples into fixed-size encoder windows with a hop, resetting
/// across stream gaps so a window never spans a disconnect.
public struct EncoderWindowBuilder {
    public let windowLength: Int
    public let hopSamples: Int
    public let gapResetSeconds: TimeInterval

    private var rows: [[Float]] = []
    private var timestamps: [TimeInterval] = []
    private var samplesSinceEmit = 0
    private var hasEmitted = false

    public init(
        windowLength: Int = EncoderFeatureLayout.windowLength,
        hopSamples: Int = 8,
        gapResetSeconds: TimeInterval = 0.5
    ) {
        self.windowLength = max(1, windowLength)
        self.hopSamples = max(1, hopSamples)
        self.gapResetSeconds = gapResetSeconds
    }

    /// Ingests one sample; returns a window when one becomes due. Samples without
    /// per-axis data are ignored — a zero-filled row would look like fabricated
    /// stillness to the model, which is worse than a shorter buffer.
    public mutating func push(_ sample: HeadMotionSample) -> EncoderInputWindow? {
        guard sample.hasPerAxisData else { return nil }
        if let last = timestamps.last,
           sample.timestamp < last || sample.timestamp - last > gapResetSeconds {
            reset()
        }

        rows.append(EncoderFeatureLayout.featureRow(for: sample))
        timestamps.append(sample.timestamp)
        if rows.count > windowLength {
            rows.removeFirst(rows.count - windowLength)
            timestamps.removeFirst(timestamps.count - windowLength)
        }
        samplesSinceEmit += 1

        guard rows.count == windowLength,
              !hasEmitted || samplesSinceEmit >= hopSamples else { return nil }
        samplesSinceEmit = 0
        hasEmitted = true
        return EncoderInputWindow(
            features: rows,
            startTime: timestamps.first ?? sample.timestamp,
            endTime: sample.timestamp
        )
    }

    public mutating func reset() {
        rows.removeAll()
        timestamps.removeAll()
        samplesSinceEmit = 0
        hasEmitted = false
    }
}
