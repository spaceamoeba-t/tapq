import Foundation

/// Which stage-2 reasoning backend a runtime instance was asked to run.
///
/// Deliberately separate from `ReasonerMode`: a provider names *what* answers, a mode
/// names *how much its answer counts*. Keeping them apart is what makes "run Apple's
/// on-device model against live traffic and change nothing" (`apple` + `shadow`)
/// expressible at all.
///
/// The enum is meant to grow. A later local open-weights backend adds its own case here
/// — together with whatever it needs to be located, the way `--encoder-model` carries a
/// model path — rather than giving `apple` a second meaning. `off` stays the default, so
/// gaining a provider never gains a reasoner: selecting one is always an explicit act.
public enum ReasonerProvider: String, CaseIterable, Sendable, Codable, Equatable {
    /// No stage-2 reasoning. Confirmation requirements come only from deterministic
    /// policy, which is exactly today's behavior.
    case off
    /// Apple's on-device Foundation Models framework. Requires an eligible device with
    /// the model available; when it is not, hosts degrade to no reasoner rather than
    /// refusing to serve, because a missing reasoner can only mean "no escalation".
    case apple
}
