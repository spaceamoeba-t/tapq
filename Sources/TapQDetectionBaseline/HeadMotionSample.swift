import Foundation

/// One IMU sample reduced to the platform-neutral values consumed by TapQ's baseline
/// motion pipeline. Hardware adapters are responsible for producing these values.
public struct HeadMotionSample: Sendable, Codable, Equatable {
    public let timestamp: TimeInterval
    public let pitch: Double
    public let yaw: Double
    public let accelerationMagnitude: Double
    public let rotationMagnitude: Double

    public init(timestamp: TimeInterval, pitch: Double, yaw: Double,
                accelerationMagnitude: Double, rotationMagnitude: Double) {
        self.timestamp = timestamp
        self.pitch = pitch
        self.yaw = yaw
        self.accelerationMagnitude = accelerationMagnitude
        self.rotationMagnitude = rotationMagnitude
    }
}
