/// The seam between the realtime voice surface and TapQ's deliberation loop
/// (agent-plan Pillar C, milestone M2).
///
/// The realtime intent model keeps handling latency-critical, single-step
/// intents directly — the reflex tier. Anything that needs knowledge or
/// multiple steps is handed across this seam as a goal. The call returns
/// immediately with a sentence for the wearer; the loop itself runs off the
/// voice turn and speaks again on the scripted channel only when it has
/// something to say.
///
/// One task runs at a time. A goal offered while one is running is not
/// queued — the wearer hears that TapQ is busy and decides what to do.
/// The caller speaks whichever sentence comes back, verbatim.
public enum WearerTaskStart: Sendable, Equatable {
    /// The loop took the task. The sentence acknowledges the goal out loud.
    case accepted(spoken: String)
    /// A task is already running; the goal was not queued. Spoken as-is.
    case busy(spoken: String)
}

/// Implemented by the deliberation loop; consumed by the voice surface.
/// The `start_task` realtime tool is declared only when an implementation
/// is composed — on the Apple path none is, and the tool does not exist.
public protocol WearerTaskStarting: Sendable {
    func startTask(goal: String) async -> WearerTaskStart
}

/// What the follow-up book did with one voice request, and the sentence the
/// wearer hears for it (agent-plan "Initiative (M3, the guarded step)",
/// scoped to one-shot follow-ups 2026-08-31).
///
/// Every case carries a sentence and the caller speaks it verbatim, exactly
/// as ``WearerTaskStart`` does — the composition decides what TapQ says
/// about its own memory, and a provider that composed sentences here would
/// be describing state it does not model. The cases are distinct so that
/// the *model's* record of the call can differ from the wearer's sentence,
/// and so an operator can count them.
///
/// A replacement is its own case because it must be its own sentence: a
/// wearer who sets a second follow-up for the same agent and hears the
/// ordinary acknowledgment will believe they have two.
public enum WearerFollowupAcknowledgment: Sendable, Equatable {
    /// Set, with nothing pending for that agent before.
    case noted(spoken: String)
    /// Set over one that was already pending for that agent.
    case replaced(spoken: String)
    /// Dropped. Either it was pending, or it had come due and its action was
    /// aborted before it landed.
    case dropped(spoken: String)
    /// Nothing was pending for that agent, so nothing was dropped.
    case nothingPending(spoken: String)
    /// A legal request that could not run: a name nothing answers to, or an
    /// empty sentence. Refused out loud; the session survives it, exactly as
    /// it survives an unknown-agent dictation.
    case refused(spoken: String)

    /// The sentence, whichever case this is.
    public var spoken: String {
        switch self {
        case let .noted(spoken), let .replaced(spoken), let .dropped(spoken),
             let .nothingPending(spoken), let .refused(spoken):
            return spoken
        }
    }
}

/// Implemented by the follow-up book's composition; consumed by the voice
/// surface. The `set_followup` and `cancel_followup` realtime tools are
/// declared only where an implementation is composed — the same structural
/// gate `start_task` has, on its own seam, so a run may have a deliberation
/// loop and no follow-up book or the reverse.
///
/// Two methods rather than one with a flag: setting a follow-up and dropping
/// one are two acts, and the one place a model's mistake is worst is a tool
/// that both creates and destroys standing state depending on an argument.
public protocol WearerFollowupScheduling: Sendable {
    /// Holds one sentence until that agent's next finished run.
    func setFollowup(agent: String, instruction: String) async
        -> WearerFollowupAcknowledgment
    /// Drops whatever is waiting on that agent, wherever it currently is.
    func cancelFollowup(agent: String) async -> WearerFollowupAcknowledgment
}
