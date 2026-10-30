import Foundation

/// A run's `diagnostics.log`: one line per event at `.info` and above, each with the wall
/// clock and the process id. `.debug` goes to standard error only, under `TAPQ_DEBUG`.
///
/// The file stays open. Past `rotationLimit` bytes it is renamed to `<path>.1`, replacing
/// the previous one, and a new file starts. A file that cannot be opened or written loses
/// the line: a diagnostic sink never fails its process.
public final class AppendingFileDiagnosticSink: TapQDiagnosticSink, @unchecked Sendable {
    public static let defaultRotationLimit = 5 * 1024 * 1024

    public let path: String
    public let rotationLimit: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    public init(path: String, rotationLimit: Int = AppendingFileDiagnosticSink.defaultRotationLimit) {
        self.path = path
        self.rotationLimit = rotationLimit
    }

    public func record(_ event: TapQDiagnosticEvent) {
        guard event.level != .debug else { return }
        let line = Data(Self.formatted(event, at: Date(),
                                       processID: ProcessInfo.processInfo.processIdentifier).utf8)
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { openFile() }
        if let current = handle, size > 0, size + line.count > rotationLimit {
            try? current.close()
            let archive = path + ".1"
            try? FileManager.default.removeItem(atPath: archive)
            try? FileManager.default.moveItem(atPath: path, toPath: archive)
            openFile()
        }
        guard (try? handle?.write(contentsOf: line)) != nil else { return }
        size += line.count
    }

    /// `O_APPEND`: every line lands at the end of the file as it is then, so two processes
    /// writing one log (a notes run beside the recording it reads, the review's S3) never
    /// write over each other's lines.
    private func openFile() {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            handle = nil
            return
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        size = Int((try? handle?.seekToEnd()) ?? 0)
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
