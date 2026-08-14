import Foundation
import TapQDetectionBaseline

public enum CalibrationProfileKind: String, Sendable, Equatable, CaseIterable {
    case gesture
    case tap
    case wearerSpeech = "wearer_speech"

    /// Human-readable name for CLI output. The raw value is the on-disk and JSON spelling
    /// and stays snake_case; `wearer_speech.capitalized` would print as "Wearer_speech".
    public var displayName: String {
        switch self {
        case .gesture: "Gesture"
        case .tap: "Tap"
        case .wearerSpeech: "Wearer speech"
        }
    }
}

public enum CalibrationStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchema(CalibrationProfileKind, Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let kind, let version):
            return "The \(kind.displayName.lowercased()) calibration profile schema \(version) is not supported by this TapQ version."
        }
    }
}

/// Stores gesture, tap and wearer-speech calibration as independent documents. A failed or
/// reset calibration of one input can therefore never discard another's valid profile.
public struct CalibrationStore: Sendable {
    public let gestureProfileURL: URL
    public let tapProfileURL: URL
    public let wearerSpeechProfileURL: URL

    public init(
        gestureProfileURL: URL,
        tapProfileURL: URL,
        wearerSpeechProfileURL: URL
    ) {
        self.gestureProfileURL = gestureProfileURL
        self.tapProfileURL = tapProfileURL
        self.wearerSpeechProfileURL = wearerSpeechProfileURL
    }

    public static func defaultProfileDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = nonempty(environment["TAPQ_CONFIG_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("TapQ", isDirectory: true)
        #else
        if let xdg = nonempty(environment["XDG_CONFIG_HOME"]) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("tapq", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("tapq", isDirectory: true)
        #endif
    }

    public static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CalibrationStore {
        let directory = defaultProfileDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return CalibrationStore(
            gestureProfileURL: directory.appendingPathComponent("gesture-calibration.json"),
            tapProfileURL: directory.appendingPathComponent("tap-calibration.json"),
            wearerSpeechProfileURL: directory
                .appendingPathComponent("wearer-speech-calibration.json")
        )
    }

    public func loadGesture() throws -> TapQGestureCalibrationProfile {
        let profile: TapQGestureCalibrationProfile = try decode(from: gestureProfileURL)
        guard profile.schemaVersion == TapQGestureCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(.gesture, profile.schemaVersion)
        }
        return profile
    }

    public func loadTap() throws -> TapQTapCalibrationProfile {
        let profile: TapQTapCalibrationProfile = try decode(from: tapProfileURL)
        guard profile.schemaVersion == TapQTapCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(.tap, profile.schemaVersion)
        }
        return profile
    }

    public func loadWearerSpeech() throws -> TapQWearerSpeechCalibrationProfile {
        let profile: TapQWearerSpeechCalibrationProfile = try decode(
            from: wearerSpeechProfileURL)
        guard profile.schemaVersion
            == TapQWearerSpeechCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(
                .wearerSpeech, profile.schemaVersion)
        }
        return profile
    }

    public func save(_ profile: TapQGestureCalibrationProfile) throws {
        guard profile.schemaVersion == TapQGestureCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(.gesture, profile.schemaVersion)
        }
        try encode(profile, to: gestureProfileURL)
    }

    public func save(_ profile: TapQTapCalibrationProfile) throws {
        guard profile.schemaVersion == TapQTapCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(.tap, profile.schemaVersion)
        }
        try encode(profile, to: tapProfileURL)
    }

    public func save(_ profile: TapQWearerSpeechCalibrationProfile) throws {
        guard profile.schemaVersion
            == TapQWearerSpeechCalibrationProfile.currentSchemaVersion else {
            throw CalibrationStoreError.unsupportedSchema(
                .wearerSpeech, profile.schemaVersion)
        }
        try encode(profile, to: wearerSpeechProfileURL)
    }

    public func exists(_ kind: CalibrationProfileKind) -> Bool {
        FileManager.default.fileExists(atPath: url(for: kind).path)
    }

    @discardableResult
    public func reset(_ kind: CalibrationProfileKind) throws -> Bool {
        let url = url(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    public func url(for kind: CalibrationProfileKind) -> URL {
        switch kind {
        case .gesture: gestureProfileURL
        case .tap: tapProfileURL
        case .wearerSpeech: wearerSpeechProfileURL
        }
    }

    private func decode<Profile: Decodable>(from url: URL) throws -> Profile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Profile.self, from: data)
    }

    private func encode<Profile: Encodable>(_ profile: Profile, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(profile)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
