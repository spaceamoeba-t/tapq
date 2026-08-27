import Foundation
import TapQContracts
import TapQPOSIXSupport
import TapQWireProtocol

/// Controls where Claude Code's ordinary tool approvals are intercepted.
///
/// - `strict`: TapQ sees every matched `PreToolUse` request, independent of Claude's
///   permission mode. This preserves TapQ's original behavior.
/// - `native`: TapQ sees ordinary tools only when Claude is about to show its native
///   permission dialog. `AskUserQuestion` remains a `PreToolUse` interaction.
public enum ClaudePermissionPolicy: String, CaseIterable, Equatable, Sendable {
    case strict
    case native
}

/// The TapQ hook layout currently found in Claude Code's settings.
public enum ClaudeHookInstallationStatus: Equatable, Sendable {
    case notInstalled
    case strict
    case native
    case partial
}

/// Idempotently merges TapQ's hooks into `~/.claude/settings.json`, preserving every
/// other key and any user-authored hooks. Current entries are identified by the configured
/// shim path. Known direct paths for TapQ's former hook executable are also recognized so an
/// upgrade migrates rather than duplicates TapQ's registrations.
///
/// Every mutation backs up the existing file first and writes atomically.
public struct HookInstaller {
    public let settingsURL: URL
    public let hookCommand: String
    public let policy: ClaudePermissionPolicy
    private let fileWriter: any SecureAtomicFileWriting

    /// One TapQ hook: which event, the matcher (nil = all), and the per-hook timeout.
    struct Spec {
        let event: String
        let matcher: String?
        let timeout: Double
    }

    static let strictPreToolMatcher = "Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion"
    static let nativePreToolMatcher = "AskUserQuestion"
    static let ordinaryToolMatcher = "Bash|Write|Edit|MultiEdit|NotebookEdit"

    /// Interaction timeout (~240 s) sits under the InteractionBudget.hookTimeout ceiling.
    /// UserPromptSubmit reads discovery and makes a bounded connection-only liveness probe;
    /// 5 s is generous.
    ///
    /// Stop is the exception, and it is written from `VoiceSessionBudget` (~620 s) rather
    /// than from the interaction chain. A Stop hook does two things: it may run a full
    /// interaction window for an intercepted question, and — in a voice session — it may
    /// hold the turn boundary open while the wearer thinks. The second is the longer of the
    /// two by an order of magnitude, and a hook configured for the first would be killed
    /// mid-wait, so the entry carries the ceiling that covers both. It costs nothing when
    /// no voice session is running: a hook that answers in a second is not affected by how
    /// long it *would* have been allowed to take.
    private static let sharedSpecs: [Spec] = [
        Spec(event: "Notification", matcher: "idle_prompt|permission_prompt", timeout: 10),
        Spec(event: "Stop", matcher: nil, timeout: VoiceSessionBudget.hookTimeout),
        Spec(event: "UserPromptSubmit", matcher: nil, timeout: 5),
    ]

    /// The original TapQ layout. Kept internal for compatibility tests and legacy detection.
    static let specs: [Spec] = [
        Spec(event: "PreToolUse", matcher: strictPreToolMatcher, timeout: InteractionBudget.hookTimeout),
    ] + sharedSpecs

    private static let nativeSpecs: [Spec] = [
        Spec(event: "PreToolUse", matcher: nativePreToolMatcher, timeout: InteractionBudget.hookTimeout),
        Spec(event: "PermissionRequest", matcher: ordinaryToolMatcher, timeout: InteractionBudget.hookTimeout),
    ] + sharedSpecs

    private static let managedEvents = Set(
        (specs + nativeSpecs).map(\.event)
    )

    public init(
        settingsURL: URL,
        hookCommand: String,
        policy: ClaudePermissionPolicy = .strict
    ) {
        self.settingsURL = settingsURL
        self.hookCommand = hookCommand
        self.policy = policy
        self.fileWriter = POSIXSecureAtomicFileWriter()
    }

    init(
        settingsURL: URL,
        hookCommand: String,
        policy: ClaudePermissionPolicy = .strict,
        fileWriter: any SecureAtomicFileWriting
    ) {
        self.settingsURL = settingsURL
        self.hookCommand = hookCommand
        self.policy = policy
        self.fileWriter = fileWriter
    }

