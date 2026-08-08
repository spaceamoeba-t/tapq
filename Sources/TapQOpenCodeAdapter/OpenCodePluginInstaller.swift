import Foundation
import TapQContracts
import TapQPOSIXSupport

/// The TapQ plugin layout currently found in OpenCode's plugin directory.
public enum OpenCodePluginInstallationStatus: Equatable, Sendable {
    case notInstalled
    /// A TapQ-managed plugin whose contents match what this build would install.
    case installed
    /// A TapQ-managed plugin from a different build, hook path, or relay version.
    case partial
    /// A file exists at the managed path but was not written by TapQ.
    case foreign
}

/// OpenCode loads plugins at process start, so a newly written or changed plugin only
/// takes effect in sessions started afterwards.
public enum OpenCodePluginReloadAction: Equatable, Sendable {
    case none
    case restartRequired

    public var message: String? {
        switch self {
        case .none:
            nil
        case .restartRequired:
            OpenCodePluginInstaller.restartInstruction
        }
    }
}

/// A mutation or status result suitable for direct presentation by the CLI.
public struct OpenCodePluginInstallationReport: Equatable, Sendable {
    public let status: OpenCodePluginInstallationStatus
    public let didChange: Bool
    public let reloadAction: OpenCodePluginReloadAction

    public init(
        status: OpenCodePluginInstallationStatus,
        didChange: Bool,
        reloadAction: OpenCodePluginReloadAction
    ) {
        self.status = status
        self.didChange = didChange
        self.reloadAction = reloadAction
    }
}

public enum OpenCodePluginInstallerError: Error, LocalizedError, Equatable {
    case foreignPluginPresent(String)

    public var errorDescription: String? {
        switch self {
        case .foreignPluginPresent(let path):
            "A plugin TapQ did not write already exists at \(path); TapQ left it unchanged. "
            + "Move it aside or pass --plugin PATH to install elsewhere."
        }
    }
}

/// Installs and removes TapQ's OpenCode plugin, which is the adapter's only footprint in
/// the user's OpenCode configuration.
///
/// Unlike Claude Code and Codex, OpenCode has no hook-registration file to merge into: it
/// discovers plugins by scanning its config directory, so the unit of installation is one
/// self-contained file that TapQ owns end to end. That makes "preserve unrelated user
/// configuration" a question of *not touching* neighbouring plugins rather than of merging
/// managed entries, and it makes ownership detection explicit: only a file carrying TapQ's
/// marker is ever rewritten or removed. A file TapQ did not write is reported and left in
/// place rather than clobbered.
///
/// Every mutation snapshots an existing file first and publishes its replacement
/// atomically, matching the Codex installer's backup guarantees.
///
/// Plugin discovery paths are documented at https://opencode.ai/docs/plugins/.
public struct OpenCodePluginInstaller {
    public static let defaultHookExecutableName = "tapq-opencode-hook"
    public static let pluginFileName = "tapq.js"
    public static let restartInstruction =
        "Restart OpenCode so it loads the current TapQ plugin. OpenCode reads its plugin "
        + "directory at startup, so sessions already running keep the previous behavior."

    public let pluginURL: URL
    public let hookCommand: String
    private let fileWriter: any SecureAtomicFileWriting

    public init(
        pluginURL: URL = OpenCodePluginInstaller.openCodePluginURL(),
        hookCommand: String = OpenCodePluginInstaller.defaultHookExecutableName
    ) {
        self.pluginURL = pluginURL
        self.hookCommand = hookCommand
        self.fileWriter = POSIXSecureAtomicFileWriter()
    }

    init(
        pluginURL: URL,
        hookCommand: String,
        fileWriter: any SecureAtomicFileWriting
    ) {
        self.pluginURL = pluginURL
        self.hookCommand = hookCommand
        self.fileWriter = fileWriter
    }

    /// The directory OpenCode scans for global plugin files.
    ///
    /// OpenCode globs `{plugin,plugins}/*.{ts,js}` under each configuration directory, so
    /// both spellings load. TapQ writes the plural form the documentation uses.
    public static let pluginDirectoryName = "plugins"

    /// The user-level plugin file OpenCode discovers by default.
    ///
    /// OpenCode resolves its global configuration directory as `$OPENCODE_CONFIG_DIR` when
    /// set, then `$XDG_CONFIG_HOME/opencode`, then `~/.config/opencode`, and loads every
    /// plugin file it finds there at startup.
    public static func openCodePluginURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        openCodeConfigDirectoryURL(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
            .appendingPathComponent(pluginFileName)
    }

