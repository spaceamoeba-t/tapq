import Foundation

/// How much of the wearer's answering the delegation filter is allowed to do.
///
/// Two cases and no ladder between them. `routine` is not "level one of several": it is the
/// only tier the reasoner can name that describes an action nobody would want to be woken
/// for, and the tiers above it are the ones a human is being asked about *because* they are
/// above it. A third case would have to mean "auto-answer something sensitive", which is
/// not a setting this project intends to offer.
public enum AutoAnswerMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// Every approval is put to the wearer, exactly as in every build before the filter
    /// existed. The default, and the composition every test that does not name the flag is
    /// asserting on.
    case off
    /// Approvals the reasoner calls `routine`, confidently enough for the user's policy,
    /// are answered `allow` without asking. Everything else — every other tier, every
    /// abstention, every timeout — still goes to the wearer.
    case routine
}

/// Why a pending approval was **not** auto-answered.
///
/// A closed set, and every refusal path in `AutoAnswerPolicy.decision(for:toolName:)`
/// names one of these. That is the point of the type: an auto-answer that fires is
/// silent, so the only way a user can audit the filter is to read back, for every request
/// it declined to answer, the specific clause that declined it. "The model was slow", "the
/// model was unsure", "you listed this tool", and "the action was not routine" are four
/// different findings, and collapsing them into one boolean would make the log unable to
/// answer the question it exists for.
///
/// The three reasoner-side cases mirror `ReasonerAbstention` one for one rather than
/// folding into a single "no decision" case, because an abstaining backend, a backend past
/// its deadline, and a backend below `ReasonerConfig.minConfidence` are operationally
/// distinct — and only the last of them says anything about this request in particular.
public enum AutoAnswerRefusal: String, Sendable, Codable, Equatable, CaseIterable {
    /// The reasoner produced no decision at all: no model, a backend error, a guardrail
    /// refusal, or unreadable output.
    case reasonerAbstained = "reasoner_abstained"
    /// The reasoner's decision fell below `ReasonerConfig.minConfidence` and was discarded
    /// before it ever reached this policy. Distinct from `belowMinimumConfidence`: this is
    /// the *reasoner's* floor, applied by `ReasonerEscalation.assess`.
    case reasonerLowConfidence = "reasoner_low_confidence"
    /// The outer deadline fired before the reasoner returned anything.
    case reasonerTimedOut = "reasoner_timeout"
    /// A decision arrived, but the action was judged `sensitive` or `destructive`. Only
    /// `routine` is ever eligible — that is the whole gate.
    case notRoutine = "not_routine"
    /// A confident-enough-for-the-reasoner routine decision that is still not confident
    /// enough for *this user's* auto-answer threshold (`minimumConfidence`).
    case belowMinimumConfidence = "below_minimum_confidence"
    /// The tool is on the user's `neverAutoTools` list, so no assessment of it can ever
    /// auto-answer.
    case neverAutoTool = "never_auto_tool"

    /// Total, and deliberately written as an exhaustive switch: adding a case to
    /// `ReasonerAbstention` must fail this build rather than quietly acquire a default
    /// mapping, because a new way for the reasoner to fail is a new way for the filter to
    /// have to stay silent.
    public init(abstention: ReasonerAbstention) {
        switch abstention {
        case .reasonerAbstained: self = .reasonerAbstained
        case .lowConfidence: self = .reasonerLowConfidence
        case .timedOut: self = .reasonerTimedOut
        }
    }
}

/// What the delegation filter concluded about one pending approval.
///
/// There are exactly two outcomes and neither of them is "deny". The filter can answer a
/// request on the user's behalf or it can decline to, and declining means the request goes
/// to the human exactly as it does today. Nothing here can make a request *harder* to
/// approve either: escalation is the reasoner's job (`ReasonerEscalation`), and this type
/// deliberately has no vocabulary for it.
public enum AutoAnswerVerdict: Sendable, Equatable {
    /// Answer `allow` without asking, silently.
    case autoAllow
    /// Put it to the human, for the named reason.
    case ask(AutoAnswerRefusal)

    public var isAutoAllow: Bool {
        if case .autoAllow = self { return true }
        return false
    }

    /// The named reason, or `nil` for an auto-allow. Every `ask` has one.
    public var refusal: AutoAnswerRefusal? {
        if case .ask(let reason) = self { return reason }
        return nil
    }
}

/// The user's standing policy for answering routine approvals on their behalf.
///
/// This is a **host** policy, and that separation is load-bearing. The stage-2 reasoner
/// contract has no approve case by construction (`ReasonerDecision` can only raise a
/// confirmation requirement), so a model can never authorize anything on its own. What a
/// model can do is say "this is routine" — an observation, not a permission. Turning that
/// observation into a silent yes is an act of delegation the *user* performs, here, by
/// enabling the filter and setting these two knobs. A compromised, confused, or
/// hallucinating reasoner still cannot approve anything the user has not delegated: the
/// worst it can do is call a sensitive action routine, which is why the tier gate is
/// paired with a confidence floor and a never-list the model cannot see or influence.
///
/// Every failure resolves to `ask`. Abstention, timeout, sub-threshold confidence, an
/// unrecognized tier — all of them leave the request exactly where it would have been with
/// the filter off. That is what makes the default-off flag byte-identical to today and
/// makes "the filter broke" indistinguishable from "the filter was never on".
public struct AutoAnswerPolicy: Sendable, Codable, Equatable {
    /// Bumped only when the on-disk field set changes meaning. A file that names a version
    /// this build does not know is a hard error at load rather than a best-effort decode:
    /// silently reinterpreting an unknown auto-answer policy is exactly the kind of guess
    /// that could widen what gets answered without asking.
    public static let currentSchemaVersion = 1

