import Foundation
import TapQContracts
import TapQDetectionBaseline
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Abstracts the single `CMHeadphoneMotionManager` behind `HeadGestureDetector` so tests
/// can drive the full detection pipeline with synthetic samples — and so a test process
/// can never reach CoreMotion at all: starting (or even stopping) real motion updates
/// inside an unsigned xctest host trips a TCC motion-permission abort on AirPods-paired
/// machines. A nil sample or a non-nil error signals stream loss (disconnect included).
@MainActor protocol HeadphoneMotionSource: AnyObject {
    var isDeviceMotionAvailable: Bool { get }
    func startUpdates(_ handler: @escaping @MainActor (HeadMotionSample?, Error?) -> Void)
    func stopUpdates()
}

/// Non-CoreMotion platforms: motion is simply unavailable.
@MainActor final class UnavailableMotionSource: HeadphoneMotionSource {
    var isDeviceMotionAvailable: Bool { false }
    func startUpdates(_ handler: @escaping @MainActor (HeadMotionSample?, Error?) -> Void) {}
    func stopUpdates() {}
}

#if canImport(CoreMotion)
enum HeadphoneMotionSourceError: LocalizedError {
    case disconnected

    var errorDescription: String? {
        switch self {
        case .disconnected: return "headphone motion connection interrupted"
        }
    }
}

/// The production source: owns the one real `CMHeadphoneMotionManager` (a second manager
/// would conflict) and refuses to touch it in a test process.
@MainActor final class HeadphoneMotionManagerSource: NSObject, HeadphoneMotionSource {
    /// XCTest linked into the process means an unsigned test host whose TCC motion check
    /// would abort the process — report unavailable and never call into CoreMotion.
    /// (Creating the manager and reading availability are safe; start/stop are not.)
    static let isTestProcess = NSClassFromString("XCTestCase") != nil

    private let manager = CMHeadphoneMotionManager()
    private var handler: (@MainActor (HeadMotionSample?, Error?) -> Void)?
    /// Identifies the callback installed by the current logical subscription. CoreMotion
    /// may deliver a callback from a just-stopped window after the next window has begun;
    /// that callback must never reach the new interaction.
    private var subscriptionGeneration: UInt64 = 0

    override init() {
        super.init()
        manager.delegate = self
    }

    var isDeviceMotionAvailable: Bool {
        !Self.isTestProcess && manager.isDeviceMotionAvailable
    }

    func startUpdates(_ handler: @escaping @MainActor (HeadMotionSample?, Error?) -> Void) {
        guard !Self.isTestProcess else { return }
        self.handler = handler
        subscriptionGeneration &+= 1
        startManagerUpdates(handler: handler, generation: subscriptionGeneration)
    }

    /// An explicit detector start always asks CoreMotion for a fresh callback, matching
    /// the proven per-window lifecycle. In particular, do not trust
    /// `isDeviceMotionActive` here: it can remain true briefly after a stop even though
    /// the old callback will no longer produce samples.
    private func startManagerUpdates(
        handler: @escaping @MainActor (HeadMotionSample?, Error?) -> Void,
        generation: UInt64
    ) {
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self,
                      self.subscriptionGeneration == generation,
                      self.handler != nil else { return }
                guard let motion, error == nil else {
                    handler(nil, error)
                    return
                }
                handler(HeadMotionSample(timestamp: motion.timestamp,
                                         pitch: motion.attitude.pitch,
                                         yaw: motion.attitude.yaw,
                                         accelerationMagnitude: Self.magnitude(motion.userAcceleration),
                                         rotationMagnitude: Self.magnitude(motion.rotationRate)),
                        nil)
            }
        }
    }

    func stopUpdates() {
        guard !Self.isTestProcess else { return }
        // Invalidate the callback before asking CoreMotion to stop. A callback already
        // queued on the main operation queue will then fail its generation check.
        subscriptionGeneration &+= 1
        handler = nil
        manager.stopDeviceMotionUpdates()
    }

    private func resumeUpdatesAfterConnection() {
        // Delegate reconnects are different from explicit starts: they should only
        // resume a live subscription whose manager is genuinely inactive.
        guard let handler, !manager.isDeviceMotionActive else { return }
        subscriptionGeneration &+= 1
        startManagerUpdates(handler: handler, generation: subscriptionGeneration)
    }

    private func handleDisconnectAfterDelegateCallback() {
        // Delegate delivery crosses onto MainActor. By the time this queued callback
        // runs, CoreMotion may already have reported the headphones available again and
        // a new subscription may be live. Never forward that stale disconnect into the
        // current interaction. Actual callback errors retain their per-subscription
        // generation check in `startManagerUpdates` above.
        guard !manager.isDeviceMotionAvailable, let handler else { return }
        handler(nil, HeadphoneMotionSourceError.disconnected)
    }

    private static func magnitude(_ v: CMAcceleration) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    private static func magnitude(_ v: CMRotationRate) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }
}

extension HeadphoneMotionManagerSource: CMHeadphoneMotionManagerDelegate {
    public nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.resumeUpdatesAfterConnection() }
    }

    public nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.handleDisconnectAfterDelegateCallback() }
    }
}
#endif
