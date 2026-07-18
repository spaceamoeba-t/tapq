import Foundation
import TapQContracts

/// Hardware-independent interpretation of timestamped volume readings. A platform
/// adapter observes the system volume; this type owns thresholding and debounce state.
public struct VolumeSwipeAnalyzer {
    public var sensitivity: Double
    public var debounceSeconds: TimeInterval

    private var lastVolume: Double?
    private var lastEmitTime: TimeInterval = -.greatestFiniteMagnitude

    public init(sensitivity: Double = 0.02,
                debounceSeconds: TimeInterval = 0.4) {
        self.sensitivity = sensitivity
        self.debounceSeconds = debounceSeconds
    }

    public mutating func reset(initialVolume: Double? = nil) {
        lastVolume = initialVolume
        lastEmitTime = -.greatestFiniteMagnitude
    }

    public mutating func ingest(volume newVolume: Double,
                                at time: TimeInterval) -> VolumeSwipeCommand? {
        defer { lastVolume = newVolume }
        guard let lastVolume else { return nil }
        let delta = newVolume - lastVolume
        guard abs(delta) >= sensitivity else { return nil }
        guard time - lastEmitTime >= debounceSeconds else { return nil }
        lastEmitTime = time
        return delta > 0 ? .swipeUp : .swipeDown
    }
}
