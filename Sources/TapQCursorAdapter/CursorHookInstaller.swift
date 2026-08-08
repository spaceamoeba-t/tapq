import Foundation
import TapQContracts
import TapQPOSIXSupport
import TapQWireProtocol

/// The TapQ hook layout currently found in Cursor's `hooks.json` file.
public enum CursorHookInstallationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case partial
}

/// A mutation or status result suitable for direct presentation by the CLI.
public struct CursorHookInstallationReport: Equatable, Sendable {
    public let status: CursorHookInstallationStatus
    public let didChange: Bool

    public init(status: CursorHookInstallationStatus, didChange: Bool) {
        self.status = status
        self.didChange = didChange
    }
}

public enum CursorHookInstallerError: Error, LocalizedError, Equatable {
    case hooksMustBeObject
    case eventMustBeArray(String)

    public var errorDescription: String? {
        switch self {
        case .hooksMustBeObject:
            "The Cursor hooks file has a non-object `hooks` value; TapQ left it unchanged."
        case .eventMustBeArray(let event):
            "The Cursor hooks file has a non-array `hooks.\(event)` value; TapQ left it unchanged."
        }
    }
}

/// Idempotently merges TapQ's agent hooks into `~/.cursor/hooks.json` while preserving
/// unrelated top-level data, events, and entries.
///
/// Every mutation snapshots the existing file first and publishes its replacement
/// atomically. Cursor has no hook-trust step: it reloads `hooks.json` when the file
/// changes, and a stale client only needs a restart.
///
/// Schema source: https://cursor.com/docs/agent/hooks. Unlike Claude Code and Codex,
/// Cursor's event arrays hold hook entries directly — `matcher` is a field on the entry,
/// not a wrapper group — so this installer manages flat entries.
public struct CursorHookInstaller {
    public static let defaultHookExecutableName = "tapq-cursor-hook"
    public static let reloadInstruction =
        "Cursor reloads hooks.json when it changes. Restart Cursor if the TapQ hooks do "
        + "not take effect in an open session."

    public let hooksURL: URL
    public let hookCommand: String
    private let fileWriter: any SecureAtomicFileWriting

    struct Spec {
        let event: String
        let matcher: String?
        let timeout: Double
    }

    /// The deliberately narrow installed slice:
    ///
    /// * `beforeShellExecution` — every non-sandboxed shell command.
    /// * `preToolUse` for `Write` and `Delete` — the mutating file tools. Cursor matches
    ///   this event by tool type, and it has no pre-edit event of its own (`afterFileEdit`
    ///   reports an edit that already happened).
    /// * `stop` — completion announcements.
    ///
    /// `beforeMCPExecution`, `beforeReadFile`, `beforeSubmitPrompt`, the Tab hooks, and the
    /// session-lifecycle hooks stay in Cursor's own interface.
    static let specs: [Spec] = [
        Spec(
            event: "beforeShellExecution",
            matcher: nil,
            timeout: InteractionBudget.hookTimeout
        ),
        Spec(
            event: "preToolUse",
            matcher: CursorTool.write,
            timeout: InteractionBudget.hookTimeout
        ),
        Spec(
            event: "preToolUse",
            matcher: CursorTool.delete,
            timeout: InteractionBudget.hookTimeout
        ),
        Spec(event: "stop", matcher: nil, timeout: 8),
    ]
    private static let managedEvents = Set(specs.map(\.event))

    /// Cursor's `hooks.json` declares a schema version. TapQ writes it only when the file
    /// does not already carry one; an existing value is unrelated user data.
    static let schemaVersion: Double = 1

    public init(
        hooksURL: URL = CursorHookInstaller.cursorHooksURL(),
        hookCommand: String = CursorHookInstaller.defaultHookExecutableName
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

    /// The user-level hooks file Cursor discovers for every project.
    public static func cursorHooksURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// Installs or repairs the TapQ layout.
    @discardableResult
    public func install() throws -> CursorHookInstallationReport {
        let original = try readRoot()
        var root = original
        var hooks = try hooksObject(in: root)

        for event in Self.managedEvents {
            let existing = try entries(for: event, in: hooks)
            let remaining = stripTapQ(from: existing).entries
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(remaining)
            }
        }

        for spec in Self.specs {
            var eventEntries = try entries(for: spec.event, in: hooks)
            eventEntries.append(entry(for: spec))
            hooks[spec.event] = .array(eventEntries)
        }
        if root["version"] == nil {
            root["version"] = .number(Self.schemaVersion)
        }
        root["hooks"] = .object(hooks)

        let changed = root != original
        if changed {
            try writeRoot(root)
        }
        return CursorHookInstallationReport(status: .installed, didChange: changed)
    }

