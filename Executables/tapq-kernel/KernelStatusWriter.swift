import Foundation
import TapQContracts
import TapQKernel

/// The status channel (§8): one JSON line per `StatusReport` on standard output, and nothing
/// else ever written there.
///
/// Two things the kernel cannot say for itself. The ready line is the two keys §8 pins,
/// `{"v":1,"type":"ready"}`; the state the kernel's ready report carries follows it as the
/// first status line, since the kernel writes the next one only on a change. And
/// `versionOverride` is a startup fact the kernel's configuration does not carry, so it is
/// stamped on here.
@MainActor
final class KernelStatusWriter {
    static let readyLine = #"{"v":1,"type":"ready"}"#

    private let versionOverride: Bool
    private let diagnostics: TapQDiagnosticEmitter
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    init(versionOverride: Bool, sink: any TapQDiagnosticSink) {
        self.versionOverride = versionOverride
        self.diagnostics = TapQDiagnosticEmitter(category: "status", sink: sink)
    }

    func write(_ report: StatusReport) {
        if report.type == "ready" { emit(Data(Self.readyLine.utf8)) }
        var stamped = report
        stamped.type = "status"
        stamped.versionOverride = versionOverride
        do {
            emit(try encoder.encode(stamped))
        } catch {
            diagnostics.record("status.encode_failed", level: .error,
                               fields: ["error": "\(error)"])
        }
    }

    private func emit(_ json: Data) {
        var line = json
        line.append(0x0A)
        // One write per line, so a host never reads half of one. A failed write means the
        // host is gone; its closed stdin is already on the way as the shutdown.
        do {
            try FileHandle.standardOutput.write(contentsOf: line)
        } catch {
            diagnostics.record("status.write_failed", level: .warning,
                               fields: ["error": "\(error)"])
        }
    }
}
