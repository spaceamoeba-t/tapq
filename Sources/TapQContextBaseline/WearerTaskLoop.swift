import Foundation
import TapQContracts

/// How one task ended, in the word the record keeps.
///
/// Six, and every one of them is audible except the two that cannot be: a run whose voice
/// pipe just broke has nothing left to speak with, and a run being shut down has nobody left
/// to speak to. Everything else the wearer hears.
public enum WearerTaskOutcome: String, Sendable, Equatable {
    /// The model called `finish`; its summary was spoken.
    case finished
    /// The model called `cannot_do`: the goal needed something no composed tool reaches, and
    /// TapQ said so out loud, naming the limit.
    ///
    /// Its own word rather than ``finished``, added 2026-08-30. A wearer asking tomorrow what
    /// happened to a goal has to find out that TapQ *declined* it, not that it completed —
    /// and an operator counting refusals is counting the goals TapQ is asked for and cannot
    /// serve, which is the one number that says where the next tool belongs. ``couldNotFinish``
    /// could not stand in either: that is a task that ran out of turns trying.
    case refused
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
/// ## Three lanes, split by who is waiting
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
/// - **The follow-up lane** (``runFollowup(_:boundary:surfaces:)``, M3's guarded step) runs
///   with nobody having spoken to TapQ at all: a one-shot follow-up the wearer set earlier
///   has come due at an agent's finished boundary. Four steps, a minute, seven tools, and a
///   model that ends without composing an interruption — see ``followupStepCap`` and
///   ``WearerTaskMode/followup``. The lane still closes out loud when it has said nothing,
///   because the firing was announced before it ran; see
///   ``followupNothingToReportNotice``.
///
/// The question lane does not take the task slot and is not refused by one. It resolves
/// nothing, declares three read-only tools, and cannot speak, ask, or queue; refusing to
/// answer a question because a background task happened to be running would be a regression
/// against the M1 behavior it replaces, for no safety gained. The follow-up lane *does* take
/// it, and shares it with the task lane: both speak on the same channel and instruct the same
/// agents, and two of them at once would be two voices composing sentences for one wearer
/// with no idea of each other.
///
/// ## Initiative, and its one door
///
/// There is still no timer and no ambient watching: this object never wakes itself. The
/// follow-up lane is *invoked* by a gate that has already decided this boundary is one the
/// wearer asked to be woken for, and there is no follow-up in the book unless they said so or
/// a task they started registered one. No book entry, no initiative.
///
/// ## Failure posture, which is not negotiable
///
/// A cloud call that fails anywhere in the first two lanes is a voice-pipeline failure: the
/// task lane reports it through ``onLoopBroken`` (the composition latches it exactly as it
/// latches narration and `ask_about_work`) and says nothing; the question lane returns
/// ``TapQContracts/WorkQuestionOutcome/failed(_:)`` and the provider does the same. The
/// follow-up lane reports ``WearerFollowupDisposition/broke(reason:)`` and touches no latch —
/// the gate that woke it owns that, because it is the same object that refuses to wake a
/// review while the latch is already broken. A local file that will not open is the other
/// class entirely: error-level diagnostics, the model told plainly so it can be honest, and
/// the session alive.
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

    /// Four, for a follow-up review. Fewer than a task's six on purpose.
    ///
    /// A task is a goal the wearer handed over and is waiting on; a review is one sentence
    /// they said minutes ago, run against a boundary they have not seen. Every turn spent
    /// here is TapQ deciding on its own initiative how much of the wearer's model budget one
    /// unattended boundary is worth, and four is enough for the shape the follow-ups
    /// actually take: look at what happened, maybe check one other thing, then say something
    /// or queue one instruction, then end. A review that needs six steps has stopped being a
    /// follow-up and become a task the wearer did not start.
    public nonisolated static let followupStepCap = 4

    /// Sixty seconds of wall clock for a review, checked between turns.
    ///
    /// The task lane has no wall clock, because nobody is parked and its bound is the step
    /// cap. This lane has one because something *is* parked: the agent's boundary is being
    /// held while TapQ thinks about it, and a held boundary is the agent not working. Sixty
    /// seconds is four turns at the slowest per-call latency this client family has measured,
    /// so in practice the step cap binds first and this is the guard against a run of slow
    /// calls holding a boundary for minutes.
    public nonisolated static let followupWallClock: TimeInterval = 60

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