    /// Removes only TapQ-owned entries and events left empty by that removal.
    @discardableResult
    public func uninstall() throws -> CursorHookInstallationReport {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else {
            return .init(status: .notInstalled, didChange: false)
        }

        let original = try readRoot()
        var root = original
        guard root["hooks"] != nil else {
            return .init(status: .notInstalled, didChange: false)
        }
        var hooks = try hooksObject(in: root)
        var removedManagedHook = false

        for event in Self.managedEvents {
            let existing = try entries(for: event, in: hooks)
            let stripped = stripTapQ(from: existing)
            removedManagedHook = removedManagedHook || stripped.didRemove
            if stripped.entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(stripped.entries)
            }
        }

        guard removedManagedHook else {
            return .init(status: installationStatus(in: original), didChange: false)
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
        return .init(status: installationStatus(in: root), didChange: changed)
    }

    public func isInstalled() -> Bool {
        installationStatus() == .installed
    }

    public func statusReport() -> CursorHookInstallationReport {
        .init(status: installationStatus(), didChange: false)
    }

    public func installationStatus() -> CursorHookInstallationStatus {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return .notInstalled }
        guard let root = try? readRoot() else { return .partial }
        return installationStatus(in: root)
    }

    // MARK: - Hook layout

    var shellCommand: String { Self.shellQuoted(hookCommand) }

    /// Cursor accepts a command line rather than a bare executable path — its own examples
    /// include arguments, as in `bun run hooks/before-shell-execution.ts` — so an absolute
    /// path that may contain spaces has to be quoted the same way Codex's hooks are.
    static func shellQuoted(_ command: String) -> String {
        "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func hooksObject(in root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value.objectValue else {
            throw CursorHookInstallerError.hooksMustBeObject
        }
        return hooks
    }

    private func entries(
        for event: String,
        in hooks: [String: JSONValue]
    ) throws -> [JSONValue] {
        guard let value = hooks[event] else { return [] }
        guard let entries = value.arrayValue else {
            throw CursorHookInstallerError.eventMustBeArray(event)
        }
        return entries
    }

    private func entry(for spec: Spec) -> JSONValue {
        var entry: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(shellCommand),
            "timeout": .number(spec.timeout),
        ]
        if let matcher = spec.matcher {
            entry["matcher"] = .string(matcher)
        }
        return .object(entry)
    }

    private func stripTapQ(
        from entries: [JSONValue]
    ) -> (entries: [JSONValue], didRemove: Bool) {
        let kept = entries.filter { !isManagedTapQHook($0) }
        return (kept, kept.count != entries.count)
    }

    private func isCurrentHook(_ entry: JSONValue) -> Bool {
        guard let command = entry["command"]?.stringValue else { return false }
        return command == shellCommand || command == hookCommand
    }

    private func isManagedTapQHook(_ entry: JSONValue) -> Bool {
        guard let command = entry["command"]?.stringValue else { return false }
        if isCurrentHook(entry) { return true }

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
        let hasFailClosed: Bool
        let hasLoopLimit: Bool
    }

    private func installationStatus(
        in root: [String: JSONValue]
    ) -> CursorHookInstallationStatus {
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
            for entry in hooks[event]?.arrayValue ?? [] where isManagedTapQHook(entry) {
                let timeout: Double?
                if case .number(let value)? = entry["timeout"] {
                    timeout = value
                } else {
                    timeout = nil
                }
                result[Registration(
                    event: event,
                    matcher: entry["matcher"]?.stringValue,
                    command: isCurrentHook(entry) ? shellCommand : "<stale>",
                    type: entry["type"]?.stringValue,
                    timeout: timeout,
                    hasFailClosed: entry["failClosed"] != nil,
                    hasLoopLimit: entry["loop_limit"] != nil
                ), default: 0] += 1
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
                hasFailClosed: false,
                hasLoopLimit: false
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
            if isCanonicalCursorHooksURL {
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

    private var isCanonicalCursorHooksURL: Bool {
        hooksURL.standardizedFileURL.path
            == Self.cursorHooksURL().standardizedFileURL.path
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
