#if canImport(TapQAppleAdapters)
import Foundation
import TapQContextBaseline
import TapQContracts

/// Append-only local record of what the stage-2 reasoner said and what the user then did.
///
/// This is the shadow-review artifact: the only way to answer "would `primary` have been
/// safe here?" is to compare, over real traffic, the requirement a decision implied
/// against the decision the user actually made. It is written in `shadow` and in
/// `primary` alike, because the same question stays worth asking after promotion.
///
/// **Sensitivity: the same class as `broker.json`, and it persists a command prefix.**
/// The full command line, the working directory, and the adapter's `detail` are all
/// deliberately absent. `summary` and the model's bounded `note` are the two reviewable
/// exceptions, and `summary` is the one to be honest about: for a `Bash` request
/// `ToolSummary.render` produces `run <first 6 words, capped at 64 characters>` of the
/// command itself. That prefix can carry real secrets — a connection string, a header
/// fragment, a token passed as an early argument — because it is the *front* of the
/// command line, not a sanitized description of it.
///
/// For a canonical MCP row, the raw connector argument object is also absent. Its model-
/// generated rationale note is deliberately omitted as well: even though the prompt
/// tells the model not to copy request text, that instruction is not a redaction
/// boundary and the note could otherwise echo an argument value into this file. The
/// tier, closed rationale code, and outcome remain available for review. Confidence is
/// omitted too because arbitrary numeric precision could become a smaller echo channel.
///
/// For a question row (`tool_name` `AgentQuestion`) `summary` is the question itself, as
/// the classifier extracted it from the agent's final reply — the same sentence TapQ read
/// out and asked the user to answer. A question row carries no command line, no `cwd`,
/// and no `detail` at all, so fusion widened what is *assessed* without widening what is
/// recorded: these rows persist strictly less than the `Bash` rows already here.
///
/// It is recorded anyway: a review artifact that cannot say what was asked cannot answer
/// the only question it exists for, and this is the same text TapQ already speaks aloud
/// for that request. The exposure is bounded rather than eliminated — the file is created
/// `0600` inside the `0700` runtime directory, never leaves the machine, is never read
/// back by TapQ, and is capped at two generations of roughly 5 MB. Deleting either file
/// at any time is safe and costs nothing but review history.
///
/// Every write failure is swallowed. A log that cannot be written must not fail, delay,
/// or change an approval: the user is mid-gesture, and their answer does not depend on
/// whether a review artifact landed on disk.
@MainActor final class ReasonerShadowLog {
    static let fileName = "reasoner-log.jsonl"
    /// Single rotation target. One generation is enough for review — the interesting
    /// window is recent traffic — and an unbounded series of numbered files in the
    /// runtime directory would be a quiet disk leak.
    static let rotatedFileName = "reasoner-log.1.jsonl"
    /// Soft cap, checked before each append. Roughly 5 MB is tens of thousands of
    /// records: far more than a review needs, small enough to never matter.
    static let maximumBytes = 5 * 1_024 * 1_024

    private let directory: URL
    private let diagnostics: TapQDiagnosticEmitter
    private let encoder: JSONEncoder
    private let timestamps: ISO8601DateFormatter

