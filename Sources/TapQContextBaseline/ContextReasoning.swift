import Foundation
import TapQContracts

/// A strategy that reads the context of a pending agent action and decides whether it
/// should require *more* confirmation than the deterministic policy already asks for.
///
/// Returning `nil` means "this reasoner cannot answer" — no model available, backend
/// error, timeout, or an output that failed to parse — and the caller keeps the
/// deterministic requirement unchanged. Returning a decision is an authoritative
/// "escalate to at least this much confirmation".
///
/// The `nil` contract is load-bearing and asymmetric on purpose. A reasoner has exactly
/// one power: raising the bar. It cannot approve, cannot deny, cannot lower a
/// requirement, and cannot resolve a request. So every failure mode — crash, hang,
/// nonsense output, missing model — collapses to the same safe result as `.off`, and no
/// implementation of this protocol can make TapQ approve something it would not have
/// approved before.
///
/// Implementations are expected to bound their own latency: `ReasonerConfig
/// .timeoutSeconds` is the contract for how long an `assess(_:)` may take, and callers
/// may additionally race it against a deadline and take the timeout as `nil`.
/// Implementations must not be `@MainActor`-isolated — `assess(_:)` runs while the user
/// is mid-gesture, and occupying the UI actor would stall the very interaction it is
/// deciding about.
public protocol ContextReasoning: Sendable {
    func assess(_ context: ReasonerContext) async -> ReasonerDecision?
}

/// How a reasoner backend participates in confirmation policy at composition time.
public enum ReasonerMode: String, Sendable, Codable, Equatable {
    /// Reasoner not consulted. Confirmation requirements come only from deterministic
    /// policy.
    case off
    /// Reasoner runs on eligible requests and its decisions are recorded as diagnostics,
    /// but the confirmation actually demanded is unchanged. The validation posture:
    /// measure the model against real traffic with zero behavior risk.
    case shadow
    /// Reasoner decisions raise the confirmation requirement for the request.
    /// Abstentions, failures, timeouts, and sub-threshold confidence all fall back to
    /// the deterministic requirement, so `primary` differs from `shadow` only where the
    /// model is both available and confident.
    case primary
}

/// Tunable knobs for the stage-2 reasoning layer.
///
/// The tier-to-confirmation mapping is escalation-only by construction:
/// `RequiredConfirmation.standard` is the floor of the ladder and is exactly today's
/// behavior, so whatever a knob is set to, the result is at least as strict as the
/// deterministic policy. There is deliberately no knob that weakens a requirement, skips
/// confirmation, or auto-approves — `routine` is fixed at `.standard` for that reason.
///
/// Values are validated at construction and at decode, and every out-of-range value
/// resolves toward "behave exactly like today" rather than toward more model influence.
/// Properties are `let`: a config is a decided policy, and mutating one in place after a
/// reasoner was built with it would leave the two disagreeing.
public struct ReasonerConfig: Sendable, Codable, Equatable {
    /// Wall-clock budget for one `assess(_:)` call. Exceeding it must be treated as
    /// `nil` (fall through), never as a reason to wait — the user is holding a gesture.
    /// Negative and non-finite values become `0`, which callers read as an immediate
    /// timeout: the reasoner abstains and deterministic behavior stands.
    public let timeoutSeconds: Double
    /// Callers discard decisions whose `confidence` is below this and treat them exactly
    /// like `nil`: an unsure model leaves deterministic behavior alone. Clamped to
    /// `0...1`; non-finite values become `1`, the setting under which nothing qualifies.
    public let minConfidence: Double
    /// Confirmation demanded when a decision lands on `RiskTier.sensitive`.
    public let sensitiveConfirmation: RequiredConfirmation
    /// Confirmation demanded when a decision lands on `RiskTier.destructive`. The
    /// default mirrors the existing double-shake deny: the most consequential commands
    /// already carry a doubling requirement.
    public let destructiveConfirmation: RequiredConfirmation

    public init(
        timeoutSeconds: Double = 2.0,
        minConfidence: Double = 0.5,
        sensitiveConfirmation: RequiredConfirmation = .standard,
        destructiveConfirmation: RequiredConfirmation = .doubleGesture
    ) {
        self.timeoutSeconds = timeoutSeconds.isFinite ? max(0.0, timeoutSeconds) : 0.0
        self.minConfidence = minConfidence.isFinite
            ? min(1.0, max(0.0, minConfidence))
            : 1.0
        self.sensitiveConfirmation = sensitiveConfirmation
        self.destructiveConfirmation = destructiveConfirmation
    }

    enum CodingKeys: String, CodingKey {
        case timeoutSeconds = "timeout_seconds"
        case minConfidence = "min_confidence"
        case sensitiveConfirmation = "sensitive_confirmation"
        case destructiveConfirmation = "destructive_confirmation"
    }

    /// Tolerant decoding, mirroring `HeadGestureConfig`: a persisted config written
    /// before a knob existed still decodes, with absent keys taking today's defaults
    /// instead of throwing away the whole config. Routes through the initializer so
    /// stored values are clamped exactly like constructed ones.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReasonerConfig()
        self.init(
            timeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
                ?? defaults.timeoutSeconds,
            minConfidence: try c.decodeIfPresent(Double.self, forKey: .minConfidence)
                ?? defaults.minConfidence,
            sensitiveConfirmation: try c.decodeIfPresent(
                RequiredConfirmation.self,
                forKey: .sensitiveConfirmation
            ) ?? defaults.sensitiveConfirmation,
            destructiveConfirmation: try c.decodeIfPresent(
                RequiredConfirmation.self,
                forKey: .destructiveConfirmation
            ) ?? defaults.destructiveConfirmation
        )
    }

    /// The confirmation this configuration asks for at a tier. `routine` always maps to
    /// `.standard` — an unremarkable action never changes what the user has to do.
    ///
    /// This is the only place tiers become requirements; callers still merge the result
    /// with the deterministic requirement through `RequiredConfirmation.strongest(_:_:)`
    /// rather than substituting it.
    public func confirmation(for tier: RiskTier) -> RequiredConfirmation {
        switch tier {
        case .routine: return .standard
        case .sensitive: return sensitiveConfirmation
        case .destructive: return destructiveConfirmation
        }
    }
}
