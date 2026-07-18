import Foundation
import TapQAppleAdapters
import TapQDetectionBaseline
#if canImport(CoreMotion)
import CoreMotion
#endif

// M0 spike (extended): confirm AirPods motion streams to a macOS process, measure the sample
// rate, and validate tap detection. A tap is a sharp |userAcceleration| transient — but a fast
// head turn accelerates the off-center earbud just as hard, so we also log |rotationRate|:
// during a tap the head isn't rotating (low |rot|), during a nod/shake/turn it is (high |rot|).
// That accel-high-AND-rotation-low pairing is the real discriminator, and Wavo already streams
// both signals. Run with AirPods (3/Pro/Max) connected:  swift run WavoMotionSpike

#if canImport(CoreMotion)
let manager = CMHeadphoneMotionManager()

print("CMHeadphoneMotionManager")
print("  isDeviceMotionAvailable: \(manager.isDeviceMotionAvailable)")
print("  authorizationStatus:     \(CMHeadphoneMotionManager.authorizationStatus().rawValue)  (0=notDetermined 1=restricted 2=denied 3=authorized)")

guard manager.isDeviceMotionAvailable else {
    print("\nNo headphone motion available. Connect compatible AirPods and try again.")
    exit(1)
}

var sampleCount = 0
var peakAccel = 0.0
var peakRot = 0.0
let spikeThreshold = 0.20   // g; |accel| display filter that surfaces candidate taps/transients
let rotQuietThreshold = 0.5 // rad/s; provisional — below this the head is ~still, so a strong
                            // |accel| spike reads as a tap rather than a head turn/shake
let start = Date()

manager.startDeviceMotionUpdates(to: .main) { motion, error in
    if let error {
        print("error: \(error.localizedDescription)")
        return
    }
    guard let motion else { return }
    sampleCount += 1

    // A tap is a sharp |userAcceleration| transient (g). But a fast head turn accelerates the
    // off-center earbud just as hard, so pair it with |rotationRate| (rad/s): a tap keeps the
    // head still (low |rot|); a nod/shake/turn does not (high |rot|). Track both peaks on EVERY
    // sample so a brief tap isn't lost between the throttled prints.
    let acc = motion.userAcceleration
    let accelMag = (acc.x * acc.x + acc.y * acc.y + acc.z * acc.z).squareRoot()
    let rot = motion.rotationRate
    let rotMag = (rot.x * rot.x + rot.y * rot.y + rot.z * rot.z).squareRoot()
    peakAccel = max(peakAccel, accelMag)
    peakRot = max(peakRot, rotMag)
    if accelMag >= spikeThreshold {
        let kind = rotMag < rotQuietThreshold ? "tap-like (head still)" : "turn/shake (head rotating)"
        print(String(format: "  >>> spike  t=%7.2f  |accel|=%.3f g  |rot|=%.2f rad/s  ", motion.timestamp, accelMag, rotMag) + kind)
    }

    if sampleCount % 5 == 0 {
        let a = motion.attitude
        print(String(format: "  t=%7.2f  pitch=%+.3f  yaw=%+.3f  roll=%+.3f  |accel|=%.3f  |rot|=%.2f", motion.timestamp, a.pitch, a.yaw, a.roll, accelMag, rotMag))
    }
}

let duration: TimeInterval = 30
print("\nStreaming for \(Int(duration))s. Keep the phases clean and separated:")
print("  1) sit still ~5s   2) tap an earbud firmly, head HELD STILL   3) nod & shake HARD, no taps\n")
RunLoop.main.run(until: Date().addingTimeInterval(duration))
manager.stopDeviceMotionUpdates()

let elapsed = Date().timeIntervalSince(start)
let hz = elapsed > 0 ? Double(sampleCount) / elapsed : 0
print(String(format: "\nDone. %d samples in %.1fs  →  ~%.0f Hz   peak |accel|=%.3f g   peak |rot|=%.2f rad/s", sampleCount, elapsed, hz, peakAccel, peakRot))
if sampleCount == 0 {
    print("Received ZERO samples. Likely causes: motion permission denied, AirPods not the active")
    print("audio route, or a CLI tool can't obtain motion auth — retry from the signed app bundle.")
}
#else
print("CoreMotion not available on this platform.")
#endif
