import Foundation
import TapQContracts

/// Why the process is about to end.
///
/// `subsystem` names the half of the loop that died, so the log says where to look before
/// anyone reads the reason.
public struct FatalReason: Sendable, Equatable {
    public enum Subsystem {
        public static let kernel = "kernel"
        public static let journal = "journal"
        public static let speechInput = "speech-input"
        public static let speechOutput = "speech-output"
        public static let intent = "intent"
        public static let summarizer = "summarizer"
        public static let describer = "describer"
        public static let titler = "titler"
        public static let picker = "picker"
        public static let progress = "progress"
        /// One agent's delegate: `delegate.claude`, `delegate.codex`.
        public static func delegate(_ agent: AgentID) -> String { "delegate.\(agent.rawValue)" }

        // Startup checks and transcription mode, which has no agent of its own.
        public static let model = "model"
        public static let delegate = "delegate"
        public static let transcript = "transcript"
        /// The recording-mode engine behind `LiveTranscriber`. Its own subsystem because a
        /// recording has no model and no delegate: when transcription dies there is no other
        /// half of the loop to suspect.
        public static let transcriber = "transcriber"
        /// The microphone, on the recording path.
        public static let microphone = "microphone"
    }

    public let subsystem: String
    public let reason: String
    public let context: [String: String]

    public init(subsystem: String, reason: String, context: [String: String] = [:]) {
        self.subsystem = subsystem
        self.reason = reason
        self.context = context
    }
}

/// The one way out. Injected so a test can assert "fatal was requested" without dying.
///
/// The kernel treats `crash` as terminal: it stops processing and `run()` returns.
@MainActor
public protocol FatalHandling: AnyObject {
    func crash(_ reason: FatalReason)
}

/// The shipping implementation: record it, run `beforeExit`, say it once on stderr, exit 70.
///
/// `beforeExit` is where the composition kills what would outlive the process
/// (`ChildProcess.killAllGroups`); it must not block.
///
/// There is no flush step because there is nothing buffered — `AppendingFileDiagnosticSink`
/// opens, appends and closes per event, so the `kernel.fatal` line is on disk before this
/// returns.
@MainActor
public final class ProcessFatal: FatalHandling {
    public static let exitCode: Int32 = 70

    private let diagnostics: TapQDiagnosticEmitter
    /// The executable the stderr line names: `tapq-kernel`, or another executable that shares
    /// this door.
    private let program: String
    private let beforeExit: @Sendable () -> Void
    private let writeStandardError: @Sendable (String) -> Void
    /// Never returns in the shipping process; a test's returns.
    private let exitProcess: @Sendable (Int32) -> Void

    /// The default stderr write cannot raise: a closed stderr (the host is gone) must not
    /// abort the process in the middle of a stop.
    public init(diagnostics: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                program: String = "tapq-kernel",
                beforeExit: @escaping @Sendable () -> Void = {},
                writeStandardError: @escaping @Sendable (String) -> Void = { text in
                    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
                },
                exitProcess: @escaping @Sendable (Int32) -> Void = { code in exit(code) }) {
        self.diagnostics = TapQDiagnosticEmitter(category: "kernel", sink: diagnostics)
        self.program = program
        self.beforeExit = beforeExit
        self.writeStandardError = writeStandardError
        self.exitProcess = exitProcess
    }

    public func crash(_ reason: FatalReason) {
        var fields = reason.context
        fields["subsystem"] = reason.subsystem
        fields["reason"] = reason.reason
        diagnostics.record("fatal", level: .error, fields: fields)
        beforeExit()
        writeStandardError(Self.message(for: reason, program: program) + "\n")
        exitProcess(Self.exitCode)
    }

    /// The single stderr line. Pinned by a test because it is the only thing a user who
    /// launched the executable from a terminal will see.
    public static func message(for reason: FatalReason) -> String {
        message(for: reason, program: "tapq-kernel")
    }

    /// The same line for another executable that exits through this door.
    public static func message(for reason: FatalReason, program: String) -> String {
        "\(program): fatal in \(reason.subsystem): \(reason.reason)"
    }
}
