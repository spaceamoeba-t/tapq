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
