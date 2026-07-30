import Foundation
import TapQContracts

/// Why one approval ended up with no usable stage-2 decision.
///
/// A closed set, because it is what a shadow-review log aggregates: "the model was slow"
/// and "the model was unsure" are different findings, and both are different from "there
/// was no answer at all". Every case leads to the same behavior — the deterministic
/// requirement stands — so this names the reason, never the outcome.
public enum ReasonerAbstention: String, Sendable, Equatable, CaseIterable {
    /// `assess(_:)` returned `nil`: no model, a backend error, a guardrail refusal, an
    /// unreadable answer, or the backend's own internal timeout.
    case reasonerAbstained = "reasoner_abstained"
    /// A decision arrived, but its confidence was below `ReasonerConfig.minConfidence`.
    /// The contract puts this filter on the caller, and this is that caller.
    case lowConfidence = "low_confidence"
    /// The outer bound fired before `assess(_:)` returned anything at all. Distinct from
    /// `reasonerAbstained` on purpose: a backend that ignores its own budget is an
    /// operational fact worth seeing in the log.
    case timedOut = "timeout"
}

/// One stage-2 assessment as the runtime observed it: a usable decision or a named
/// abstention, plus what it cost.
public struct ReasonerAssessment: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case decided(ReasonerDecision)
        case abstained(ReasonerAbstention)
    }

    public let outcome: Outcome
    /// Wall-clock time from the call to `assess(_:)` until this result, including any
    /// time spent past the backend's own budget waiting for the outer bound.
    public let latencyMilliseconds: Int

    public init(outcome: Outcome, latencyMilliseconds: Int) {
        self.outcome = outcome
        self.latencyMilliseconds = latencyMilliseconds
    }

    /// The decision, if this assessment produced one that survived the confidence filter.
    public var decision: ReasonerDecision? {
        if case .decided(let decision) = outcome { return decision }
        return nil
    }

    public var abstention: ReasonerAbstention? {
        if case .abstained(let reason) = outcome { return reason }
        return nil
    }
}

/// The caller half of the stage-2 contract: bound the model, discard what is not
/// confident enough, and price what is left as a confirmation requirement.
///
/// Portable on purpose. The only backend that exists lives behind `canImport
/// (FoundationModels)` and is not compiled on the machine that gates merges, so a bound
/// implemented next to it would be neither built nor tested there. Everything that
/// decides whether a *failing* reasoner is safe — the outer deadline, the confidence
/// filter, the escalation-only merge, the voice degradation — is here instead, where the
/// full test suite reaches it on every platform.
public enum ReasonerEscalation {
    /// Grace added to `ReasonerConfig.timeoutSeconds` for the outer bound.
    ///
    /// `assess(_:)` is contracted to bound itself, so this deadline is a backstop, not
    /// the budget: firing it first would turn every well-behaved timeout into
    /// `timedOut` and hide the backend's own reason. A quarter second is enough for a
    /// bounded backend to record its abstention and return, and short enough that a
    /// backend that hangs outright still costs the user a fixed, small wait.
    public static let outerBoundGraceSeconds = 0.25

    /// Runs one assessment under a hard wall-clock bound and applies the confidence
    /// filter the contract assigns to callers.
    ///
    /// Returns `abstained` for every failure shape there is: `nil` from the reasoner, a
    /// decision the config is not confident enough to use, and a call that never comes
    /// back at all. None of them can produce a decision, so none of them can raise — or
    /// lower — what the user has to do.
    public static func assess(
        _ context: ReasonerContext,
        using reasoner: any ContextReasoning,
        under config: ReasonerConfig
    ) async -> ReasonerAssessment {
        let started = ContinuousClock.now
        let bounded = await ReasonerDeadline.run(
            seconds: config.timeoutSeconds + outerBoundGraceSeconds
        ) {
            await reasoner.assess(context)
        }
        let latency = milliseconds(from: started, to: .now)

        switch bounded {
        case .completed(.some(let decision)):
            // The contract puts `minConfidence` on the caller: an unsure decision is
            // discarded here and treated exactly like `nil`, so it never reaches
            // `effectiveConfirmation(deterministic:under:)`.
            guard decision.confidence >= config.minConfidence else {
                return .init(outcome: .abstained(.lowConfidence), latencyMilliseconds: latency)
            }
            return .init(outcome: .decided(decision), latencyMilliseconds: latency)
        case .completed(.none):
            return .init(outcome: .abstained(.reasonerAbstained), latencyMilliseconds: latency)
        case .timedOut:
            return .init(outcome: .abstained(.timedOut), latencyMilliseconds: latency)
        case .cancelled:
            return .init(outcome: .abstained(.reasonerAbstained), latencyMilliseconds: latency)
        }
    }

    /// What the user must actually do, given a decision that survived `assess(_:)`.
    ///
    /// `nil` — every abstention, every failure, and `.off` — yields `deterministic`
    /// unchanged, which is the whole safety property: the reasoner's absence is
    /// indistinguishable from today.
    ///
    /// `voiceAvailable` degrades a `gestureAndVoice` request to `doubleGesture` when
    /// there is no voice channel to confirm through (`--no-voice`, or speech
    /// authorization the user declined). Without the degradation the requirement could
    /// not be met at all and the request would sit until it timed out to `.ask` —
    /// technically safe, but it would turn "this looks risky" into "this cannot be
    /// approved hands-free", which is a worse answer than asking for the strongest
    /// confirmation the device can still collect. The degradation applies only to what
    /// the *reasoner* asked for: the deterministic requirement is merged in afterwards,
    /// so this can never return something weaker than `deterministic`.
    public static func requiredConfirmation(
        for decision: ReasonerDecision?,
        deterministic: RequiredConfirmation = .standard,
        under config: ReasonerConfig,
        voiceAvailable: Bool
    ) -> RequiredConfirmation {
        guard let decision else { return deterministic }
        let asked = decision.effectiveConfirmation(deterministic: .standard, under: config)
        let collectable = (asked == .gestureAndVoice && !voiceAvailable)
            ? RequiredConfirmation.doubleGesture
            : asked
        return RequiredConfirmation.strongest(deterministic, collectable)
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: end).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        return Int(milliseconds.rounded())
    }
}
