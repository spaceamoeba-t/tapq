import Foundation
import TapQContracts
import TapQPOSIXSupport
import TapQWireProtocol

/// The TapQ hook layout currently found in Codex's `hooks.json` file.
public enum CodexHookInstallationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case partial
}

/// Codex owns hook trust and records it against the exact hook-definition hash.
/// TapQ never reads, writes, or bypasses that trust decision.
public enum CodexHookTrustAction: Equatable, Sendable {
    /// No TapQ hook remains, so no Codex trust action applies.
    case none
    /// TapQ changed the definition. Codex will skip it until the user reviews it in `/hooks`.
    case reviewRequired
    /// The definition exists, but only Codex can report whether its current hash is trusted.
    case verifyInCodex

    public var command: String? {
        switch self {
        case .none: nil
        case .reviewRequired, .verifyInCodex: CodexHookInstaller.trustCommand
        }
    }

    public var message: String? {
        switch self {
        case .none:
            nil
        case .reviewRequired:
            CodexHookInstaller.trustInstruction
        case .verifyInCodex:
            "Run `/hooks` in Codex to verify that the current TapQ hook definitions are trusted."
        }
    }
}

/// A mutation or status result suitable for direct presentation by the CLI.
public struct CodexHookInstallationReport: Equatable, Sendable {
    public let status: CodexHookInstallationStatus
    public let didChange: Bool
    public let trustAction: CodexHookTrustAction

    public init(
        status: CodexHookInstallationStatus,
        didChange: Bool,
        trustAction: CodexHookTrustAction
    ) {
        self.status = status
        self.didChange = didChange
        self.trustAction = trustAction
    }
}

public enum CodexHookInstallerError: Error, LocalizedError, Equatable {
    case hooksMustBeObject
    case eventMustBeArray(String)

    public var errorDescription: String? {
        switch self {
        case .hooksMustBeObject:
            "The Codex hooks file has a non-object `hooks` value; TapQ left it unchanged."
        case .eventMustBeArray(let event):
            "The Codex hooks file has a non-array `hooks.\(event)` value; TapQ left it unchanged."
        }
    }
}

/// Idempotently merges TapQ's stable lifecycle hooks into `~/.codex/hooks.json` while
/// preserving unrelated top-level data, events, matcher groups, and handlers.
///
/// Every mutation snapshots the existing file first and publishes its replacement atomically.
/// Installing a new or changed definition does not make it trusted: Codex deliberately skips
/// non-managed command hooks until the user reviews their current definitions through `/hooks`.
public struct CodexHookInstaller {
    public static let defaultHookExecutableName = "tapq-codex-hook"
    public static let trustCommand = "/hooks"
    public static let trustInstruction =
        "Open Codex, run `/hooks`, review the TapQ hooks, and trust their current definitions. "
        + "Codex skips new or changed non-managed hooks until this step is complete."

    public let hooksURL: URL
    public let hookCommand: String
    private let fileWriter: any SecureAtomicFileWriting

    struct Spec {
        let event: String
        let matcher: String?
        let timeout: Double
    }

    /// Codex reports unified exec as `Bash` and patch mutations as `apply_patch`.
    static let permissionMatcher = "^(Bash|apply_patch)$"
    static let specs: [Spec] = [
        Spec(
            event: "PermissionRequest",
            matcher: permissionMatcher,
            timeout: InteractionBudget.hookTimeout
        ),
        Spec(event: "Stop", matcher: nil, timeout: InteractionBudget.hookTimeout),
    ]
    private static let managedEvents = Set(specs.map(\.event))

    public init(
        hooksURL: URL = CodexHookInstaller.codexHooksURL(),
        hookCommand: String = CodexHookInstaller.defaultHookExecutableName
    ) {
        self.hooksURL = hooksURL
        self.hookCommand = hookCommand
        self.fileWriter = POSIXSecureAtomicFileWriter()
    }

    init(
        hooksURL: URL,
        hookCommand: String,
        fileWriter: any SecureAtomicFileWriting
    ) {
        self.hooksURL = hooksURL
        self.hookCommand = hookCommand
        self.fileWriter = fileWriter
    }

    /// The user-level lifecycle-hook file Codex discovers by default.
    public static func codexHooksURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// Installs or repairs the TapQ layout. A changed hook hash always requires `/hooks` review.
    @discardableResult
    public func install() throws -> CodexHookInstallationReport {
        let original = try readRoot()
        var root = original
        var hooks = try hooksObject(in: root)

        for event in Self.managedEvents {
            let existing = try groups(for: event, in: hooks)
            let remaining = stripTapQ(from: existing).groups
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(remaining)
            }
        }

