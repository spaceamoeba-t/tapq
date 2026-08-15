import Foundation
import TapQContextBaseline

public enum AutoAnswerPolicyStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The auto-answer policy schema \(version) is not supported by this TapQ version."
        }
    }
}

/// Reads and writes `auto-answer-policy.json`, the one file that says which approvals TapQ
/// may answer without asking.
///
/// It lives beside the calibration profiles and resolves its directory through the same
/// `CalibrationStore.defaultProfileDirectory` — shared rather than reimplemented, so
/// `TAPQ_CONFIG_DIR` cannot ever point calibration at one directory and this at another.
/// A user who moves their TapQ config moves all of it.
///
/// Two behaviors carry the safety of the whole feature:
///
/// - **Absent means defaults.** No file is the overwhelmingly common case (the file is
///   optional; the flag is what turns delegation on) and it has to mean the strict
///   defaults, not "unconfigured, so allow".
/// - **Malformed means throw.** A policy file that does not parse, or that names a schema
///   this build does not know, aborts `serve` exactly as a malformed calibration profile
///   does. Falling back to defaults on a broken file would be the more forgiving choice
///   and the wrong one: the user wrote that file to *narrow* what gets auto-answered — a
///   typo in their `never_auto_tools` list must not silently widen it back out.
public struct AutoAnswerPolicyStore {
    public static let fileName = "auto-answer-policy.json"

    public let policyURL: URL

    public init(policyURL: URL) {
        self.policyURL = policyURL
    }

    public static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AutoAnswerPolicyStore {
        let directory = CalibrationStore.defaultProfileDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return AutoAnswerPolicyStore(
            policyURL: directory.appendingPathComponent(fileName)
        )
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: policyURL.path)
    }

    /// The effective policy: what is on disk, or the defaults when nothing is.
    ///
    /// The absent case is checked by path rather than by catching the read error, so a
    /// directory that exists but cannot be read still throws instead of quietly resolving
    /// to defaults.
    public func load() throws -> AutoAnswerPolicy {
        guard exists() else { return .defaults }
        let data = try Data(contentsOf: policyURL)
        let policy = try JSONDecoder().decode(AutoAnswerPolicy.self, from: data)
        guard policy.schemaVersion == AutoAnswerPolicy.currentSchemaVersion else {
            throw AutoAnswerPolicyStoreError.unsupportedSchema(policy.schemaVersion)
        }
        return policy
    }

    /// Writes the policy the way every other TapQ config file is written: pretty-printed
    /// with sorted keys because a person edits it by hand, atomically because a truncated
    /// policy file would abort the next `serve`, and `0600` because it names what may
    /// happen without the user watching.
    public func save(_ policy: AutoAnswerPolicy) throws {
        guard policy.schemaVersion == AutoAnswerPolicy.currentSchemaVersion else {
            throw AutoAnswerPolicyStoreError.unsupportedSchema(policy.schemaVersion)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: policyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(policy)
        data.append(0x0A)
        try data.write(to: policyURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: policyURL.path
        )
    }
}
