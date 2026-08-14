import Foundation

/// Why a capture could not be turned into a calibration profile.
///
/// Rejection is the point: a profile derived from a weak or ambiguous capture would lower
/// the detection threshold toward the wearer's own resting jitter, and every gesture after
/// that would be guesswork.
public enum CalibrationServiceError: Error, LocalizedError, Equatable {
    /// The nod and shake swings were too small, or too close to resting motion, to
    /// separate a deliberate gesture from noise.
    case gestureCaptureUnusable
    /// No acceleration spike sufficiently separated from resting motion was observed. The
    /// assessment carries the measured peaks and the floor they had to clear, so a host can
    /// tell the wearer what was actually seen rather than "try again".
    case tapCaptureUnusable(TapCalibrator.Assessment)

    public var errorDescription: String? {
        switch self {
        case .gestureCaptureUnusable:
            return "Gesture calibration was too weak or too close to resting motion. "
                + "Recapture with clean, distinct nods and shakes."
        case .tapCaptureUnusable(let assessment):
            return "Tap calibration did not observe an acceleration spike sufficiently "
                + "separated from resting motion (tap peak \(Self.g(assessment.tapPeak)), "
                + "resting peak \(Self.g(assessment.restingPeak)), required "
                + "\(Self.g(assessment.requiredPeak))). Recapture with the head held still, "
                + "tapping the outside body of an earbud with a fingertip — a stem squeeze "
                + "is a force-sensor event and produces no acceleration transient."
        }
    }

    private static func g(_ value: Double) -> String {
        String(format: "%.3f g", value)
    }
}

extension GestureCalibrationSamples {
    /// Sorts one capture session's samples into calibrator input by phase.
    ///
    /// Each array is the samples recorded while the wearer was doing that one thing:
    /// sitting still, nodding, shaking, tapping. Only the axis each phase actually
    /// constrains is extracted — pitch from the nod, yaw from the shake, acceleration
    /// magnitude from rest and tap — which is exactly the reduction the `tapq` CLI performs
    /// before handing a capture to `GestureCalibrator` and `TapCalibrator`.
    public init(
        resting: [HeadMotionSample],
        nod: [HeadMotionSample],
        shake: [HeadMotionSample],
        tap: [HeadMotionSample] = []
    ) {
        self.init(
            restingPitch: resting.map(\.pitch),
            restingYaw: resting.map(\.yaw),
            nodPitch: nod.map(\.pitch),
            shakeYaw: shake.map(\.yaw),
            restingAccel: resting.map(\.accelerationMagnitude),
            tapAccel: tap.map(\.accelerationMagnitude)
        )
    }
}

/// Turns a calibration capture into saved profiles.
///
/// Thin by construction: the thresholds come from `GestureCalibrator` and `TapCalibrator`,
/// the quality gates are theirs, and persistence is the store's. What this type adds is the
/// order of operations the `tapq` CLI uses — derive from the *previously saved* config so
/// non-threshold tuning survives recalibration, refuse to save an unusable capture, and
/// keep the two profiles independent so a failed tap calibration can never discard a valid
/// nod/shake one.
///
/// Collect the samples with `GestureSession.motionSamples()`, bucket them by phase, and
/// build `GestureCalibrationSamples` with the phase initializer above.
///
/// ```swift
/// let service = CalibrationService(store: CalibrationStore.defaultStore())
/// let samples = GestureCalibrationSamples(resting: resting, nod: nod, shake: shake, tap: tap)
/// let profile = try service.calibrateGestures(from: samples)
/// ```
public struct CalibrationService: Sendable {
    private let store: any CalibrationProfileStoring

    public init(store: any CalibrationProfileStoring) {
        self.store = store
    }

    /// Derives, validates, and saves a nod/shake profile.
    ///
    /// Only `amplitudeThreshold` is derived; every other field is inherited from the
    /// currently stored profile, or from `HeadGestureConfig()` when none is stored or it
    /// cannot be read.
    ///
    /// - Throws: `CalibrationServiceError.gestureCaptureUnusable` when the capture fails
    ///   the calibrator's quality gate — nothing is written in that case — or whatever the
    ///   store throws while saving.
    @discardableResult
    public func calibrateGestures(
        from samples: GestureCalibrationSamples
    ) throws -> TapQGestureCalibrationProfile {
        guard GestureCalibrator.isUsable(samples) else {
            throw CalibrationServiceError.gestureCaptureUnusable
        }
        let base = (try? store.loadGesture().config) ?? HeadGestureConfig()
        let profile = TapQGestureCalibrationProfile(
            config: GestureCalibrator.suggestedConfig(from: samples, base: base),
            quality: GestureCalibrationQuality(
                restingSampleCount: samples.restingPitch.count,
                nodSampleCount: samples.nodPitch.count,
                shakeSampleCount: samples.shakeYaw.count
            )
        )
        try store.save(profile)
        return profile
    }

    /// Derives, validates, and saves a tap profile.
    ///
    /// Acceptance is stricter than the threshold it writes: the observed tap must clear
    /// resting acceleration by a wider margin than the saved threshold will require, so a
    /// profile is never built from a capture that only just separated.
    ///
    /// - Throws: `CalibrationServiceError.tapCaptureUnusable` carrying the measured
    ///   assessment when the capture fails that gate — nothing is written in that case —
    ///   or whatever the store throws while saving.
    @discardableResult
    public func calibrateTap(
        from samples: GestureCalibrationSamples
    ) throws -> TapQTapCalibrationProfile {
        let assessment = TapCalibrator.assessment(of: samples)
        guard assessment.isUsable else {
            throw CalibrationServiceError.tapCaptureUnusable(assessment)
        }
        let base = (try? store.loadTap().config) ?? TapConfig()
        let profile = TapQTapCalibrationProfile(
            config: TapCalibrator.suggestedTapConfig(from: samples, base: base),
            quality: TapCalibrationQuality(
                restingSampleCount: samples.restingAccel.count,
                tapSampleCount: samples.tapAccel.count,
                restingAccelerationPeak: assessment.restingPeak,
                tapAccelerationPeak: assessment.tapPeak
            )
        )
        try store.save(profile)
        return profile
    }
}
