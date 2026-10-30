import Foundation
import TapQContracts

/// Warnings and errors on standard error, everything under `TAPQ_DEBUG`. A closed standard
/// error (the host is gone) loses the line and nothing else.
final class KernelConsoleDiagnosticSink: TapQDiagnosticSink, @unchecked Sendable {
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
        let line = "[tapq-kernel][\(event.level.rawValue)][\(event.category)] "
            + "\(event.name)\(suffix)\n"
        lock.lock()
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        lock.unlock()
    }
}

/// One sink in front of several. The run's record goes to a file that outlives it and to the
/// terminal that launched it, and every component takes exactly one sink.
struct KernelFanOutDiagnosticSink: TapQDiagnosticSink {
    let sinks: [any TapQDiagnosticSink]

    func record(_ event: TapQDiagnosticEvent) {
        for sink in sinks { sink.record(event) }
    }
}
