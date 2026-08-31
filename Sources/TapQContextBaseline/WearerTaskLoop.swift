import Foundation
import TapQContracts

/// How one task ended, in the word the record keeps.
///
/// Five, and every one of them is audible except the two that cannot be: a run whose voice
/// pipe just broke has nothing left to speak with, and a run being shut down has nobody left
/// to speak to. Everything else the wearer hears.
public enum WearerTaskOutcome: String, Sendable, Equatable {
    /// The model called `finish`; its summary was spoken.
    case finished
    /// The step cap was reached without a `finish`. TapQ said so out loud.
    case couldNotFinish = "could not finish"
    /// `ask_wearer` got no answer inside the question machinery's own deadline. TapQ said so
    /// out loud and stopped.
    case unanswered
    /// A cloud call failed. Nothing is spoken here — the voice latch speaks its own notice,
    /// and a second sentence from TapQ would be a degraded answer on a path whose whole
    /// posture is that there is no such thing.
    case broken
    /// The voice session or the runtime ended under the task. Silent by design: see
    /// ``WearerTaskLoop/cancel(reason:)``.
    case canceled
}

/// TapQ's deliberation tier: a bounded tool-executing loop that works on one goal the wearer
/// handed over (`docs/TAPQ_AGENT_PLAN.md`, Pillar C, milestone M2).
///
/// ## Two lanes, split by who is waiting
///
/// - **The task lane** (``startTask(goal:)``, the `start_task` seam) runs *off* the voice
///   turn. The call returns an acknowledgment immediately and the loop works in the
///   background for up to ``taskStepCap`` steps, speaking only when it has something to say.
///   One at a time: a goal offered while one is running is refused out loud, per
///   ``TapQContracts/WearerTaskStart/busy(spoken:)``, rather than queued behind a task the
///   wearer has probably stopped caring about.
/// - **The question lane** (``answerWorkQuestion(question:agentDisplayName:)``) is
///   `ask_about_work` folded in, which is Pillar B's one revision now that the loop exists:
///   an answer can combine transcript slices with TapQ's own memory. It runs *inside* the
///   realtime peer's tool call, which is the whole reason it is a separate lane — see the
///   bounds on ``questionStepCap`` and ``questionWallClock``.
///
/// The question lane does not take the task slot and is not refused by one. It resolves
/// nothing, declares three read-only tools, and cannot speak, ask, or queue; refusing to
/// answer a question because a background task happened to be running would be a regression
/// against the M1 behavior it replaces, for no safety gained.
///
/// ## Initiative is not here
///
/// M2 is wearer-initiated only. There is no timer, no event subscription, and no path by
/// which this object starts a task nobody asked for — the two entry points above are both
/// calls from the voice surface. Standing directives and boundary-review invocation are M3.
///
/// ## Failure posture, which is not negotiable
///
/// A cloud call that fails anywhere in either lane is a voice-pipeline failure: the task lane
/// reports it through ``onLoopBroken`` (the composition latches it exactly as it latches
/// narration and `ask_about_work`) and says nothing; the question lane returns
/// ``TapQContracts/WorkQuestionOutcome/failed(_:)`` and the provider does the same. A local
/// file that will not open is the other class entirely: error-level diagnostics, the model
/// told plainly so it can be honest, and the session alive.
///
/// Diagnostics carry counts, names, and lengths. Never a goal, never an excerpt, never a
/// sentence, never the key.
@MainActor public final class WearerTaskLoop {
    /// `nonisolated` throughout the constants below, for the reason
    /// ``WearerConversationStore/fileName`` is: they are read at call sites that are not on
    /// the main actor — a default argument, the recall renderer — and an isolated constant
    /// would make a plain string into a hop.
    ///
    /// Six, from the plan. It is a cap on *model turns*, so the worst case is six times the
    /// client's own per-call timeout — acceptable because nobody is parked: the wearer heard
    /// an acknowledgment and went back to what they were doing.
    public nonisolated static let taskStepCap = 6

    /// Three. Enough to read the agent's transcript, search TapQ's memory, and answer from
    /// both — which is exactly the capability the fold-in exists to add — and no more,
    /// because the realtime peer is holding its tool call for every one of them.
    public nonisolated static let questionStepCap = 3

