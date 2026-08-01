import Foundation
import TapQContracts

/// How consequential the requested agent action is judged to be.
///
/// A tier is advisory input to a confirmation policy, never an outcome. Nothing in this
/// contract approves, denies, or answers a request — the only thing a tier can do is
/// select a *stronger* confirmation requirement (`ReasonerConfig.confirmation(for:)`).
/// `allCases` order is ascending consequence and is part of the pinned contract.
public enum RiskTier: String, CaseIterable, Sendable, Codable, Equatable {
    /// Ordinary work whose effects stay inside the workspace and are easy to undo:
    /// reads, builds, test runs, edits to tracked files.
    case routine
    /// Consequential enough that the user would want to be sure it was really them
    /// approving: touches secrets, leaves the machine, or changes durable configuration.
    case sensitive
    /// Destroys or irreversibly changes state the user cannot get back by re-running the
    /// agent: deletions, overwrites, history rewrites, published side effects.
    case destructive
}

/// Why a request was placed above `routine`.
///
/// This closed set — not the free-text note — is the signal: it is what diagnostics
/// aggregate, what the bench corpus asserts on, and what a future policy may branch on.
/// Keeping it closed is what makes the stage-2 output schema auditable; a model that
/// cannot name a listed reason has to say `unspecified` rather than invent a category.
///
/// Codes are deliberately non-overlapping in intent, but a single action can satisfy
/// several (`rm -rf ~/.config`). `allCases` order is the precedence order: report the
/// first code that applies, so identical actions produce identical rationales.
public enum RationaleCode: String, CaseIterable, Sendable, Codable, Equatable {
    /// Deletes, overwrites, truncates, or resets existing content — files, records,
    /// branches, or history the user cannot regenerate by re-running the agent.
    case dataLoss = "data_loss"
    /// Reads, writes, or transmits credentials, keys, tokens, or a credential store.
    case credentialExposure = "credential_exposure"
    /// Sends data off the machine or makes it visible to others: network writes, pushes,
    /// publishes, deploys, outbound messages.
    case externalPublication = "external_publication"
    /// Changes durable machine, account, or tool configuration — settings, installed
    /// software, hooks, scheduled jobs — beyond the current session.
    case systemConfiguration = "system_configuration"
    /// The blast radius is wide or unbounded without necessarily destroying anything:
    /// wildcards, recursion over many paths, "all"/"force" flags.
    case bulkOrUnscopedChange = "bulk_or_unscoped_change"
    /// Judged risky, but the reason is not one of the codes above. Deliberately last:
    /// it is the honest answer, not a default.
    case unspecified
}

/// Why a decision escalated, as a closed code plus optional annotation.
///
/// `code` carries the meaning; `note` is annotation only — never parsed, never branched
/// on, and hard-capped by both the initializer and `init(from:)`. That split is what
/// keeps the schema closed while still letting a decision say something specific in a
/// log or on screen.
///
/// Normalization is byte-bound, then character-truncate, then trim, then empty-to-`nil`.
/// The order matters: trimming last makes normalization idempotent, so encoding and
/// decoding a rationale is a fixed point. Trimming first would let truncation reintroduce
/// a trailing space that the next decode would strip, and a recorded corpus fixture would
/// stop comparing equal to its own round trip.
public struct ReasonerRationale: Sendable, Codable, Equatable {
    public let code: RationaleCode
    /// Bounded, truncated, trimmed, and empty-to-`nil` normalized at construction, so a
    /// stored note is always either absent or short human-readable text.
    public let note: String?

    public init(code: RationaleCode, note: String? = nil) {
        self.code = code
        self.note = Self.normalizedNote(note)
    }

    enum CodingKeys: String, CodingKey {
        case code
        case note
    }

    /// Decoding re-applies the cap, so a decoded rationale is indistinguishable from a
    /// constructed one. Model output arrives as JSON; without this, an unbounded note
    /// would slip past the type's only guarantee.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(RationaleCode.self, forKey: .code)
        let note = try container.decodeIfPresent(String.self, forKey: .note)
        self.init(code: code, note: note)
    }

    /// Idempotent by construction: the result is already within both caps and already
    /// trimmed, so `normalizedNote(normalizedNote(x)) == normalizedNote(x)`.
    private static func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let bounded = byteBounded(note)
        let truncated = bounded.prefix(ReasonerDecisionContract.noteCharacterLimit)
        let trimmed = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Absolute byte bound applied before the character cap. A `Character` is a grapheme
    /// cluster of unbounded length, so 140 characters of combining marks could otherwise
    /// be megabytes of model output. Cut on scalar boundaries — never mid-scalar, which
    /// would produce replacement characters.
    private static func byteBounded(_ note: String) -> String {
        guard note.utf8.count > ReasonerDecisionContract.noteByteLimit else { return note }
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in note.unicodeScalars {
            let width = utf8Width(of: scalar)
            guard byteCount + width <= ReasonerDecisionContract.noteByteLimit else { break }
            byteCount += width
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func utf8Width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }
}

