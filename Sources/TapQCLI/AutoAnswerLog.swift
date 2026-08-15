import Foundation
import TapQContextBaseline
import TapQContracts

/// Append-only local record of what the delegation filter answered on the user's behalf.
///
/// Every other thing TapQ does is witnessed: an approval is spoken, a gesture is made, a
/// resolution is announced. An auto-answer is the one action with no witness — that
/// silence is the entire feature — so this file is the only place a user can go to find
/// out what was said yes to while they were not asked. It is written for the same reason
/// `ReasonerShadowLog` is, and to the same discipline, but it answers a different
/// question: not "would the model have been right?" but "what did my policy actually do?".
///
/// **Sensitivity: the same class as `ReasonerShadowLog`, and it persists a command
/// prefix.** The full command line, the working directory, and the adapter's `detail` are
/// all deliberately absent, but `summary` is not: for a `Bash` request `ToolSummary
/// .render` produces `run <first 6 words, capped at 64 characters>` of the command itself,
/// and that prefix can carry a real secret passed as an early argument. It is recorded
/// anyway, because a record of a silent approval that cannot say *what* was approved
/// cannot answer the only question it exists for. The exposure is bounded the same way:
/// `0600` inside the `0700` runtime directory, never leaves the machine, never read back
/// by TapQ, capped at two generations of roughly 5 MB, and safe to delete at any time.
///
/// For an open-schema MCP context, confidence is withheld by `ReasonerReviewDisclosure`
/// exactly as it is in the shadow log — arbitrary numeric precision is a small echo
/// channel for a connector argument. The row stays reviewable without it: the verdict, the
/// tier, the closed rationale code, and the threshold that was in force all remain, and a
/// refusal still names its reason.
///
/// Every write failure is swallowed. The user is not present by definition — that is what
/// an auto-answer means — and there is nobody to tell; failing or delaying the approval
/// because a review artifact did not land would turn a full disk into a stalled agent.
@MainActor public final class AutoAnswerLog {
    public static let fileName = "auto-answer-log.jsonl"
    /// Single rotation target, matching the shadow log: one previous generation is what a
    /// review wants, and an unbounded series of numbered files is a quiet disk leak.
    public static let rotatedFileName = "auto-answer-log.1.jsonl"
    /// Soft cap, checked before each append, so the live file never exceeds it.
    public static let maximumBytes = 5 * 1_024 * 1_024

    private let directory: URL
    private let diagnostics: TapQDiagnosticEmitter
    private let encoder: JSONEncoder
    private let timestamps: ISO8601DateFormatter

    public init(
        directory: URL,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.directory = directory
        self.diagnostics = TapQDiagnosticEmitter(
            category: "AutoAnswerLog",
            sink: diagnosticSink
        )
        self.encoder = JSONEncoder()
        // Sorted keys because every other JSON TapQ writes is sorted, and a stable key
        // order is what makes an append-only file greppable and diffable across runs.
        // Unescaped slashes because the file is read by a person and its values are paths
        // and command prefixes; `~\/Documents` is valid JSON and unreadable prose.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.timestamps = ISO8601DateFormatter()
        // Fractional seconds so records from one burst of auto-answers stay ordered.
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var rotatedFileURL: URL { directory.appendingPathComponent(Self.rotatedFileName) }

    /// Records one filter verdict.
    ///
    /// The runtime calls this on the silent path — the auto-allow — because that is the
    /// decision with no other trace. Passing a refusal is supported and writes an `ask`
    /// row carrying the named reason, which is what a near-miss review ("why does nothing
    /// ever auto-answer?") needs; the request itself is unaffected either way, since by
    /// the time a verdict exists the policy has already been applied.
    ///
    /// `policy` is recorded alongside the verdict rather than assumed, because the file
    /// outlives any one setting: a row that does not say which threshold was in force
    /// cannot be read a week later, after the threshold changed.
    public func append(
        request: ApprovalRequest,
        context: ReasonerContext,
        assessment: ReasonerAssessment,
        verdict: AutoAnswerVerdict,
        policy: AutoAnswerPolicy
    ) {
        let record = Record(
            timestamp: timestamps.string(from: Date()),
            requestID: request.id,
            agentName: request.agent.displayName,
            toolName: context.toolName,
            summary: context.summary,
            verdict: verdict.isAutoAllow ? "auto_allow" : "ask",
            reason: verdict.refusal?.rawValue,
            riskTier: assessment.decision?.riskTier.rawValue,
            code: assessment.decision?.rationale.code.rawValue,
            // An MCP context carries arbitrary third-party values. The same disclosure
            // policy the shadow log uses applies here, for the same reason.
            confidence: AutoAnswerLog.persistedConfidence(
                from: assessment.decision,
                context: context
            ),
            minimumConfidence: policy.minimumConfidence,
            abstainReason: assessment.abstention?.rawValue,
            reasonerLatencyMilliseconds: assessment.latencyMilliseconds
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

    /// Withheld for open-schema contexts, mirroring `ReasonerReviewDisclosure`'s rule.
    private static func persistedConfidence(
        from decision: ReasonerDecision?,
        context: ReasonerContext
    ) -> Double? {
        guard context.toolInput == nil else { return nil }
        return decision?.confidence
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

    /// Rotates before the append that would cross the cap, so the live file never exceeds
    /// it. A previous rotation is replaced rather than kept: two generations is the bound,
    /// and `moveItem` onto an existing path fails rather than overwriting.
    private func rotateIfNeeded(adding bytes: Int, fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size + bytes > Self.maximumBytes else { return }
        try? fileManager.removeItem(at: rotatedFileURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }

    /// One JSONL line, written with sorted keys.
    ///
    /// Optional fields are omitted when absent (synthesized `encode(to:)` skips `nil`), so
    /// an auto-allow row and a refusal row are visibly different shapes rather than one
    /// shape half full of nulls.
    private struct Record: Encodable {
        let timestamp: String
        let requestID: String
        let agentName: String
        let toolName: String
        let summary: String
        let verdict: String
        let reason: String?
        let riskTier: String?
        let code: String?
        let confidence: Double?
        let minimumConfidence: Double
        let abstainReason: String?
        let reasonerLatencyMilliseconds: Int

        enum CodingKeys: String, CodingKey {
            case timestamp = "ts"
            case requestID = "request_id"
            case agentName = "agent_name"
            case toolName = "tool_name"
            case summary
            case verdict
            case reason
            case riskTier = "risk_tier"
            case code
            case confidence
            case minimumConfidence = "minimum_confidence"
            case abstainReason = "abstain_reason"
            case reasonerLatencyMilliseconds = "reasoner_latency_ms"
        }
    }
}