    /// What the wearer hears when a follow-up ran out of turns or of clock.
    ///
    /// Spoken, and the decision took some arguing with the lane's own "silence is the normal
    /// ending" rule. That rule is about the *model* choosing not to interrupt, which is a
    /// review working correctly. This is TapQ failing to do a thing it said out loud it would
    /// do — and a promise that quietly evaporates is worse than a sentence, because the
    /// wearer goes on believing it is still coming. The agent is named so they know which
    /// promise, and the sentence is read back so they know which follow-up.
    public nonisolated static func followupCouldNotFinishNotice(
        agent: String,
        instruction: String
    ) -> String {
        "I couldn't do the follow-up on \(agent): " + spokenGoal(instruction)
    }

    /// What the wearer hears when a review ended with nothing to tell them.
    ///
    /// The lane's silence rule is about the *model*, and it is untouched: `finish` still says
    /// nothing, and a review with nothing worth breaking a concentration for still must not
    /// invent a sentence. What 2026-09-01 changed is the other end of it. Every firing is
    /// announced before the review runs — "Claude Code finished — on your follow-up: rerun
    /// the tests" — so by the time this lane starts, TapQ has already opened its mouth about
    /// the promise and the wearer is listening for the rest. Ending silent *there* does not
    /// cost them nothing: it is indistinguishable from a review that broke, that was
    /// cancelled in the grace, or that was never run, and their only recourse is to ask.
    ///
    /// So silence is free right up to the announcement, and after it a close is owed. One
    /// short line, and said only when nothing else from the review reached them — a review
    /// that spoke a result or queued an instruction has already reported, and must not get
    /// this on top of it.
    ///
    /// Kept here beside `followupCouldNotFinishNotice` rather than on
    /// ``WearerFollowupScheduler``, which owns the *book's* sentences: this one is an ending
    /// of the lane, said by the lane, and the two endings that speak belong together.
    public nonisolated static let followupNothingToReportNotice =
        "Nothing to report on that yet."

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
    private let followupCap: Int
    private let followupClock: TimeInterval
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
    /// The follow-up lane's run, held for the same reason ``running`` is: so
    /// ``cancel(reason:)`` reaches it, and so the slot is visibly taken.
    private var runningFollowup: Task<WearerFollowupDisposition, Never>?

    public init(
        model: any WearerTaskReasoning,
        surfaces: WearerTaskSurfaces,
        stepCap: Int = WearerTaskLoop.taskStepCap,
        questionStepCap: Int = WearerTaskLoop.questionStepCap,
        questionWallClock: TimeInterval = WearerTaskLoop.questionWallClock,
        followupStepCap: Int = WearerTaskLoop.followupStepCap,
        followupWallClock: TimeInterval = WearerTaskLoop.followupWallClock,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.model = model
        self.surfaces = surfaces
        self.stepCap = max(1, stepCap)
        self.questionCap = max(1, questionStepCap)
        self.wallClock = questionWallClock
        self.followupCap = max(1, followupStepCap)
        self.followupClock = followupWallClock
        self.diagnostics = TapQDiagnosticEmitter(category: "WearerTask", sink: diagnosticSink)
    }