/// One stage-2 assessment of a pending agent action.
///
/// A decision is a *requirement*, not a resolution: it can only raise the bar the user
/// must clear to approve. There is no case here for "approve", "deny", or "skip
/// confirmation", and adding one would break the contract's guarantee that a failed,
/// absent, or hallucinating reasoner leaves deterministic behavior exactly as it was.
public struct ReasonerDecision: Sendable, Codable, Equatable {
    public let riskTier: RiskTier
    /// The confirmation this decision asks for. Callers merge it with the deterministic
    /// requirement via `RequiredConfirmation.strongest(_:_:)`; they never substitute it.
    public let requiredConfirmation: RequiredConfirmation
    public let rationale: ReasonerRationale
    /// Clamped to `0...1` at construction and at decode. Non-finite input — NaN *and*
    /// both infinities — becomes `0`, which reads as "no confidence" and is discarded by
    /// `ReasonerConfig.minConfidence`. Garbage from a backend must not present itself as
    /// certainty; the explicit `isFinite` test is also what keeps NaN handling from
    /// depending on the argument order of `max(_:_:)`.
    public let confidence: Double

    public init(
        riskTier: RiskTier,
        requiredConfirmation: RequiredConfirmation,
        rationale: ReasonerRationale,
        confidence: Double
    ) {
        self.riskTier = riskTier
        self.requiredConfirmation = requiredConfirmation
        self.rationale = rationale
        self.confidence = confidence.isFinite ? min(1.0, max(0.0, confidence)) : 0.0
    }

    /// The confirmation a request must actually collect once this decision is taken into
    /// account — the **only** supported way to combine a decision with the deterministic
    /// requirement.
    ///
    /// It is a three-way maximum over the deterministic requirement, the decision's own
    /// `requiredConfirmation`, and the tier mapping in `config`, so the result is never
    /// weaker than what the deterministic policy already demanded. Callers must not
    /// hand-write `strength` comparisons or substitute `requiredConfirmation` directly;
    /// routing through here is what makes escalation-only a property of the type rather
    /// than of every call site.
    ///
    /// Confidence is *not* applied here: a decision below `ReasonerConfig.minConfidence`
    /// is discarded as if the reasoner had returned `nil` and never reaches this method.
    public func effectiveConfirmation(
        deterministic: RequiredConfirmation,
        under config: ReasonerConfig
    ) -> RequiredConfirmation {
        RequiredConfirmation.strongest(
            deterministic,
            RequiredConfirmation.strongest(
                requiredConfirmation,
                config.confirmation(for: riskTier)
            )
        )
    }

    enum CodingKeys: String, CodingKey {
        case riskTier = "risk_tier"
        case requiredConfirmation = "required_confirmation"
        case rationale
        case confidence
    }

    /// Decoding routes through the memberwise initializer so the clamp holds for values
    /// that arrive as JSON from a model backend.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            riskTier: try container.decode(RiskTier.self, forKey: .riskTier),
            requiredConfirmation: try container.decode(
                RequiredConfirmation.self,
                forKey: .requiredConfirmation
            ),
            rationale: try container.decode(ReasonerRationale.self, forKey: .rationale),
            confidence: try container.decode(Double.self, forKey: .confidence)
        )
    }
}