    public static func openCodeConfigDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configDirectory = absoluteDirectory(environment["OPENCODE_CONFIG_DIR"]) {
            return configDirectory
        }
        let base = absoluteDirectory(environment["XDG_CONFIG_HOME"])
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("opencode", isDirectory: true)
    }

    /// Only an absolute path is a usable base directory; anything else falls back so a
    /// stray relative value cannot place the plugin somewhere OpenCode will not scan.
    private static func absoluteDirectory(_ value: String?) -> URL? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// The exact plugin bytes this build installs, for the current hook path.
    public var pluginContents: String {
        OpenCodePluginSource.render(hookCommand: hookCommand)
    }

    /// Installs or repairs the TapQ plugin. A changed plugin needs an OpenCode restart.
    @discardableResult
    public func install() throws -> OpenCodePluginInstallationReport {
        let existing = try existingContents()
        if let existing, !OpenCodePluginSource.isManagedPlugin(existing) {
            throw OpenCodePluginInstallerError.foreignPluginPresent(pluginURL.path)
        }

        let desired = pluginContents
        guard existing != desired else {
            return .init(status: .installed, didChange: false, reloadAction: .none)
        }

        try write(Data(desired.utf8))
        return .init(status: .installed, didChange: true, reloadAction: .restartRequired)
    }

    /// Removes only a TapQ-managed plugin. A file TapQ did not write is left in place.
    @discardableResult
    public func uninstall() throws -> OpenCodePluginInstallationReport {
        guard let existing = try existingContents() else {
            return .init(status: .notInstalled, didChange: false, reloadAction: .none)
        }
        guard OpenCodePluginSource.isManagedPlugin(existing) else {
            return .init(status: .foreign, didChange: false, reloadAction: .none)
        }

        try backupIfPresent()
        try FileManager.default.removeItem(at: pluginURL)
        return .init(status: .notInstalled, didChange: true, reloadAction: .restartRequired)
    }

    public func isInstalled() -> Bool {
        installationStatus() == .installed
    }

    public func statusReport() -> OpenCodePluginInstallationReport {
        let status = installationStatus()
        return .init(
            status: status,
            didChange: false,
            reloadAction: status == .partial ? .restartRequired : .none
        )
    }

    public func installationStatus() -> OpenCodePluginInstallationStatus {
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return .notInstalled }
        // An unreadable file at the managed path is not TapQ's to rewrite or remove.
        guard let contents = (try? existingContents()) ?? nil else { return .foreign }
        guard OpenCodePluginSource.isManagedPlugin(contents) else { return .foreign }
        return contents == pluginContents ? .installed : .partial
    }

    // MARK: - File I/O

    private func existingContents() throws -> String? {
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return nil }
        let data = try Data(contentsOf: pluginURL)
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ data: Data) throws {
        try preparePluginDirectory()
        let previous = try backupIfPresent()
        try fileWriter.write(
            data,
            to: pluginURL,
            mode: Self.pluginMode(for: previous),
            disposition: .replaceExisting
        )
    }

    private struct PluginSnapshot {
        let data: Data
        let mode: UInt16
    }

    @discardableResult
    private func backupIfPresent() throws -> UInt16? {
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return nil }
        let data = try Data(contentsOf: pluginURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: pluginURL.path)
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600) & 0o777
        try fileWriter.write(
            data,
            to: uniqueBackupURL(),
            mode: Self.backupMode(for: mode),
            disposition: .createNew
        )
        return mode
    }

    private func uniqueBackupURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return pluginURL.appendingPathExtension(
            "tapq-backup-\(stamp)-\(UUID().uuidString)"
        )
    }

    private static func pluginMode(for existingMode: UInt16?) -> UInt16 {
        guard let existingMode else { return 0o600 }
        let ownerReadWrite = existingMode & 0o600
        return ownerReadWrite & 0o400 != 0 ? ownerReadWrite : 0o600
    }

    private static func backupMode(for existingMode: UInt16) -> UInt16 {
        existingMode & 0o600
    }

    private func preparePluginDirectory() throws {
        let directory = pluginURL.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: UInt16(0o700))]
        )
    }
}