    /// Convenience: the real Claude Code settings file at `~/.claude/settings.json`.
    public static func claudeSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    public func install() throws {
        var root = try readSettings()
        var hooks = root["hooks"]?.objectValue ?? [:]

        // Remove every TapQ-owned policy variant first. This makes a strict/native switch
        // one atomic settings mutation and prevents ordinary tools from being registered
        // under both PreToolUse and PermissionRequest.
        for event in Self.managedEvents {
            guard let existing = hooks[event]?.arrayValue else { continue }
            let remaining = stripTapQ(from: existing)
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(remaining)
            }
        }

        for spec in desiredSpecs {
            var groups = hooks[spec.event]?.arrayValue ?? []
            groups.append(group(for: spec))
            hooks[spec.event] = .array(groups)
        }
        root["hooks"] = .object(hooks)
        try writeSettings(root)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var root = try readSettings()
        guard var hooks = root["hooks"]?.objectValue else { return }
        for event in Self.managedEvents {
            guard let existing = hooks[event]?.arrayValue else { continue }
            let remaining = stripTapQ(from: existing)
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(remaining)
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = .object(hooks)
        }
        try writeSettings(root)
    }

    public func isInstalled() -> Bool {
        switch (policy, installationStatus()) {
        case (.strict, .strict), (.native, .native):
            return true
        default:
            return false
        }
    }

    /// Detects both complete policy layouts as well as stale, mixed, or incomplete TapQ
    /// registrations. A pre-policy TapQ installation is exactly the strict layout.
    public func installationStatus() -> ClaudeHookInstallationStatus {
        guard let root = try? readSettings(),
              let hooks = root["hooks"]?.objectValue else { return .notInstalled }

        let installedRegistrations = managedRegistrations(in: hooks)
        guard !installedRegistrations.isEmpty else { return .notInstalled }

        if installedRegistrations == registrations(for: Self.specs) {
            return .strict
        }
        if installedRegistrations == registrations(for: Self.nativeSpecs) {
            return .native
        }
        return .partial
    }

    // MARK: - Group construction

    private var desiredSpecs: [Spec] {
        switch policy {
        case .strict: Self.specs
        case .native: Self.nativeSpecs
        }
    }

    /// The command string written into settings.json: the shim path, shell-quoted. Claude
    /// Code runs each hook `command` through `/bin/sh`, so an unquoted path containing a
    /// space (e.g. `…/Application Support/…`) would word-split and fail to launch.
    var shellCommand: String { Self.shellQuoted(hookCommand) }

    /// POSIX single-quote escaping: wrap in single quotes, rewriting any embedded single
    /// quote as the `'\''` sequence.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// Drops TapQ's hook entries from each group and discards groups left empty, leaving
    /// any user-authored hooks untouched.
    private func stripTapQ(from groups: [JSONValue]) -> [JSONValue] {
        groups.compactMap { element -> JSONValue? in
            guard var group = element.objectValue,
                  let hooks = group["hooks"]?.arrayValue else { return element }
            let kept = hooks.filter { !isManagedTapQHook($0) }
            if kept.isEmpty { return nil }
            group["hooks"] = .array(kept)
            return .object(group)
        }
    }

    private func isCurrentHook(_ hook: JSONValue) -> Bool {
        guard let cmd = hook["command"]?.stringValue else { return false }
        return cmd == shellCommand || cmd == hookCommand
    }

    private func isManagedTapQHook(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        if command == shellCommand || command == hookCommand { return true }

        // Migrate only direct paths in known TapQ-owned layouts. A basename match alone
        // could delete an unrelated user hook with the same executable name.
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
        let executableName = url.lastPathComponent
        let normalized = path.lowercased()

        // Wavo was TapQ's internal pre-release codename. These paths are recognized
        // only so an installer can replace or remove hooks left by those builds.
        if executableName == "wavo-hook" {
            return [
                "/library/application support/wavo/",
                "/library/application support/tapq/",
                "/tapq-open/.build/",
                "/wavo/.build/",
                "/tapqruntime.app/contents/macos/",
                "/wavo.app/contents/macos/",
            ].contains { normalized.contains($0) }
        }

        guard executableName == "tapq-hook" else { return false }

        // Current-name migration is deliberately narrower than the historical fallback:
        // recognize only the layouts TapQ itself creates or documents. This lets moving a
        // source checkout or rebuilding TapQRuntime.app replace stale absolute hook paths
        // without claiming an arbitrary /opt/custom/tapq-hook owned by the user.
        let components = url.pathComponents.map { $0.lowercased() }
        func hasSuffix(_ suffix: [String]) -> Bool {
            components.count >= suffix.count
                && components.suffix(suffix.count).elementsEqual(suffix)
        }

        if hasSuffix(["library", "application support", "tapq", "tapq-hook"])
            || hasSuffix(["library", "application support", "tapq", "runtime", "tapq-hook"])
            || hasSuffix(["tapqruntime.app", "contents", "macos", "tapq-hook"])
        {
            return true
        }

        return zip(components, components.dropFirst()).contains { parent, child in
            (parent == "tapq" || parent == "tapq-open") && child == ".build"
        }
    }

    // MARK: - Layout detection

    private struct Registration: Hashable {
        let event: String
        let matcher: String?
        let command: String
        let type: String?
        let timeout: Double?
        let hasAsync: Bool
        let hasCondition: Bool
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
                    let command = isCurrentHook(hook) ? shellCommand : "<stale>"
                    let timeout: Double?
                    if case .number(let value)? = hook["timeout"] {
                        timeout = value
                    } else {
                        timeout = nil
                    }
                    result[Registration(
                        event: event,
                        matcher: matcher,
                        command: command,
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
            result[
                Registration(
                    event: spec.event,
                    matcher: spec.matcher,
                    command: shellCommand,
                    type: "command",
                    timeout: spec.timeout,
                    hasAsync: false,
                    hasCondition: false
                ),
                default: 0
            ] += 1
        }
        return result
    }

    // MARK: - File I/O

    private func readSettings() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func writeSettings(_ root: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(root)
        data.append(0x0A)

        try prepareSettingsDirectory()
        let previous = try settingsSnapshotIfPresent()
        if let previous {
            let backupURL = uniqueBackupURL()
            try fileWriter.write(
                previous.data,
                to: backupURL,
                mode: Self.backupMode(for: previous.mode),
                disposition: .createNew
            )
        }
        try fileWriter.write(
            data,
            to: settingsURL,
            mode: Self.settingsMode(for: previous?.mode),
            disposition: .replaceExisting
        )
    }

    private struct SettingsSnapshot {
        let data: Data
        let mode: UInt16
    }

    private func settingsSnapshotIfPresent() throws -> SettingsSnapshot? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        return SettingsSnapshot(data: data, mode: mode & 0o777)
    }

    private func uniqueBackupURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return settingsURL.appendingPathExtension(
            "tapq-backup-\(stamp)-\(UUID().uuidString)"
        )
    }

    private static func settingsMode(for existingMode: UInt16?) -> UInt16 {
        guard let existingMode else { return 0o600 }
        let ownerReadWrite = existingMode & 0o600
        // Claude must be able to read settings. Preserve a usable stricter mode such as
        // 0400, while repairing pathological write-only or mode-zero files to 0600.
        return ownerReadWrite & 0o400 != 0 ? ownerReadWrite : 0o600
    }

    private static func backupMode(for existingMode: UInt16) -> UInt16 {
        // A backup never gains group/world access or owner permissions absent from the
        // source. This preserves 0400 and narrows common 0644 files to 0600.
        existingMode & 0o600
    }

    private func prepareSettingsDirectory() throws {
        let directory = settingsURL.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            // The canonical directory is owned by the current user, so remove accidental
            // group/world access. Explicit custom directories are deliberately untouched.
            if isCanonicalClaudeSettingsURL {
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

    private var isCanonicalClaudeSettingsURL: Bool {
        settingsURL.standardizedFileURL.path == Self.claudeSettingsURL().standardizedFileURL.path
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
