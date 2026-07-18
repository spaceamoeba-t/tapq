import Foundation
import TapQContracts

/// Lightweight foreground diagnostics for the open runtime. Warnings and errors are
/// always visible; `TAPQ_DEBUG=1` also prints lifecycle and detected-input events.
final class ConsoleDiagnosticSink: TapQDiagnosticSink, @unchecked Sendable {
    private let verbose: Bool
    private let lock = NSLock()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let value = environment["TAPQ_DEBUG"]?.lowercased()
        verbose = value == "1" || value == "true" || value == "yes"
    }

    func record(_ event: TapQDiagnosticEvent) {
        guard verbose || event.level == .warning || event.level == .error else { return }
        let fields = event.fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = fields.isEmpty ? "" : " \(fields)"
        let line = "[tapq][\(event.level.rawValue)][\(event.category)] \(event.name)\(suffix)\n"

        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