    init(directory: URL, diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.directory = directory
        self.diagnostics = TapQDiagnosticEmitter(
            category: "ReasonerShadowLog",
            sink: diagnosticSink
        )
        self.encoder = JSONEncoder()
        // Sorted keys because every other JSON TapQ writes is sorted, and a stable key
        // order is what makes an append-only file greppable and diffable across runs.
        // Unescaped slashes because the file is read by a person and half its values are
        // paths; `~\/Documents` is valid JSON and unreadable prose.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.timestamps = ISO8601DateFormatter()
        // Fractional seconds so records from one burst of approvals stay ordered.
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var rotatedFileURL: URL { directory.appendingPathComponent(Self.rotatedFileName) }

    /// Records one reasoner-observed approval.
    ///
    /// `requiredConfirmation` is what the decision implied — in `shadow` that is the
    /// counterfactual the whole file exists to collect, which is why it is recorded even
    /// though nothing acted on it. `escalationApplied` is the narrower fact: whether the
    /// interaction actually demanded more than `standard`, which only `primary` can do.
    ///
    /// `request` supplies identity; `context` supplies what the model was actually shown,
    /// which is what a review is comparing decisions against. The two agree field for
    /// field on broker traffic, and differ by design on a question: `tool_name` records
    /// the reasoner's synthetic `AgentQuestion` rather than the coordinator's internal
    /// `StopQuestion`, so a log row, a prompt, and a `bench/` row all name a question the
    /// same way.
    func append(
        mode: ReasonerMode,
        request: ApprovalRequest,
        context: ReasonerContext,
        assessment: ReasonerAssessment,
        requiredConfirmation: RequiredConfirmation,
        escalationApplied: Bool,
        outcome: Decision
    ) {
        let record = Record(
            timestamp: timestamps.string(from: Date()),
            requestID: request.id,
            agentName: request.agent.displayName,
            toolName: context.toolName,
            summary: context.summary,
            mode: mode.rawValue,
            riskTier: assessment.decision?.riskTier.rawValue,
            code: assessment.decision?.rationale.code.rawValue,
            // An MCP context carries arbitrary third-party values. Never persist a
            // free-text model field derived from that context: constrained tier/code
            // values provide the review signal without creating an echo channel.
            note: ReasonerReviewDisclosure.persistedNote(
                from: assessment.decision,
                context: context
            ),
            confidence: ReasonerReviewDisclosure.persistedConfidence(
                from: assessment.decision,
                context: context
            ),
            abstained: assessment.decision == nil ? true : nil,
            abstainReason: assessment.abstention?.rawValue,
            reasonerLatencyMilliseconds: assessment.latencyMilliseconds,
            requiredConfirmation: requiredConfirmation.rawValue,
            escalationApplied: escalationApplied,
            outcome: outcome.rawValue
        )

        do {
            var line = try encoder.encode(record)
            line.append(0x0A)
            try write(line)
        } catch {
            // Deliberately terminal: no retry, no fallback path, no rethrow. The only
            // thing a failed review artifact may cost is the artifact.
            diagnostics.record("write_failed", level: .warning, fields: [
                "error": String(describing: error),
            ])
        }
    }

    private func write(_ line: Data) throws {
        let fileManager = FileManager.default
        rotateIfNeeded(adding: line.count, fileManager: fileManager)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: line,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Rotates before the append that would cross the cap, so the live file never
    /// exceeds it. A previous rotation is replaced rather than kept: two generations is
    /// the bound, and `moveItem` onto an existing path fails rather than overwriting.
    private func rotateIfNeeded(adding bytes: Int, fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size + bytes > Self.maximumBytes else { return }
        try? fileManager.removeItem(at: rotatedFileURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }

    /// One JSONL line, written with sorted keys.
    ///
    /// Optional fields are omitted when absent (synthesized `encode(to:)` skips `nil`),
    /// which is what makes a decided record and an abstained one visibly different
    /// shapes rather than one shape half full of nulls.
    private struct Record: Encodable {
        let timestamp: String
        let requestID: String
        let agentName: String
        let toolName: String
        let summary: String
        let mode: String
        let riskTier: String?
        let code: String?
        let note: String?
        let confidence: Double?
        let abstained: Bool?
        let abstainReason: String?
        let reasonerLatencyMilliseconds: Int
        let requiredConfirmation: String
        let escalationApplied: Bool
        let outcome: String

        enum CodingKeys: String, CodingKey {
            case timestamp = "ts"
            case requestID = "request_id"
            case agentName = "agent_name"
            case toolName = "tool_name"
            case summary
            case mode
            case riskTier = "risk_tier"
            case code
            case note
            case confidence
            case abstained
            case abstainReason = "abstain_reason"
            case reasonerLatencyMilliseconds = "reasoner_latency_ms"
            case requiredConfirmation = "required_confirmation"
            case escalationApplied = "escalation_applied"
            case outcome
        }
    }
}
#endif
