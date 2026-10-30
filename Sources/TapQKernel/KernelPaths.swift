import Foundation

/// Where one workspace's kernel state lives.
///
/// One directory per workspace, named by a hash of its path, so two checkouts of the same
/// project never share a transcript and a renamed parent directory never silently inherits
/// one.
public enum KernelPaths {
    /// Characters of the hex digest used in the directory name.
    public static let keyLength = 12

    /// The stable directory name for a workspace.
    public static func workspaceKey(for workspace: URL) -> String {
        String(SHA256.hexDigest(of: workspace.standardizedFileURL.path).prefix(keyLength))
    }

    /// Where TapQ keeps its state on this machine: `TAPQ_BROKER_DIR` when it is set (the
    /// end-to-end harness points it at a scratch directory), else
    /// `~/Library/Application Support/TapQ/runtime` on macOS, and the XDG runtime directory,
    /// or `~/.local/state/tapq/runtime`, elsewhere.
    ///
    /// The same path the legacy broker used (`BrokerRuntimeDiscovery`, deleted 2026-10-08),
    /// so every kernel directory written before the deletion is still found. The variable
    /// keeps its old name for the same reason.
    public static func defaultSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        if let override = nonempty(environment["TAPQ_BROKER_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS) || os(iOS)
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("TapQ/runtime", isDirectory: true)
        #else
        if let runtimeDirectory = nonempty(environment["XDG_RUNTIME_DIR"]) {
            return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
                .appendingPathComponent("tapq", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local/state/tapq/runtime", isDirectory: true)
        #endif
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public static func directory(supportDirectory: URL, workspace: URL) -> URL {
        supportDirectory
            .appendingPathComponent("kernel")
            .appendingPathComponent(workspaceKey(for: workspace))
    }
}
