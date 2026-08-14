import Foundation

/// A `HeadphoneMotionSource` you drive yourself.
///
/// Three uses, all of which need detection to run without hardware:
///
/// - **Tests.** The production CoreMotion source reports itself unavailable inside an
///   XCTest host on purpose, so this is how a test exercises the real pipeline — the same
///   analyzers, the same pairing windows, the same motion-loss lifecycle — from synthetic
///   samples.
/// - **Capture replay.** Feed a recorded session back through `play(_:rate:)` to see what
///   the detector would have done, or to compare backends after a config change.
/// - **Demos.** Drive a UI from a canned gesture without asking anyone to wear AirPods.
///
/// Sending before `startUpdates` (or after `stopUpdates`) is a no-op: with no subscription
/// there is nobody to deliver to, which mirrors the real source.
@MainActor public final class ScriptedMotionSource: HeadphoneMotionSource {
    public typealias Handler = @MainActor (HeadMotionSample?, Error?) -> Void

    /// Whether the detector should believe headphone motion exists. Settable so a test can
    /// make the connection appear or disappear mid-session.
    public var isDeviceMotionAvailable: Bool

    /// How many subscriptions have been opened, and closed, since this source was created.
    /// The detector restarts its subscription in some recovery paths, so these are how a
    /// test asserts lifecycle rather than only output.
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    private var handler: Handler?

    /// - Parameter available: the initial value of `isDeviceMotionAvailable`. Pass `false`
    ///   to exercise the "no headphones connected" path.
    public init(available: Bool = true) {
        self.isDeviceMotionAvailable = available
    }

    public func startUpdates(_ handler: @escaping Handler) {
        startCount += 1
        self.handler = handler
    }

    public func stopUpdates() {
        stopCount += 1
        handler = nil
    }

    /// Delivers one sample to the live subscription.
    public func send(_ sample: HeadMotionSample) {
        handler?(sample, nil)
    }

    /// Delivers a stream fault. The detector treats this as an interruption and only
    /// reports an outage if no valid sample arrives before its grace period expires, so a
    /// single `fail` does not immediately produce `motionLost`.
    public func fail(_ error: Error) {
        handler?(nil, error)
    }

    /// Replays samples at the pace their own timestamps describe.
    ///
    /// Gaps come from the recording, not from a fixed rate, so a capture that stuttered
    /// replays with its stutter — which is the point when the thing under test is a
    /// time-windowed detector. `rate` scales playback speed: `2.0` replays twice as fast,
    /// `0.5` half as fast. Non-positive deltas are delivered immediately.
    ///
    /// Suspends until the last sample has been sent; cancelling the surrounding task stops
    /// the replay.
    public func play(_ samples: [HeadMotionSample], rate: Double = 1.0) async {
        let speed = max(rate, .leastNonzeroMagnitude)
        var previousTimestamp: TimeInterval?
        for sample in samples {
            if Task.isCancelled { return }
            if let previousTimestamp {
                let delta = (sample.timestamp - previousTimestamp) / speed
                if delta > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delta * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }
            previousTimestamp = sample.timestamp
            send(sample)
        }
    }
}