        for spec in Self.specs {
            var eventGroups = try groups(for: spec.event, in: hooks)
            eventGroups.append(group(for: spec))
            hooks[spec.event] = .array(eventGroups)
        }
        root["hooks"] = .object(hooks)

        let changed = root != original
        if changed {
            try writeRoot(root)
        }
        return CodexHookInstallationReport(
            status: .installed,
            didChange: changed,
            trustAction: changed ? .reviewRequired : .verifyInCodex
        )
    }

    /// Removes only TapQ-owned handlers and groups left empty by that removal.
    @discardableResult
    public func uninstall() throws -> CodexHookInstallationReport {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else {
            return .init(status: .notInstalled, didChange: false, trustAction: .none)
        }

        let original = try readRoot()
        var root = original
        guard root["hooks"] != nil else {
            return .init(status: .notInstalled, didChange: false, trustAction: .none)
        }
        var hooks = try hooksObject(in: root)
        var removedManagedHook = false

        for event in Self.managedEvents {
            let existing = try groups(for: event, in: hooks)
            let stripped = stripTapQ(from: existing)
            let remaining = stripped.groups
            removedManagedHook = removedManagedHook || stripped.didRemove
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(remaining)
            }
        }

        guard removedManagedHook else {
            return .init(
                status: installationStatus(in: original),
                didChange: false,
                trustAction: .none
            )
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = .object(hooks)
        }

        let changed = root != original
        if changed {
            try writeRoot(root)
        }
        return .init(
            status: installationStatus(in: root),
            didChange: changed,
            trustAction: .none
        )
    }

    public func isInstalled() -> Bool {
        installationStatus() == .installed
    }

    /// Reports the file layout. Hook trust itself is intentionally verifiable only in Codex.
    public func statusReport() -> CodexHookInstallationReport {
        let status = installationStatus()
        return .init(
            status: status,
            didChange: false,
            trustAction: status == .notInstalled ? .none : .verifyInCodex
        )
    }

    public func installationStatus() -> CodexHookInstallationStatus {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return .notInstalled }
        guard let root = try? readRoot() else { return .partial }
        return installationStatus(in: root)
    }

    // MARK: - Hook layout

    var shellCommand: String { Self.shellQuoted(hookCommand) }

    static func shellQuoted(_ command: String) -> String {
        "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func hooksObject(in root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value.objectValue else {
            throw CodexHookInstallerError.hooksMustBeObject
        }
        return hooks
    }

    private func groups(
        for event: String,
        in hooks: [String: JSONValue]
    ) throws -> [JSONValue] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value.arrayValue else {
            throw CodexHookInstallerError.eventMustBeArray(event)
        }
        return groups
    }

    private func group(for spec: Spec) -> JSONValue {
        let hook: JSONValue = .object([
            "type": .string("command"),
            "command": .string(shellCommand),
            "timeout": .number(spec.timeout),
        ])
        var group: [String: JSONValue] = ["hooks": .array([hook])]
        if let matcher = spec.matcher {
            group["matcher"] = .string(matcher)
        }
        return .object(group)
    }

    private func stripTapQ(
        from groups: [JSONValue]
    ) -> (groups: [JSONValue], didRemove: Bool) {
        var didRemove = false
        let remaining = groups.compactMap { element in
            guard var group = element.objectValue,
                  let handlers = group["hooks"]?.arrayValue else {
                return element
            }
            let kept = handlers.filter { !isManagedTapQHook($0) }
            didRemove = didRemove || kept.count != handlers.count
            if kept.isEmpty { return nil }
            group["hooks"] = .array(kept)
            return .object(group)
        }
        return (remaining, didRemove)
    }

    private func isCurrentHook(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        return command == shellCommand || command == hookCommand
    }

    private func isManagedTapQHook(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        if isCurrentHook(hook) { return true }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.defaultHookExecutableName
            || trimmed == Self.shellQuoted(Self.defaultHookExecutableName)
        {
            return true
        }

        guard let path = Self.directExecutablePath(from: command) else { return false }
        return Self.isRecognizedManagedHookPath(path)
    }

    private static func directExecutablePath(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path: String
        if trimmed.first == "'", trimmed.last == "'", trimmed.count >= 2 {
            path = String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "'\\''", with: "'")
        } else {
            path = trimmed
        }
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private static func isRecognizedManagedHookPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == defaultHookExecutableName else { return false }

        let normalized = url.path.lowercased()
        if normalized.contains("/library/application support/tapq/")
            || normalized.contains("/tapqruntime.app/contents/macos/")
        {
            return true
        }

        let components = url.pathComponents.map { $0.lowercased() }
        return components.indices.contains { index in
            components[index] == ".build"
                && components[..<index].contains { $0.hasPrefix("tapq") }
        }
    }

    private struct Registration: Hashable {
        let event: String
        let matcher: String?
        let command: String
        let type: String?
        let timeout: Double?
        let hasAsync: Bool
        let hasCondition: Bool
    }

    private func installationStatus(
        in root: [String: JSONValue]
    ) -> CodexHookInstallationStatus {
        guard let hooksValue = root["hooks"] else { return .notInstalled }
        guard let hooks = hooksValue.objectValue else { return .partial }

        for event in Self.managedEvents where hooks[event] != nil {
            guard hooks[event]?.arrayValue != nil else { return .partial }
        }

        let installed = managedRegistrations(in: hooks)
        guard !installed.isEmpty else { return .notInstalled }
        return installed == registrations(for: Self.specs) ? .installed : .partial
    }

    private func managedRegistrations(
        in hooks: [String: JSONValue]
    ) -> [Registration: Int] {
        var result: [Registration: Int] = [:]
        for event in Self.managedEvents {
            for groupValue in hooks[event]?.arrayValue ?? [] {
                guard let group = groupValue.objectValue else { continue }
                let matcher = group["matcher"]?.stringValue
                for hook in group["hooks"]?.arrayValue ?? [] where isManagedTapQHook(hook) {
                    let timeout: Double?
                    if case .number(let value)? = hook["timeout"] {
                        timeout = value
                    } else {
                        timeout = nil
                    }
                    result[Registration(
                        event: event,
                        matcher: matcher,
                        command: isCurrentHook(hook) ? shellCommand : "<stale>",
                        type: hook["type"]?.stringValue,
                        timeout: timeout,
                        hasAsync: hook["async"] != nil,
                        hasCondition: hook["if"] != nil
                    ), default: 0] += 1
                }
            }
        }
        return result
    }

    private func registrations(for specs: [Spec]) -> [Registration: Int] {
        var result: [Registration: Int] = [:]
        for spec in specs {
            result[Registration(
                event: spec.event,
                matcher: spec.matcher,
                command: shellCommand,
                type: "command",
                timeout: spec.timeout,
                hasAsync: false,
                hasCondition: false
            ), default: 0] += 1
        }
        return result
    }

    // MARK: - File I/O

    private func readRoot() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        let data = try Data(contentsOf: hooksURL)
        if data.isEmpty { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func writeRoot(_ root: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(root)
        data.append(0x0A)

        try prepareHooksDirectory()
        let previous = try hooksSnapshotIfPresent()
        if let previous {
            try fileWriter.write(
                previous.data,
                to: uniqueBackupURL(),
                mode: Self.backupMode(for: previous.mode),
                disposition: .createNew
            )
        }
        try fileWriter.write(
            data,
            to: hooksURL,
            mode: Self.hooksMode(for: previous?.mode),
            disposition: .replaceExisting
        )
    }

    private struct HooksSnapshot {
        let data: Data
        let mode: UInt16
    }

    private func hooksSnapshotIfPresent() throws -> HooksSnapshot? {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return nil }
        let data = try Data(contentsOf: hooksURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        return HooksSnapshot(data: data, mode: mode & 0o777)
    }

    private func uniqueBackupURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return hooksURL.appendingPathExtension(
            "tapq-backup-\(stamp)-\(UUID().uuidString)"
        )
    }

    private static func hooksMode(for existingMode: UInt16?) -> UInt16 {
        guard let existingMode else { return 0o600 }
        let ownerReadWrite = existingMode & 0o600
        return ownerReadWrite & 0o400 != 0 ? ownerReadWrite : 0o600
    }

    private static func backupMode(for existingMode: UInt16) -> UInt16 {
        existingMode & 0o600
    }

    private func prepareHooksDirectory() throws {
        let directory = hooksURL.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if isCanonicalCodexHooksURL {
                try restrictCanonicalDirectory(directory)
            }
            return
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: UInt16(0o700))]
        )
    }

    private var isCanonicalCodexHooksURL: Bool {
        hooksURL.standardizedFileURL.path
            == Self.codexHooksURL().standardizedFileURL.path
    }

    private func restrictCanonicalDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else { return }
        let current = number.uint16Value & 0o777
        let restricted = current & 0o700
        guard restricted != current else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: restricted)],
            ofItemAtPath: directory.path
        )
    }
}