    /// Deliberately high. The threshold is the second half of the tier gate, and the cost
    /// of the two errors is asymmetric: a needless prompt costs a nod, while a wrongly
    /// silent yes costs whatever the action did.
    public static let defaultMinimumConfidence = 0.8

    public let schemaVersion: Int

    /// Floor on `ReasonerDecision.confidence` for a routine decision to be auto-answered.
    ///
    /// Clamped exactly like `ReasonerConfig.minConfidence` — non-finite becomes `1.0`, the
    /// setting under which nothing qualifies — so the two thresholds a request has to pass
    /// cannot drift apart in how they treat garbage. This one is applied *after* the
    /// reasoner's own floor and is normally the stricter of the two.
    public let minimumConfidence: Double

    /// Tools that are never auto-answered, whatever the assessment says.
    ///
    /// Empty by default: the `routine` tier is the gate, and shipping a curated denylist
    /// here would imply the tier is not trusted while still letting everything not on the
    /// list through — the worst of both. Users who want a narrower delegation name the
    /// tools themselves.
    public let neverAutoTools: [String]

    public init(
        schemaVersion: Int = AutoAnswerPolicy.currentSchemaVersion,
        minimumConfidence: Double = AutoAnswerPolicy.defaultMinimumConfidence,
        neverAutoTools: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.minimumConfidence = minimumConfidence.isFinite
            ? min(1.0, max(0.0, minimumConfidence))
            : 1.0
        self.neverAutoTools = neverAutoTools
    }

    /// What an absent policy file means. Named rather than spelled `AutoAnswerPolicy()` at
    /// call sites so "no file" and "a file holding the defaults" are provably the same
    /// policy.
    public static let defaults = AutoAnswerPolicy()

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case minimumConfidence = "minimum_confidence"
        case neverAutoTools = "never_auto_tools"
    }

    /// Tolerant of absent optional knobs, strict about the version — and routed through
    /// the memberwise initializer so a value read from disk is clamped exactly like one
    /// written in code. Without that, a hand-edited `minimum_confidence: -1` would be a
    /// threshold no request could fail.
    ///
    /// `schema_version` itself is required: a policy file with no version is not a policy
    /// file this build can vouch for, and the store's job is to refuse it rather than
    /// assume it meant version 1.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            minimumConfidence: try container.decodeIfPresent(
                Double.self,
                forKey: .minimumConfidence
            ) ?? AutoAnswerPolicy.defaultMinimumConfidence,
            neverAutoTools: try container.decodeIfPresent(
                [String].self,
                forKey: .neverAutoTools
            ) ?? []
        )
    }

    /// Whether this tool can never be auto-answered.
    ///
    /// Matching is case- and whitespace-insensitive. Tool names are written by hand into a
    /// JSON file and read back from adapter payloads that spell them however the agent
    /// does (`Bash`, `bash`), and the two ways this can be wrong are not symmetric: a
    /// never-list that matches too broadly costs a prompt, one that matches too narrowly
    /// costs the silent approval the user explicitly asked to prevent.
    ///
    /// A blank tool name is forbidden outright. It should be unreachable —
    /// `ReasonerContext.toolName` is non-optional and question requests carry a synthetic
    /// name — but a request nobody can name is not one to answer silently, and no entry a
    /// user could write would ever match it.
    public func forbidsAutoAnswer(_ toolName: String) -> Bool {
        let wanted = Self.normalized(toolName)
        guard !wanted.isEmpty else { return true }
        return neverAutoTools.contains { Self.normalized($0) == wanted }
    }

    /// The filter's whole decision, for one assessed request.
    ///
    /// The clauses are evaluated in the order the policy states them — decided, routine,
    /// confident enough, not on the never-list — so the reason a request was declined is
    /// deterministic rather than dependent on which check happened to run first. A request
    /// that fails several clauses reports the first, which is also the most fundamental:
    /// "there was no decision" is a better answer than "the tool is on your list" when
    /// both are true.
    ///
    /// Note what is absent: no case reads the request's own text, the agent's identity, or
    /// anything else that could vary the answer for the same assessment. This function is
    /// pure and total, which is what lets the verdict matrix in the tests stand as the
    /// complete specification of when TapQ answers for you.
    public func decision(
        for assessment: ReasonerAssessment,
        toolName: String
    ) -> AutoAnswerVerdict {
        switch assessment.outcome {
        case .abstained(let reason):
            return .ask(AutoAnswerRefusal(abstention: reason))
        case .decided(let decision):
            guard decision.riskTier == .routine else { return .ask(.notRoutine) }
            guard decision.confidence >= minimumConfidence else {
                return .ask(.belowMinimumConfidence)
            }
            guard !forbidsAutoAnswer(toolName) else { return .ask(.neverAutoTool) }
            return .autoAllow
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