/// Everything a stage-2 reasoner is given about a pending action.
///
/// Deliberately decoupled from `TapQContracts.ApprovalRequest`: the reasoner sees a
/// portable description, and the mapping from a broker request lives with the broker.
/// That keeps this target free of transport concerns and lets scenario corpora construct
/// a context without a live approval.
///
/// Designed additively — later packets (agent-context fusion) add fields. Any new field
/// must be optional or defaulted so existing call sites and stored JSON keep working.
/// `questionText` and `optionLabels` are the first of those: a pending *action* and a
/// pending *question* are both things the runtime makes the user answer, so both are
/// described by this one type rather than by two parallel ones. Fields a given request
/// has no value for stay absent — a tool call carries no `questionText`, and a question
/// carries no `commandText` or `toolInput`.
public struct ReasonerContext: Sendable, Codable, Equatable {
    /// The tool the agent asked to run, as the adapter named it (`Bash`, `Write`, ...).
    ///
    /// Non-optional, so a request that is not a tool call still has to name something:
    /// question requests use the synthetic `ReasonerContext.agentQuestionToolName`
    /// (`AgentQuestion`) by the convention `ReasonerRequestContext` documents.
    public let toolName: String
    /// The command line or primary argument, when the tool has one. Absent for tools
    /// whose input is not a command.
    public let commandText: String?
    /// The complete argument object for an open-schema tool, when its values are needed
    /// to judge the action. The bundled mapping currently supplies this for canonical
    /// Codex MCP calls: their server-defined schemas cannot be reduced to one stable
    /// command/path field without hiding the destination, content, or requested effect.
    ///
    /// This is sensitive request data. It is rendered only inside the reasoner's
    /// untrusted-data fence, under a hard size cap, and must never be logged or spoken.
    public let toolInput: [String: JSONValue]?
    /// The agent's working directory, which is what makes a path argument interpretable.
    public let cwd: String?
    /// Display name of the originating agent, for diagnostics and prompt context.
    public let agentName: String?
    /// The one-line description already shown to the user for this request.
    public let summary: String
    /// Longer supporting text when the adapter produced one.
    public let detail: String?
    /// The question the agent asked, when this request is a question rather than a tool
    /// call. What is judged is the consequence of *accepting* it: a question is not an
    /// action, but answering yes to one can authorize any action a tool call could.
    public let questionText: String?
    /// The choices offered alongside `questionText`, when the question named any.
    /// Absent for a yes/no question, which has no labels beyond yes and no.
    public let optionLabels: [String]?

    public init(
        toolName: String,
        commandText: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        cwd: String? = nil,
        agentName: String? = nil,
        summary: String,
        detail: String? = nil,
        questionText: String? = nil,
        optionLabels: [String]? = nil
    ) {
        self.toolName = toolName
        self.commandText = commandText
        self.toolInput = toolInput
        self.cwd = cwd
        self.agentName = agentName
        self.summary = summary
        self.detail = detail
        self.questionText = questionText
        self.optionLabels = optionLabels
    }

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case commandText = "command_text"
        case toolInput = "tool_input"
        case cwd
        case agentName = "agent_name"
        case summary
        case detail
        case questionText = "question_text"
        case optionLabels = "option_labels"
    }

    /// Written out rather than synthesized so additive evolution is a property of the
    /// type instead of an accident of what the compiler happened to generate: every
    /// optional field is `decodeIfPresent`, so a corpus row or a stored context recorded
    /// before a field existed still decodes, and a row that omits a key means the request
    /// had no such value — never that the decode should fail.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            toolName: try container.decode(String.self, forKey: .toolName),
            commandText: try container.decodeIfPresent(String.self, forKey: .commandText),
            toolInput: try container.decodeIfPresent(
                [String: JSONValue].self,
                forKey: .toolInput
            ),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            agentName: try container.decodeIfPresent(String.self, forKey: .agentName),
            summary: try container.decode(String.self, forKey: .summary),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            questionText: try container.decodeIfPresent(String.self, forKey: .questionText),
            optionLabels: try container.decodeIfPresent([String].self, forKey: .optionLabels)
        )
    }
}

/// The versioned stage-2 decision contract: the closed output schema a reasoner backend
/// must produce, independent of which model produces it.
///
/// Any change to the tier set, the confirmation ladder, the rationale codes, or the JSON
/// field names is a new version — recorded corpora and diagnostics are compared across
/// runs by this string, so silently reusing it would make two incompatible schemas
/// indistinguishable.
public enum ReasonerDecisionContract {
    public static let version = "tapq1-decision-v1"

    /// Hard cap on `ReasonerRationale.note`, in characters. The note is annotation, so
    /// it is bounded rather than trusted: a model cannot turn it into a channel for
    /// arbitrary-length output.
    public static let noteCharacterLimit = 140

    /// Absolute cap on `ReasonerRationale.note`, in UTF-8 bytes, applied before the
    /// character cap. Characters are grapheme clusters with no length bound, so the
    /// character cap alone does not bound memory; 1024 bytes is far above any legitimate
    /// 140-character note in any script.
    public static let noteByteLimit = 1024
}