    /// The question lane's wall clock: past this, the loop stops asking for another turn.
    ///
    /// M1's direct path held the peer for one model call under a 15 s timeout. Three calls
    /// cannot honor that, so this is the honest replacement rather than a pretence: after
    /// 20 s no further turn is requested, which bounds the hold at 20 s plus one in-flight
    /// call — about 35 s worst case, against a typical two calls of a few seconds each. The
    /// alternative considered and rejected was answering the peer immediately and speaking
    /// later: it would have left the realtime model free to talk over TapQ's own answer.
    public nonisolated static let questionWallClock: TimeInterval = 20

    /// Spoken when a goal arrives while one is already running.
    public nonisolated static let busyNotice =
        "I'm still on the last thing you asked — I'll tell you when it's done."

    /// Spoken when `start_task` arrives with no goal in it. The same sentence a dictation
    /// that captured silence gets, because from the wearer's side it is the same event.
    public nonisolated static let emptyGoalNotice = "I didn't catch that — say it again."

    /// What the wearer hears when the step cap runs out, per the plan's "never silent
    /// abandonment". The goal is read back so they know *which* thing stalled.
    public nonisolated static func couldNotFinishNotice(goal: String) -> String {
        "I couldn't finish: " + spokenGoal(goal)
    }

    /// What the wearer hears when they never answered an `ask_wearer`.
    public nonisolated static func unansweredNotice(goal: String) -> String {
        "I asked you something and didn't hear back, so I've stopped: " + spokenGoal(goal)
    }

    /// The question lane's own last resort: no `finish`, and nothing local to blame.
    public nonisolated static let couldNotAnswerNotice =
        "I couldn't work that out in time — ask me again."

    /// The acknowledgment. It reads the goal back, shortened, for the reason the dictation
    /// read-back does: a wearer who cannot see a screen has no other way to find out that
    /// TapQ heard something different from what they said. The *recorded* goal is the full
    /// one; only the spoken copy is condensed.
    public nonisolated static func acceptedNotice(goal: String) -> String {
        "On it — " + spokenGoal(goal)
    }

