import Foundation

/// A signed 3-axis motion quantity in the earbud's device frame (acceleration and
/// gravity in g, rotation rate in rad/s). Platform-neutral so the baseline pipeline
/// and capture tooling never depend on CoreMotion types.
public struct MotionVector: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public static let zero = MotionVector(x: 0, y: 0, z: 0)

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

/// One IMU sample reduced to the platform-neutral values consumed by TapQ's baseline
/// motion pipeline. Hardware adapters are responsible for producing these values.
///
/// Magnitude fields remain authoritative for the magnitude-based analyzers; the signed
/// per-axis vectors and roll exist for direction-aware detection (lateral tilts, swipe
/// direction) and for capture studies. Adapters that cannot supply per-axis data leave
/// the vectors at `.zero` and roll at 0, which every consumer must treat as "absent".
public struct HeadMotionSample: Sendable, Codable, Equatable {
    public let timestamp: TimeInterval
    public let pitch: Double
    public let yaw: Double
    /// Attitude roll in radians (lateral ear-toward-shoulder lean). 0 when the producing
    /// adapter predates per-axis capture.
    public let roll: Double
    public let accelerationMagnitude: Double
    public let rotationMagnitude: Double
    /// Signed user acceleration (gravity removed) in the earbud frame. `.zero` when absent.
    public let userAcceleration: MotionVector
    /// Signed rotation rate in the earbud frame. `.zero` when absent.
    public let rotationRate: MotionVector
    /// Gravity direction in the earbud frame; the reference for "up" in direction-aware
    /// analysis regardless of ear fit. `.zero` when absent.
    public let gravity: MotionVector

    /// Magnitude-only sample. Kept for adapters, calibration hosts, and recorded data
    /// that predate per-axis capture.
    public init(timestamp: TimeInterval, pitch: Double, yaw: Double,
                accelerationMagnitude: Double, rotationMagnitude: Double) {
        self.timestamp = timestamp
        self.pitch = pitch
        self.yaw = yaw
        self.roll = 0
        self.accelerationMagnitude = accelerationMagnitude
        self.rotationMagnitude = rotationMagnitude
        self.userAcceleration = .zero
        self.rotationRate = .zero
        self.gravity = .zero
    }

    /// Full per-axis sample. Magnitudes are derived from the vectors so they can never
    /// disagree with the signed data.
    public init(timestamp: TimeInterval, pitch: Double, yaw: Double, roll: Double,
                userAcceleration: MotionVector, rotationRate: MotionVector,
                gravity: MotionVector) {
        self.timestamp = timestamp
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.accelerationMagnitude = userAcceleration.magnitude
        self.rotationMagnitude = rotationRate.magnitude
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
    }

    /// Tolerant decoding: samples recorded before per-axis capture existed must still
    /// decode (mirrors `HeadGestureConfig`'s policy for persisted calibrations).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        pitch = try c.decode(Double.self, forKey: .pitch)
        yaw = try c.decode(Double.self, forKey: .yaw)
        roll = try c.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        accelerationMagnitude = try c.decode(Double.self, forKey: .accelerationMagnitude)
        rotationMagnitude = try c.decode(Double.self, forKey: .rotationMagnitude)
        userAcceleration = try c.decodeIfPresent(MotionVector.self, forKey: .userAcceleration) ?? .zero
        rotationRate = try c.decodeIfPresent(MotionVector.self, forKey: .rotationRate) ?? .zero
        gravity = try c.decodeIfPresent(MotionVector.self, forKey: .gravity) ?? .zero
    }

    /// True when the producing adapter supplied signed per-axis data, i.e. the sample can
    /// feed direction-aware analysis rather than only the magnitude-based analyzers.
    public var hasPerAxisData: Bool {
        gravity != .zero || userAcceleration != .zero || rotationRate != .zero
    }
}
