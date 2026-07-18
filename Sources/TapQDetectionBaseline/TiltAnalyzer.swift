import Foundation
import TapQContracts

/// Detects a head tilt by peak displacement from the starting position. Fires on the
/// dominant direction of motion even if the head returns to neutral afterward — matching
/// the natural quick-tilt gesture (pitch down, return to rest).
public struct TiltAnalyzer {
    public var displacementThreshold: Double
    public var minSamples: Int

    public init(displacementThreshold: Double = 0.10, minSamples: Int = 10) {
        self.displacementThreshold = displacementThreshold
        self.minSamples = minSamples
    }

    public func detect(pitch: [Double]) -> TiltCommand? {
        guard pitch.count >= minSamples,
              let first = pitch.first else { return nil }

        var peakDown = 0.0
        var peakUp = 0.0
        for p in pitch {
            let d = p - first
            if d < peakDown { peakDown = d }
            if d > peakUp { peakUp = d }
        }

        let downMag = abs(peakDown)
        let upMag = abs(peakUp)
        guard max(downMag, upMag) >= displacementThreshold else { return nil }

        if downMag >= displacementThreshold && upMag >= displacementThreshold {
            return nil
        }

        return downMag > upMag ? .tiltDown : .tiltUp
    }
}
