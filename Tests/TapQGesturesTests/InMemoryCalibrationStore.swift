import Foundation
import TapQGestures

/// A `CalibrationProfileStoring` that lives in memory.
///
/// Two knobs cover the cases that matter to the SDK: what is stored, and whether reading it
/// fails. `loadsFail` deliberately leaves `exists(_:)` answering `true` — that is the shape
/// of a corrupt or schema-rejected profile on disk, and the case where "fall back to
/// defaults" has to hold.
final class InMemoryCalibrationStore: CalibrationProfileStoring, @unchecked Sendable {
    struct LoadFailure: Error, Equatable {}
    struct SaveFailure: Error, Equatable {}

    private let lock = NSLock()
    private var gesture: TapQGestureCalibrationProfile?
    private var tap: TapQTapCalibrationProfile?
    private var loadsFail: Bool
    private var savesFail: Bool

    init(
        gesture: TapQGestureCalibrationProfile? = nil,
        tap: TapQTapCalibrationProfile? = nil,
        loadsFail: Bool = false,
        savesFail: Bool = false
    ) {
        self.gesture = gesture
        self.tap = tap
        self.loadsFail = loadsFail
        self.savesFail = savesFail
    }

    var storedGesture: TapQGestureCalibrationProfile? {
        lock.lock()
        defer { lock.unlock() }
        return gesture
    }

    var storedTap: TapQTapCalibrationProfile? {
        lock.lock()
        defer { lock.unlock() }
        return tap
    }

    func loadGesture() throws -> TapQGestureCalibrationProfile {
        lock.lock()
        defer { lock.unlock() }
        guard !loadsFail, let gesture else { throw LoadFailure() }
        return gesture
    }

    func loadTap() throws -> TapQTapCalibrationProfile {
        lock.lock()
        defer { lock.unlock() }
        guard !loadsFail, let tap else { throw LoadFailure() }
        return tap
    }

    func save(_ profile: TapQGestureCalibrationProfile) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !savesFail else { throw SaveFailure() }
        gesture = profile
    }

    func save(_ profile: TapQTapCalibrationProfile) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !savesFail else { throw SaveFailure() }
        tap = profile
    }

    func exists(_ kind: CalibrationProfileKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if loadsFail { return true }
        switch kind {
        case .gesture: return gesture != nil
        case .tap: return tap != nil
        // The storing protocol carries no wearer-speech load/save pair, so a fake built
        // against it can only ever report the profile absent.
        case .wearerSpeech: return false
        }
    }

    @discardableResult
    func reset(_ kind: CalibrationProfileKind) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .gesture:
            defer { gesture = nil }
            return gesture != nil
        case .tap:
            defer { tap = nil }
            return tap != nil
        case .wearerSpeech: return false
        }
    }
}
