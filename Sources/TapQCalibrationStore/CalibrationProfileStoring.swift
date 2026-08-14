import TapQDetectionBaseline

/// Abstraction over calibration-profile persistence so an embedding app can
/// substitute its own storage (Keychain, iCloud, sandbox container) for the
/// default on-disk store.
public protocol CalibrationProfileStoring: Sendable {
    /// Reads the stored nod/shake profile, throwing when it is absent or unreadable.
    func loadGesture() throws -> TapQGestureCalibrationProfile

    /// Reads the stored tap profile, throwing when it is absent or unreadable.
    func loadTap() throws -> TapQTapCalibrationProfile

    /// Persists a nod/shake profile, replacing any previously stored one.
    func save(_ profile: TapQGestureCalibrationProfile) throws

    /// Persists a tap profile, replacing any previously stored one.
    func save(_ profile: TapQTapCalibrationProfile) throws

    /// Reports whether a profile of `kind` is currently stored.
    func exists(_ kind: CalibrationProfileKind) -> Bool

    /// Discards the stored profile of `kind`, returning whether one was present.
    @discardableResult
    func reset(_ kind: CalibrationProfileKind) throws -> Bool
}

extension CalibrationStore: CalibrationProfileStoring {}
