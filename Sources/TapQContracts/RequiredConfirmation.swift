import Foundation

/// How much confirmation a pending request must collect before it can be approved.
///
/// Cases are ordered weakest-to-strongest and `standard` is the floor: it is exactly
/// today's deterministic behavior. Every other case *adds* a requirement, so a policy
/// that may only move a request up this ladder can never make approving easier. That is
/// the whole safety argument for the stage-2 reasoner — see `strongest(_:_:)`.
///
/// It lives in the contracts layer because both ends of that argument need it: the
/// context layer produces a requirement, and the interaction layer is what actually
/// collects it. Neither depends on the other, and both depend on this module.
///
/// A requirement counts approve *events*, and an approve event is already whatever the
/// detector decided one is — a paired double nod, a debounced tap, a recognized "yes".
/// Pairing windows, minimum gaps, and debounce live down there
/// (`HeadGestureConfig.doubleShakeWindowSeconds`, `minDoubleShakeGap`), not here: the
/// interaction layer enforces only how many events, and from how many channel families,
/// must arrive inside the request's existing interaction window. There is no additional
/// upper bound between the events beyond that window.
public enum RequiredConfirmation: String, CaseIterable, Sendable, Codable, Equatable {
    /// Today's behavior: a single approve event resolves the request.
    case standard
    /// Two approve events instead of one. The precedent is the existing double-shake
    /// deny, where one physical movement must not be able to confirm its own pending
    /// command; this applies the same idea to approving.
    case doubleGesture = "double_gesture"
    /// A gesture *and* a spoken confirmation, in either order: two independent input
    /// channels must agree, so neither a stray head movement nor a misheard phrase can
    /// approve alone — and neither can two of the same kind.
    case gestureAndVoice = "gesture_and_voice"

    /// Position on the weakest-to-strongest ladder. Pinned to `allCases` order by
    /// `ReasonerContractTests`; callers merge requirements by keeping the larger value
    /// and must never keep the smaller one.
    public var strength: Int {
        switch self {
        case .standard: return 0
        case .doubleGesture: return 1
        case .gestureAndVoice: return 2
        }
    }

    /// The stronger of two requirements — the only merge this contract permits. A
    /// reasoner's decision is combined with the deterministic requirement through this
    /// function, which makes "escalation only" structural rather than a convention every
    /// call site has to remember.
    public static func strongest(
        _ lhs: RequiredConfirmation,
        _ rhs: RequiredConfirmation
    ) -> RequiredConfirmation {
        lhs.strength >= rhs.strength ? lhs : rhs
    }
}