    /// Whether the task slot is taken right now. For tests and for the composition's
    /// teardown.
    ///
    /// One slot for both the task lane and the follow-up lane, and they share it on purpose.
    /// The two speak on the same channel and instruct the same agents, and two of them
    /// running at once would be two voices composing sentences for one wearer with no idea
    /// of each other. The question lane is not here and never was: it holds the peer's tool
    /// call, resolves nothing, and refusing an answer because a background task is running
    /// would regress M1 for no safety gained.
    public var isBusy: Bool { running != nil || runningFollowup != nil }

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
        // `isBusy`, not `running == nil`: the follow-up lane holds the same slot, so a goal
        // offered while a review is running is refused exactly as one offered during a task
        // is. Two of them speaking at once would be two voices composing sentences for one
        // wearer with no idea of each other.
        guard !isBusy else {
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
        if let followup = runningFollowup {
            // The same silence, and more emphatically: nobody asked for this review, so
            // there is nobody owed a sentence about its ending.
            diagnostics.record("followup.canceled", fields: ["reason": reason])
            followup.cancel()
            runningFollowup = nil
        }
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

            case .cannotDo(let spoken):
                // An ending, and audible like every other ending that has someone to speak
                // to. The sentence is the model's and is spoken verbatim: what TapQ cannot
                // do is a fact about this composition, and a canned sentence here would
                // either be wrong for most goals or so vague it told the wearer nothing.
                diagnostics.record("task.refused", fields: [
                    "n": "\(step)",
                    "length": "\(spoken.count)",
                ])
                surfaces.speak(spoken)
                return end(goal: goal, outcome: .refused, steps: step, started: started)

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
    ///
    /// ## One call, typically (2026-08-30)
    ///
    /// As first built the lane spent two sequential cloud calls on every question — one to
    /// decide to read the transcript, one to write the answer from it — measured live at
    /// ~1.1 s plus ~1.2–3.8 s, roughly double M1's single call, with the wearer standing
    /// there. Both lookups are *local reads over the question itself*, so nothing was being
    /// decided by the first call that the loop could not do without it. They now run before
    /// the first turn and ride it as evidence (``WearerTaskTurnRequest/evidence``), and the
    /// typical question is one call.
    ///
    /// It is not a cap. The bounds are unchanged, and a model whose pre-fetched evidence does
    /// not answer the question may still spend a turn on `search_memory` with sharper words
    /// or `read_transcript` for a different agent.
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
        /// Cloud calls actually spent. The number the fix exists to move, so it is on the
        /// line an operator reads on hardware rather than inferred from `steps`.
        var modelCalls = 0

        let evidence = prefetchQuestionEvidence(question: question, agent: agentDisplayName)
        // The transcript's sentence, and only the transcript's. A history that cannot be read
        // is what `ask_about_work` is *about* being unable to answer, so it is the honest
        // thing to say if nothing better gets said; a memory file that will not open still
        // leaves the agent's session to answer from, and speaking about TapQ's own record
        // would answer a question the wearer did not ask.
        if let notice = evidence.transcriptNotice {
            lastLocalNotice = notice
        }

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
                    evidence: evidence.steps,
                    steps: steps,
                    stepsRemaining: questionCap - step + 1
                ))
                modelCalls += 1
            } catch {
                modelCalls += 1
                let reason = (error as? NarrationFailure)?.reason ?? "unknown"
                diagnostics.record("task.question_failed", level: .error, fields: [
                    "n": "\(step)",
                    "model_calls": "\(modelCalls)",
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
                // The lane's latency line. `model_calls` is the measurement the pre-fetch
                // exists to move and `slices` is what it had to answer from; counts and
                // lengths only, as everywhere on this path.
                diagnostics.record("task.question_answered", fields: [
                    "latency_ms": Self.milliseconds(from: started),
                    "model_calls": "\(modelCalls)",
                    "slices": evidence.slices.map(String.init) ?? "none",
                    "memories": evidence.memories.map(String.init) ?? "none",
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
            "latency_ms": Self.milliseconds(from: started),
            "model_calls": "\(modelCalls)",
            "steps": "\(steps.count)",
        ])
        return .unavailable(notice)
    }

    // MARK: - The question lane's pre-fetch

    /// Both lookups an `ask_about_work` answer can draw on, run over the question itself
    /// before the lane's first model call.
    ///
    /// Through the same two surfaces the model would have called — not a second path to the
    /// same files. That is the whole of why this is safe to do ahead of the model: whatever
    /// `read_transcript` and `search_memory` would have returned for the wearer's own words
    /// is exactly what is fetched, including the failures, so the lane cannot drift from the
    /// tools it still declares.
    private struct QuestionEvidence {
        /// What rides the first turn.
        var steps: [WearerTaskStep] = []
        /// Excerpt and entry counts, when the surface reported them. Diagnostics only.
        var slices: Int?
        var memories: Int?
        /// The transcript's spoken sentence, when the history could not be read.
        var transcriptNotice: String?
    }

    private func prefetchQuestionEvidence(
        question: String,
        agent: String?
    ) -> QuestionEvidence {
        var evidence = QuestionEvidence()

        let transcript = surfaces.readTranscript(agent, question)
        evidence.slices = transcript.itemCount
        evidence.steps.append(WearerTaskStep(
            tool: WearerTaskToolName.readTranscript,
            arguments: agent.map { "\($0), \(question)" } ?? question,
            result: transcript.text
        ))
        if let failure = transcript.localFailure {
            // The two-class split, held at the pre-fetch exactly as it is held mid-lane: a
            // local file that will not open is loud in the log, honest to the model, and
            // survivable. The model is told in `text` and usually says something better than
            // the carried sentence; the sentence is what gets spoken if it does not.
            diagnostics.record("task.prefetch_unavailable", level: .error, fields: [
                "tool": WearerTaskToolName.readTranscript,
                "reason": failure.reason,
            ])
            evidence.transcriptNotice = failure.wearerNotice
        }

        let memory = surfaces.searchMemory(question)
        evidence.memories = memory.itemCount
        evidence.steps.append(WearerTaskStep(
            tool: WearerTaskToolName.searchMemory,
            arguments: question,
            result: memory.text
        ))
        if let failure = memory.localFailure {
            // Loud, and then carry on with what there is. No carried sentence: the agent's
            // history is still in hand, and "I can't read my own memory" is not an answer to
            // a question about the agent's work.
            diagnostics.record("task.prefetch_unavailable", level: .error, fields: [
                "tool": WearerTaskToolName.searchMemory,
                "reason": failure.reason,
            ])
        }

        diagnostics.record("task.question_prefetched", fields: [
            "slices": evidence.slices.map(String.init) ?? "none",
            "memories": evidence.memories.map(String.init) ?? "none",
            "chars": "\(transcript.text.count + memory.text.count)",
            "transcript_ok": "\(transcript.localFailure == nil)",
            "memory_ok": "\(memory.localFailure == nil)",
        ])
        return evidence
    }

    // MARK: - The follow-up lane

    /// Runs one one-shot follow-up that has come due (`docs/TAPQ_AGENT_PLAN.md`, "Initiative
    /// (M3, the guarded step)", scoped to one-shots 2026-08-31).
    ///
    /// This is the *only* path by which the loop does anything nobody just asked it for, and
    /// everything narrow about it is deliberate. It is entered from a gate that has already
    /// decided this boundary is one the wearer asked to be woken for; the model is asked only
    /// what to do, never whether the gate should have fired. It reasons in
    /// ``WearerTaskMode/followup``, whose seven tools leave out the two that would be wrong
    /// on an unattended path. It gets four turns and a minute. The model composes nothing to
    /// say unless the wearer needs it, sends at most one instruction, and says so out loud
    /// when it does — and a review that got all the way to `finish` having told the wearer
    /// nothing is closed with one short line, because the firing was announced before this
    /// ran (see ``followupNothingToReportNotice``).
    ///
    /// ## What it does not do
    ///
    /// It does not speak ``busyNotice`` when the slot is taken, and it does not break the
    /// voice when a cloud call fails. Both come back as dispositions instead, because both
    /// are decisions about a wearer who is not in a conversation and the object that decided
    /// to wake this review is the one holding the context to make them. See
    /// ``WearerFollowupDisposition``.
    ///
    /// It also does not touch the durable record. ``WearerFollowupBook`` is the single writer
    /// of `followup` entries; the composition passes this method's return value to
    /// ``WearerFollowupBook/recordFiring(_:disposition:)``.
    ///
    /// - Parameters:
    ///   - followup: the consumed follow-up. Consumed, past tense: by the time this runs it
    ///     is already out of the book, which is what makes a second boundary arriving during
    ///     the review harmless and what makes a re-fire off this review's *own* queued
    ///     instruction structurally impossible.
    ///   - boundary: what woke it. Its ``WearerFollowupBoundary/summary`` is untrusted agent
    ///     output and is rendered to the model under its own label; see
    ///     ``WearerTaskContract/input(for:)``.
    ///   - surfaces: a set to run against instead of the loop's own, or `nil`. It exists for
    ///     one thing the plan requires: review speech must reach the wearer through
    ///     `NotificationPolicy` as a deferrable producer, so an open command window defers it
    ///     exactly as it defers an agent notification — which the task lane's direct
    ///     scripted-speech path does not do. A composition hands this lane a set whose
    ///     `speak` is routed there and leaves the rest alone.
    @discardableResult
    public func runFollowup(
        _ followup: WearerFollowup,
        boundary: WearerFollowupBoundary,
        surfaces overriding: WearerTaskSurfaces? = nil
    ) async -> WearerFollowupDisposition {
        guard !isBusy else {
            // A gate refusal, and silent-and-logged like every other one: the wearer never
            // asked for this boundary to be reviewed *now*, and a sentence explaining TapQ's
            // scheduling to them would be the interruption the whole lane exists to ration.
            diagnostics.record("followup.busy", fields: [
                "agent": followup.agentDisplayName,
            ])
            return .busy
        }
        // Assigned before the first suspension point, so the slot is visibly taken the
        // instant this is entered and a `start_task` in the same turn is refused rather than
        // raced — the mirror of `begin(goal:)`.
        let run = Task { @MainActor [weak self] in
            guard let self else { return WearerFollowupDisposition.ran(.canceled) }
            return await self.performFollowup(
                followup, boundary: boundary, surfaces: overriding ?? self.surfaces
            )
        }
        runningFollowup = run
        let disposition = await run.value
        // Only if it is still ours. `cancel(reason:)` clears the slot from under a run it
        // cancelled, and a second review may legitimately have taken it by the time this
        // one's value arrives; nilling unconditionally would evict the live one.
        if runningFollowup == run { runningFollowup = nil }
        return disposition
    }

    private func performFollowup(
        _ followup: WearerFollowup,
        boundary: WearerFollowupBoundary,
        surfaces: WearerTaskSurfaces
    ) async -> WearerFollowupDisposition {
        let started = ContinuousClock.now
        var steps: [WearerTaskStep] = []
        /// The plan's "at most one autonomous instruction per boundary", held here rather
        /// than in the prompt. A bound a model can talk itself past is not a bound.
        var instructionSent = false
        /// Whether anything from this review has reached the wearer's ear: a `speak`, or a
        /// tool whose own announcement went out — `queue_instruction` says what it sent.
        /// Read at `finish`, where a review that has said nothing owes the closing line; see
        /// ``followupNothingToReportNotice``. Not the same question as "did it call speak":
        /// a review that queued an instruction has reported, through a different door.
        var spokeToWearer = false

        diagnostics.record("followup.started", fields: [
            "agent": followup.agentDisplayName,
            "origin": followup.origin.rawValue,
            "length": "\(followup.instruction.count)",
            "steps": "\(followupCap)",
        ])

        for step in 1...followupCap {
            guard !Task.isCancelled else {
                return endFollowup(followup, outcome: .canceled, steps: steps.count,
                                   started: started)
            }
            if step > 1, started.seconds(elapsedTo: .now) >= followupClock {
                diagnostics.record("followup.deadline", level: .warning, fields: [
                    "agent": followup.agentDisplayName,
                    "n": "\(step - 1)",
                    "budget_s": "\(Int(followupClock))",
                ])
                break
            }

            let decision: WearerTaskDecision
            do {
                decision = try await model.decide(WearerTaskTurnRequest(
                    goal: followup.instruction,
                    mode: .followup,
                    agentDisplayName: boundary.agentDisplayName,
                    boundary: boundary,
                    steps: steps,
                    stepsRemaining: followupCap - step + 1
                ))
            } catch {
                let reason = (error as? NarrationFailure)?.reason ?? "unknown"
                diagnostics.record("followup.model_failed", level: .error, fields: [
                    "agent": followup.agentDisplayName,
                    "n": "\(step)",
                    "reason": reason,
                ])
                // Nothing spoken and no latch touched. The gate owns the latch — see
                // `WearerFollowupDisposition.broke`.
                return .broke(reason: reason)
            }
            guard !Task.isCancelled else {
                return endFollowup(followup, outcome: .canceled, steps: step, started: started)
            }
            diagnostics.record("followup.step", fields: [
                "n": "\(step)",
                "tool": decision.toolName,
            ])

            switch decision {
            case .finish(let summary):
                // Recorded, not spoken. The lane's one inversion, and it is what keeps the
                // *model* from having to invent an interruption to end a turn: anything the
                // wearer needed to hear went out through `speak` earlier.
                //
                // But the firing was announced before this lane ran, so a review that
                // reaches here having said nothing leaves an opened sentence unfinished —
                // and a wearer who hears "on your follow-up: rerun the tests" and then
                // nothing cannot tell that from a review that broke. Closed out loud, once,
                // and only when nothing else got through. See
                // `followupNothingToReportNotice`.
                diagnostics.record("followup.finished", fields: [
                    "agent": followup.agentDisplayName,
                    "n": "\(step)",
                    "length": "\(summary.count)",
                    "spoke": "\(spokeToWearer)",
                    "queued": "\(instructionSent)",
                ])
                if !spokeToWearer { surfaces.speak(Self.followupNothingToReportNotice) }
                return endFollowup(followup, outcome: .finished, steps: step, started: started)

            case .cannotDo(let spoken):
                // Audible, like the task lane's, and for the same reason: the wearer asked
                // for a thing and is not getting it, which they cannot find out any other
                // way. The alternative the prompt forbids — forwarding it to the agent whose
                // boundary this is — is exactly the 2026-08-30 failure, and an unattended
                // path is where it would do the most damage.
                diagnostics.record("followup.refused", fields: [
                    "agent": followup.agentDisplayName,
                    "n": "\(step)",
                    "length": "\(spoken.count)",
                ])
                surfaces.speak(spoken)
                return endFollowup(followup, outcome: .refused, steps: step, started: started)

            case .speak(let text):
                surfaces.speak(text)
                spokeToWearer = true
                steps.append(WearerTaskStep(
                    tool: decision.toolName,
                    arguments: text,
                    result: "Spoken to the wearer."
                ))

            case .queueInstruction:
                guard !instructionSent else {
                    // The cap, and it is silent: refusing a second instruction is TapQ
                    // declining to do more than the wearer authorized, not news. The model
                    // is told so it stops trying, and the log carries the reason so "why
                    // did only one go out" is answerable without a transcript dig.
                    diagnostics.record("followup.instruction_capped", level: .warning, fields: [
                        "agent": followup.agentDisplayName,
                        "n": "\(step)",
                    ])
                    steps.append(WearerTaskStep(
                        tool: decision.toolName,
                        arguments: "",
                        result: "Nothing was sent. A follow-up may send at most one "
                            + "instruction, and it has already sent one. Say what you found "
                            + "with speak, or finish."
                    ))
                    continue
                }
                instructionSent = true
                let queued = perform(decision, speaking: true, using: surfaces)
                if queued.output.announce != nil { spokeToWearer = true }
                steps.append(queued.step)

            case .setFollowup, .askWearer:
                // Undeclared in this lane, so unreachable through `WearerTaskContract.decode`
                // — and refused here as well rather than falling through to `perform`, so
                // that "a review cannot re-arm itself and cannot open a question window" is
                // a property of the engine and not only of the tool list it happened to send.
                diagnostics.record("followup.tool_unavailable", level: .warning, fields: [
                    "agent": followup.agentDisplayName,
                    "tool": decision.toolName,
                ])
                steps.append(WearerTaskStep(
                    tool: decision.toolName,
                    arguments: "",
                    result: "That tool is not available in a follow-up. Say what you found "
                        + "with speak, or finish."
                ))

            default:
                // The read-only three. None of them announces today; the check is here so
                // that a tool which starts to would count as having reported, rather than
                // silently earning the review a closing line on top of its own sentence.
                let performed = perform(decision, speaking: true, using: surfaces)
                if performed.output.announce != nil { spokeToWearer = true }
                steps.append(performed.step)
            }
        }

        // Out of turns or out of clock. Spoken, against the lane's own silence rule, because
        // this is TapQ failing a promise rather than choosing not to interrupt.
        surfaces.speak(Self.followupCouldNotFinishNotice(
            agent: followup.agentDisplayName,
            instruction: followup.instruction
        ))
        return endFollowup(followup, outcome: .couldNotFinish, steps: steps.count,
                           started: started)
    }

    private func endFollowup(
        _ followup: WearerFollowup,
        outcome: WearerTaskOutcome,
        steps: Int,
        started: ContinuousClock.Instant
    ) -> WearerFollowupDisposition {
        // Diagnostics only. The book writes the record; see `runFollowup`.
        diagnostics.record("followup.ended", fields: [
            "agent": followup.agentDisplayName,
            "steps": "\(steps)",
            "outcome": outcome.rawValue,
            "duration_ms": Self.milliseconds(from: started),
        ])
        return .ran(outcome)
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
    /// - Parameter surfaces: the set to run against, or `nil` for the loop's own. The
    ///   follow-up lane may be handed its own, so a composition can route review speech
    ///   somewhere the task lane's speech does not go — see
    ///   ``runFollowup(_:boundary:surfaces:)``.
    private func perform(
        _ decision: WearerTaskDecision,
        speaking: Bool,
        using overriding: WearerTaskSurfaces? = nil
    ) -> (step: WearerTaskStep, output: WearerTaskToolOutput) {
        let surfaces = overriding ?? self.surfaces
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
        case .setFollowup(let agent, let instruction):
            arguments = agent.map { "\($0), \(instruction)" } ?? instruction
            output = surfaces.setFollowup(agent, instruction)
        case .speak, .askWearer, .finish, .cannotDo:
            // Unreachable: the four are handled by the task lane's own switch and are
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