    /// A wearer sentence in the length a spoken read-back can carry.
    ///
    /// Shortening a read-back is the established rule and this is the established cap:
    /// NARRATION_MODEL_PLAN's rule 1 governs what reaches the *agent* — which is never
    /// shortened, here or anywhere — and this reaches nobody but the wearer's ear. Public
    /// because the composition's `queue_instruction` announcement reads a sentence back the
    /// same way, and two read-backs at two lengths would be two behaviors.
    public nonisolated static func spokenGoal(_ goal: String) -> String {
        SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(goal),
            limit: SpokenSummary.sentenceCharacterLimit
        )
    }

    private let model: any WearerTaskReasoning
    private let surfaces: WearerTaskSurfaces
    private let stepCap: Int
    private let questionCap: Int
    private let wallClock: TimeInterval
    private let diagnostics: TapQDiagnosticEmitter

    /// A cloud call inside the loop failed. Wired by the composition to the same
    /// `VoiceBrokenState` latch `onNarrationFailed`, `onScriptedSpeechUndeliverable`, and
    /// `onWorkAnswerFailed` reach.
    ///
    /// Its own hook rather than a reuse of `onWorkAnswerFailed`, for the reason that one is
    /// separate from the other two: an operator reading the log has to know whether TapQ
    /// could not be heard, could not understand the wearer, could not answer a question, or
    /// could not think.
    public var onLoopBroken: (@MainActor (String) -> Void)?

    private var running: Task<Void, Never>?
    private var runningGoal: String?

    public init(
        model: any WearerTaskReasoning,
        surfaces: WearerTaskSurfaces,
        stepCap: Int = WearerTaskLoop.taskStepCap,
        questionStepCap: Int = WearerTaskLoop.questionStepCap,
        questionWallClock: TimeInterval = WearerTaskLoop.questionWallClock,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.model = model
        self.surfaces = surfaces
        self.stepCap = max(1, stepCap)
        self.questionCap = max(1, questionStepCap)
        self.wallClock = questionWallClock
        self.diagnostics = TapQDiagnosticEmitter(category: "WearerTask", sink: diagnosticSink)
    }

    /// Whether a task is running right now. For tests and for the composition's teardown.
    public var isBusy: Bool { running != nil }

    // MARK: - The task lane

    /// Takes a goal, or says why it did not.
    ///
    /// Returns as soon as the task is *started*, never when it is done: the wearer is at the
    /// end of a voice turn and the realtime session must not be parked while TapQ thinks.
    public func begin(goal: String) -> WearerTaskStart {
        let goal = SpokenSummaryText.normalized(goal)
        guard !goal.isEmpty else {
            // The contract has two cases and this is neither's name, but it is the right
            // behavior for both halves of what `busy` promises: nothing was started, and the
            // wearer hears one sentence saying so. Flagged in the M2 report.
            diagnostics.record("task.rejected", fields: ["reason": "empty_goal"])
            return .busy(spoken: Self.emptyGoalNotice)
        }
        guard running == nil else {
            diagnostics.record("task.busy", fields: ["goal_length": "\(goal.count)"])
            return .busy(spoken: Self.busyNotice)
        }

        // Recorded before the first turn, and that ordering is the whole of "a restart
        // mid-task loses the loop but not the record of what was asked". A goal recorded at
        // the end would be a goal a crash erases.
        surfaces.recordTask(goal, Self.startedOutcome)
        diagnostics.record("task.started", fields: [
            "goal_length": "\(goal.count)",
            "steps": "\(stepCap)",
        ])
        runningGoal = goal
        // Assigned before any suspension point, so `isBusy` is true the instant this
        // returns and a second goal in the same turn is refused rather than raced.
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTask(goal: goal)
            self.running = nil
            self.runningGoal = nil
        }
        return .accepted(spoken: Self.acceptedNotice(goal: goal))
    }

    /// Ends the running task without speaking.
    ///
    /// Silent by design, and the design is that both callers are endings. The voice session
    /// closing and the runtime shutting down both take away the channel a sentence would go
    /// out on — `BackendSpeechSink` is being torn down in the same `defer` — so a spoken
    /// "I've stopped" would at best be dropped and at worst be half-said over a closing
    /// pipe. The record still gets the outcome, so a wearer who asks tomorrow finds out.
    public func cancel(reason: String = "session ended") {
        guard let task = running else { return }
        diagnostics.record("task.canceled", fields: ["reason": reason])
        task.cancel()
        running = nil
        runningGoal = nil
    }

    private func runTask(goal: String) async {
        let started = ContinuousClock.now
        var steps: [WearerTaskStep] = []

        for step in 1...stepCap {
            guard !Task.isCancelled else {
                return end(goal: goal, outcome: .canceled, steps: steps.count, started: started)
            }
            let decision: WearerTaskDecision
            do {
                decision = try await model.decide(WearerTaskTurnRequest(
                    goal: goal,
                    mode: .task,
                    steps: steps,
                    stepsRemaining: stepCap - step + 1
                ))
            } catch {
                return breakVoice(goal: goal, error: error, step: step,
                                  steps: steps.count, started: started)
            }
            guard !Task.isCancelled else {
                return end(goal: goal, outcome: .canceled, steps: steps.count, started: started)
            }
            diagnostics.record("task.step", fields: [
                "n": "\(step)",
                "tool": decision.toolName,
            ])

            switch decision {
            case .finish(let summary):
                surfaces.speak(summary)
                return end(goal: goal, outcome: .finished, steps: step, started: started)

            case .askWearer(let question):
                let answer = await surfaces.askWearer(question)
                guard !Task.isCancelled else {
                    return end(goal: goal, outcome: .canceled, steps: step, started: started)
                }
                guard answer != .unanswered else {
                    // The bound on a pause. The question machinery has its own deadline
                    // (`InteractionBudget.total`), and a wearer who let it pass has moved on;
                    // resuming into a seventh turn they are not listening to would be the
                    // loop talking to itself. Audible, because "never silent abandonment"
                    // covers this ending too.
                    diagnostics.record("task.ask_unanswered", fields: ["n": "\(step)"])
                    surfaces.speak(Self.unansweredNotice(goal: goal))
                    return end(goal: goal, outcome: .unanswered, steps: step, started: started)
                }
                steps.append(WearerTaskStep(
                    tool: decision.toolName,
                    arguments: question,
                    result: answer == .yes
                        ? "The wearer answered yes."
                        : "The wearer answered no."
                ))

            case .speak(let text):
                surfaces.speak(text)
                steps.append(WearerTaskStep(
                    tool: decision.toolName,
                    arguments: text,
                    result: "Spoken to the wearer."
                ))

            default:
                steps.append(perform(decision, speaking: true).step)
            }
        }

        // The cap, spoken. Reached only when the model spent every turn on something other
        // than `finish`, having been told on each of them how many were left.
        surfaces.speak(Self.couldNotFinishNotice(goal: goal))
        end(goal: goal, outcome: .couldNotFinish, steps: stepCap, started: started)
    }

    // MARK: - The question lane

    /// Answers one `ask_about_work` question through the loop, so the answer can draw on the
    /// agent's transcript *and* TapQ's own memory (`docs/TAPQ_AGENT_PLAN.md`, Pillar B's one
    /// revision).
    ///
    /// The three outcomes are M1's, unchanged, and so is what the wearer hears in each:
    /// ``TapQContracts/WorkQuestionOutcome/answered(_:)`` is spoken verbatim,
    /// ``TapQContracts/WorkQuestionOutcome/unavailable(_:)`` is spoken and the session lives,
    /// ``TapQContracts/WorkQuestionOutcome/failed(_:)`` says nothing and breaks the run's
    /// voice. What changed is where the slices come from and how many model calls it takes.
    ///
    /// One widening, recorded honestly: `unavailable` now also carries "I couldn't work that
    /// out in time", which is not a transcript that could not be read. It is the right
    /// *handling* — spoken, error-logged, session alive — and the alternative, `failed`,
    /// would break the wearer's voice channel over a slow think, which the ratified
    /// two-class posture reserves for cloud calls that actually failed.
    public func answerWorkQuestion(
        question: String,
        agentDisplayName: String?
    ) async -> WorkQuestionOutcome {
        let question = SpokenSummaryText.normalized(question)
        diagnostics.record("task.question", fields: [
            "question_length": "\(question.count)",
            "agent_named": "\(agentDisplayName?.isEmpty == false)",
            "steps": "\(questionCap)",
        ])
        guard !question.isEmpty else {
            diagnostics.record("task.question_unavailable", level: .error,
                               fields: ["reason": "empty"])
            return .unavailable(TranscriptQuestionAnswerer.emptyNotice)
        }

        let started = ContinuousClock.now
        var steps: [WearerTaskStep] = []
        /// The last local problem a read reported, kept so a lane that runs out of room can
        /// say the true thing rather than the generic one.
        var lastLocalNotice: String?

        for step in 1...questionCap {
            if step > 1, started.seconds(elapsedTo: .now) >= wallClock {
                diagnostics.record("task.question_deadline", level: .warning, fields: [
                    "n": "\(step - 1)",
                    "budget_s": "\(Int(wallClock))",
                ])
                break
            }
            let decision: WearerTaskDecision
            do {
                decision = try await model.decide(WearerTaskTurnRequest(
                    goal: question,
                    mode: .question,
                    agentDisplayName: agentDisplayName,
                    steps: steps,
                    stepsRemaining: questionCap - step + 1
                ))
            } catch {
                let reason = (error as? NarrationFailure)?.reason ?? "unknown"
                diagnostics.record("task.question_failed", level: .error, fields: [
                    "n": "\(step)",
                    "reason": reason,
                ])
                // Deliberately not `onLoopBroken`: the provider breaks on a `failed`
                // outcome through `onWorkAnswerFailed`, which is the seam an operator
                // already reads for this question. Latching here as well would report one
                // failure twice.
                return .failed(reason)
            }
            diagnostics.record("task.step", fields: [
                "n": "\(step)",
                "tool": decision.toolName,
            ])

            if case .finish(let summary) = decision {
                diagnostics.record("task.question_answered", fields: [
                    "steps": "\(step)",
                    "length": "\(summary.count)",
                ])
                return .answered(summary)
            }
            // Nothing else in this lane can speak: `speak`, `ask_wearer`, and
            // `queue_instruction` are not declared for it, and a call for one of them was
            // already rejected as a protocol failure by the decoder.
            let run = perform(decision, speaking: false)
            if let failure = run.output.localFailure {
                lastLocalNotice = failure.wearerNotice
            }
            steps.append(run.step)
        }

        let notice = lastLocalNotice ?? Self.couldNotAnswerNotice
        diagnostics.record("task.question_unavailable", level: .error, fields: [
            "reason": lastLocalNotice == nil ? "no_finish" : "local",
            "steps": "\(steps.count)",
        ])
        return .unavailable(notice)
    }

    // MARK: - Tool execution

    /// Runs one non-terminal, non-speaking tool and renders the step the next turn reads.
    ///
    /// Both halves come back: the task lane uses the step, and the question lane also needs
    /// the raw output, because a local failure's sentence is the one it will speak if it
    /// runs out of room to say anything better.
    ///
    /// - Parameter speaking: whether an ``WearerTaskToolOutput/announce`` may go out. False
    ///   in the question lane, which speaks nothing itself — its one sentence is the answer
    ///   the provider speaks.
    private func perform(
        _ decision: WearerTaskDecision,
        speaking: Bool
    ) -> (step: WearerTaskStep, output: WearerTaskToolOutput) {
        let arguments: String
        let output: WearerTaskToolOutput
        switch decision {
        case .searchMemory(let query):
            arguments = query
            output = surfaces.searchMemory(query)
        case .readTranscript(let agent, let query):
            arguments = agent.map { "\($0), \(query)" } ?? query
            output = surfaces.readTranscript(agent, query)
        case .getStatus:
            arguments = ""
            output = surfaces.status()
        case .queueInstruction(let agent, let text):
            arguments = agent.map { "\($0), \(text)" } ?? text
            output = surfaces.queueInstruction(agent, text)
        case .speak, .askWearer, .finish:
            // Unreachable: the three are handled by the task lane's own switch and are
            // undeclared in the question lane. Rendered rather than trapped, because a trap
            // inside a voice path is the one failure with no diagnostic at all.
            arguments = ""
            output = .ok("That tool is not available here.")
        }

        if let failure = output.localFailure {
            // Error, not warning: the wearer asked for something and is going to get a
            // thinner answer than they wanted because a file on this machine would not open.
            diagnostics.record("task.tool_unavailable", level: .error, fields: [
                "tool": decision.toolName,
                "reason": failure.reason,
            ])
        }
        if speaking, let announce = output.announce {
            surfaces.speak(announce)
        }
        return (
            WearerTaskStep(
                tool: decision.toolName,
                arguments: arguments,
                result: output.text
            ),
            output
        )
    }

    // MARK: - Endings

    private func end(
        goal: String,
        outcome: WearerTaskOutcome,
        steps: Int,
        started: ContinuousClock.Instant
    ) {
        surfaces.recordTask(goal, outcome.rawValue)
        diagnostics.record("task.finished", fields: [
            "steps": "\(steps)",
            "outcome": outcome.rawValue,
            "duration_ms": Self.milliseconds(from: started),
        ])
    }

    private func breakVoice(
        goal: String,
        error: any Error,
        step: Int,
        steps: Int,
        started: ContinuousClock.Instant
    ) {
        let reason = (error as? NarrationFailure)?.reason ?? "unknown"
        diagnostics.record("task.model_failed", level: .error, fields: [
            "n": "\(step)",
            "reason": reason,
        ])
        // Nothing is spoken. The latch this reaches speaks its own notice, and a sentence
        // from TapQ saying "I couldn't think" would be the degraded half-agent the posture
        // forbids.
        onLoopBroken?(reason)
        end(goal: goal, outcome: .broken, steps: steps, started: started)
    }

    /// The word the record keeps for a task that has begun but not ended. Its own constant
    /// because a restart looking at the file has to be able to tell a task that was
    /// interrupted from one that finished, and the difference is this string.
    public nonisolated static let startedOutcome = "started"

    private nonisolated static func milliseconds(from start: ContinuousClock.Instant) -> String {
        let components = start.duration(to: .now).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        return String(format: "%.0f", milliseconds)
    }
}

extension WearerTaskLoop: WearerTaskStarting {
    /// The committed seam (``TapQContracts/WearerTaskStarting``).
    ///
    /// `nonisolated` and `async` so a caller on any actor can reach it: the body does nothing
    /// but hop to the main actor, where every surface behind the loop already lives. Written
    /// this way rather than as a bare `@MainActor` witness so the isolation of the
    /// conformance is stated here rather than inferred.
    public nonisolated func startTask(goal: String) async -> WearerTaskStart {
        await MainActor.run { self.begin(goal: goal) }
    }
}

extension ContinuousClock.Instant {
    /// Seconds from this instant to `other`. The loop's own wall clock; the interaction
    /// layer's `seconds(after:)` reads the other way round and lives in another target.
    func seconds(elapsedTo other: ContinuousClock.Instant) -> TimeInterval {
        let parts = duration(to: other).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
