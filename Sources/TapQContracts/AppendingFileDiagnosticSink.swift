import Foundation

/// A diagnostic sink that appends one line per event to a file, for processes whose
/// standard error nobody reads.
///
/// The hook shims are the case: Claude Code runs them with stderr captured, shows it only
/// when the hook fails, and every decision they make on a clean exit — a reply read from
/// the transcript, a reply not found, a stop question passed — leaves no trace. Pointed
/// at a file by the runtime's launcher (`TAPQ_HOOK_LOG`), the shim's record survives.
///
/// Every level is written: a hook runs for a fraction of a second and the file is the
/// only place its debug lines can go. Each line carries the wall clock and the process
/// id, because several hooks may append to the same file at once. A file that cannot be
/// opened or written is ignored — a diagnostic sink must never fail the hook.
public struct AppendingFileDiagnosticSink: TapQDiagnosticSink {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The sink named by `environmentKey` in `environment`, or `nil` when it is unset or
    /// empty.
    public init?(environment: [String: String], key: String) {
        guard let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        self.init(path: path)
    }

    public func record(_ event: TapQDiagnosticEvent) {
        let line = Self.formatted(event, at: Date(), processID: ProcessInfo.processInfo.processIdentifier)
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { return }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        // O_APPEND semantics are not guaranteed by FileHandle; one line per event is small
        // enough that interleaving between concurrent hooks stays at line granularity in
        // practice, which is all a diagnostic file needs.
        try? handle.write(contentsOf: data)
    }

    static func formatted(_ event: TapQDiagnosticEvent, at date: Date, processID: Int32) -> String {
        let fields = event.fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = fields.isEmpty ? "" : " \(fields)"
        let stamp = ISO8601DateFormatter.diagnosticTimestamp.string(from: date)
        return "\(stamp) [pid \(processID)][\(event.level.rawValue)][\(event.category)] \(event.name)\(suffix)\n"
    }
}

private extension ISO8601DateFormatter {
    static let diagnosticTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
