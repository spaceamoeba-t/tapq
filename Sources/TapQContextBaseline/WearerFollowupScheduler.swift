import Foundation
import TapQContracts

/// The book, as the voice surface and the deliberation loop both reach it: one place that
/// resolves the agent's name, writes to the book, and produces the sentence TapQ says.
///
/// It exists so that the wording is in one file rather than three. A follow-up can be set
/// three ways — the wearer says so and the realtime model calls `set_followup`, a running
/// task calls the loop's own `set_followup` tool, or a composition sets one directly — and
/// all three make the same promise, so all three have to say the same thing. Announcing on
/// creation is not optional: what TapQ has agreed to do later, on its own, in the wearer's
/// name, has to be audible at the moment it is agreed to. That is the same rule
/// `queue_instruction` follows for a sentence sent now.
///
/// **Name resolution is not here.** Which names are addressable is the roster's question and
/// rung E's resolver is the authority; this type takes a closure that answers it and refuses
/// out loud, fail-closed, when it comes back empty. A book that matched names itself would be
/// a second grammar for agent names, which is the thing the 2026-08-28 no-heuristics ruling
/// removed from this path.
@MainActor public final class WearerFollowupScheduler {
    private let book: WearerFollowupBook
    private let resolve: @MainActor (String) -> String?
    private let diagnostics: TapQDiagnosticEmitter

    /// - Parameters:
    ///   - book: the one-shot book. Shared with the gate that fires follow-ups.
    ///   - resolveAgent: turns a spoken name into the roster's display name, or `nil` when
    ///     nothing answers to it. Defaults to identity, which is what a composition with no
    ///     roster to check against has — and which is honest, because it promises to watch
    ///     the name it was given rather than pretending to have verified it.
    public init(
        book: WearerFollowupBook,
        resolveAgent: @escaping @MainActor (String) -> String? = { $0 },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.book = book
        self.resolve = resolveAgent
        self.diagnostics = TapQDiagnosticEmitter(
            category: "WearerFollowup", sink: diagnosticSink
        )
    }

    // MARK: - What the wearer hears

    /// "After Claude Code finishes: rerun the tests — noted."
    ///
    /// The read-back is the point, and it is the same read-back a dictated instruction and an
    /// accepted goal both get: a wearer who cannot see a screen has no other way to find out
    /// that TapQ heard something different from what they said. The agent is first because it
    /// is the half a mis-hearing does the most damage to — a follow-up armed on the wrong
    /// agent waits forever and fires never — and "noted" closes it because the wearer needs
    /// to know it is *held*, not being done now.
    public nonisolated static func notedNotice(agent: String, instruction: String) -> String {
        "After \(agent) finishes: " + WearerTaskLoop.spokenGoal(instruction) + " — noted."
    }

    /// The replacement's sentence: the ordinary one, prefixed with what it displaced.
    ///
    /// It leads with the replacement rather than appending it, because a wearer who hears the
    /// familiar acknowledgment first has already stopped listening by the time the
    /// qualification arrives — and believing you have two follow-ups when you have one is
    /// exactly the mis-modelling the plan's read-back rule exists to prevent.
    public nonisolated static func replacedNotice(agent: String, instruction: String) -> String {
        "Instead of the last one — after \(agent) finishes: "
            + WearerTaskLoop.spokenGoal(instruction) + " — noted."
    }

    /// "Dropped the follow-up on Claude Code."
    public nonisolated static func droppedNotice(agent: String) -> String {
        "Dropped the follow-up on \(agent)."
    }

    /// Said when there was nothing to drop. It names the agent, because the likeliest reason
    /// is that the follow-up is on a different one.
    public nonisolated static func nothingPendingNotice(agent: String) -> String {
        "There's no follow-up on \(agent)."
    }

    /// Fail-closed, out loud, for a name nothing answers to. The wearer's own word is read
    /// back so they can hear which name TapQ heard.
    public nonisolated static func unknownAgentNotice(agent: String) -> String {
        "I don't know an agent called \(agent) — nothing is set."
    }

    /// The sentence a dictation that captured silence has always got.
    public nonisolated static let emptyInstructionNotice =
        "I didn't catch that — say it again."

    // MARK: - Reporting back

    /// The follow-up TapQ arms on its own when an instruction reaches an agent and nothing
    /// is waiting on that agent yet.
    ///
    /// Second and third hardware runs (2026-09-01): "find market landscape for CRM
    /// softwares" was handed to Claude Code correctly, Claude finished, TapQ said "Claude
    /// Code finished." and nothing else, and the wearer had to ask what the answer was. A
    /// finished boundary announces itself and narrates only a question; the *result* of work
    /// the wearer sent reaches them only through a follow-up, and the model was told to set
    /// one but did not. So the composition sets it, at the moment the instruction is
    /// delivered — the one moment TapQ knows for certain that the next finished boundary is
    /// the answer to something the wearer asked for. The wearer hears that it was set, can
    /// call it off, and can replace it with one of their own; both go through the book as
    /// any follow-up does.
    public nonisolated static func reportBackInstruction(agent: String, about text: String) -> String {
        "Tell me what \(agent) did about: " + WearerTaskLoop.spokenGoal(text)
    }

    /// "I'll report back when Claude Code finishes." — shorter than the ordinary noted
    /// read-back, because the sentence it would read back is the one the wearer just heard
    /// queued.
    public nonisolated static func reportBackNotice(agent: String) -> String {
        "I'll report back when \(agent) finishes."
    }

    /// Arms the report-back follow-up for an agent that has just received an instruction,
    /// unless something is already waiting on it — a follow-up the wearer set is theirs,
    /// and a replacement here would silently swap their sentence for TapQ's.
    ///
    /// - Returns: the sentence to say, or `nil` when nothing was set.
    @discardableResult
    public func armReportBack(agent: String, about text: String) -> String? {
        let name = SpokenSummaryText.normalized(agent)
        guard !name.isEmpty, book.pending(for: name) == nil else {
            diagnostics.record("report_back.skipped", fields: [
                "agent": name, "reason": name.isEmpty ? "no_agent" : "pending",
            ])
            return nil
        }
        guard case .created = book.set(
            agent: name, instruction: Self.reportBackInstruction(agent: name, about: text),
            origin: .loop, purpose: .reportBack
        ) else { return nil }
        diagnostics.record("report_back.armed", fields: ["agent": name])
        return Self.reportBackNotice(agent: name)
    }

    /// What a report-back says as it fires, in place of the ordinary "on your follow-up:"
    /// read-back of the instruction.
    ///
    /// The ordinary announcement reads the follow-up's sentence back because the wearer
    /// wrote it and may want to stop it. A report-back's sentence is TapQ's own ("Tell me
    /// what Claude Code did about: …"), and reading it out — right after "Claude Code
    /// finished." — was one of the four repetitions the fifth hardware run (2026-09-02)
    /// counted. The grace after it is unchanged: "cancel the follow-up" still stops it.
    public nonisolated static func reportingBackNotice(agent: String) -> String {
        "Reporting back on what \(agent) did."
    }

    /// Said right after "\(agent) finished." when that turn left background work running
    /// and a follow-up is waiting on the agent.
    ///
    /// The wearer has just heard "finished" and is expecting their follow-up next. Silence
    /// here would read as the follow-up being lost, and firing would report on work that is
    /// not done — the 2026-09-01 hardware run, where "tell me the test result" fired against
    /// a suite that was still running. So the hold is audible, names the reason, and says
    /// the promise is intact.
    public nonisolated static func heldNotice(agent: String) -> String {
        "\(agent) left work running in the background — your follow-up is still waiting."
    }

    // MARK: - Setting

    /// Sets a follow-up and returns the sentence to say about it.
    ///
    /// - Parameter origin: who asked. The wearer by voice, or TapQ's own loop registering a
    ///   continuation for work it just started.
    @discardableResult
    public func set(
        agent: String,
        instruction: String,
        origin: InstructionOrigin
    ) -> WearerFollowupAcknowledgment {
        let spokenName = SpokenSummaryText.normalized(agent)
        let instruction = SpokenSummaryText.normalized(instruction)
        guard !instruction.isEmpty else {
            diagnostics.record("schedule.refused", fields: ["reason": "no_instruction"])
            return .refused(spoken: Self.emptyInstructionNotice)
        }
        guard !spokenName.isEmpty, let resolved = resolve(spokenName), !resolved.isEmpty else {
            diagnostics.record("schedule.refused", level: .warning, fields: [
                "reason": "unknown_agent",
                "agent": spokenName,
            ])
            return .refused(spoken: Self.unknownAgentNotice(agent: spokenName))
        }

        switch book.set(agent: resolved, instruction: instruction, origin: origin) {
        case .created:
            return .noted(spoken: Self.notedNotice(agent: resolved, instruction: instruction))
        case .replaced:
            return .replaced(
                spoken: Self.replacedNotice(agent: resolved, instruction: instruction)
            )
        case .notSet:
            // Unreachable: both of the book's rejections are already refused above, with a
            // sentence that says which. Answered rather than trapped, because a trap on the
            // voice path is the one failure with no diagnostic at all.
            diagnostics.record("schedule.refused", level: .error, fields: ["reason": "not_set"])
            return .refused(spoken: Self.emptyInstructionNotice)
        }
    }

    /// Drops the follow-up on one agent.
    ///
    /// The unknown-name case is *not* fail-closed here, and the asymmetry is deliberate:
    /// refusing to set a follow-up on a name nothing answers to prevents a promise TapQ
    /// cannot keep, while refusing to cancel one would leave a follow-up armed because the
    /// agent it watches has since gone away. So a cancel goes through on the spoken name when
    /// the roster does not know it, and finds nothing if nothing is there.
    @discardableResult
    public func cancel(agent: String) -> WearerFollowupAcknowledgment {
        let spokenName = SpokenSummaryText.normalized(agent)
        guard !spokenName.isEmpty else {
            diagnostics.record("cancel.refused", fields: ["reason": "no_agent"])
            return .refused(spoken: Self.emptyInstructionNotice)
        }
        let name = resolve(spokenName) ?? spokenName
        switch book.cancel(agent: name) {
        case .cancelled(let followup), .aborted(let followup):
            return .dropped(spoken: Self.droppedNotice(agent: followup.agentDisplayName))
        case .nothingPending:
            return .nothingPending(spoken: Self.nothingPendingNotice(agent: name))
        }
    }

    // MARK: - The loop's own tool

    /// ``WearerTaskSurfaces/setFollowup``, wired to this scheduler.
    ///
    /// The announcement rides the tool's own output rather than a separate `speak` call, for
    /// the reason `queue_instruction`'s does: the loop speaks a tool's announcement before
    /// the next turn, so what TapQ agreed to is heard in the order it happened rather than
    /// whenever the model next decides to mention it. And the model reads a different
    /// sentence from the wearer's — it needs to know the follow-up is *held* and that setting
    /// a second would replace it, which is not what the wearer needs to hear.
    public func taskSurface() -> @MainActor (String?, String) -> WearerTaskToolOutput {
        { [weak self] agent, instruction in
            guard let self else {
                return .ok(WearerTaskSurfaces.noFollowupBookText)
            }
            let acknowledgment = self.set(
                agent: agent ?? "", instruction: instruction, origin: .loop
            )
            switch acknowledgment {
            case .noted(let spoken):
                return .announcing(
                    "Noted. TapQ will act on this once, at that agent's next finished run, "
                        + "and the wearer has been told out loud.",
                    say: spoken
                )
            case .replaced(let spoken):
                return .announcing(
                    "Noted, replacing the follow-up that was already waiting on that agent. "
                        + "The wearer has been told out loud.",
                    say: spoken
                )
            case .refused(let spoken):
                // A refusal the wearer hears, exactly as an unknown-agent dictation is. The
                // model is told plainly so it stops rather than trying the name again.
                return .announcing(
                    "Nothing was scheduled: that agent name is not one TapQ can address. "
                        + "Call get_status for the names that are, or say so with cannot_do.",
                    say: spoken
                )
            case .dropped, .nothingPending:
                // Unreachable: `set` never returns either. Rendered rather than trapped.
                return .ok(WearerTaskSurfaces.noFollowupBookText)
            }
        }
    }
}

/// The voice seam. `nonisolated` and `async` for the reason
/// ``WearerTaskLoop/startTask(goal:)`` is: a caller on any actor can reach it, and the body
/// does nothing but hop to the main actor, where the book already lives.
extension WearerFollowupScheduler: WearerFollowupScheduling {
    public nonisolated func setFollowup(
        agent: String,
        instruction: String
    ) async -> WearerFollowupAcknowledgment {
        await MainActor.run {
            // `.dictated`: this arm is reached only from the realtime tool, which is the
            // wearer speaking. The loop's own path goes through `taskSurface()` above and
            // tags itself `.loop`.
            self.set(agent: agent, instruction: instruction, origin: .dictated)
        }
    }

    public nonisolated func cancelFollowup(
        agent: String
    ) async -> WearerFollowupAcknowledgment {
        await MainActor.run { self.cancel(agent: agent) }
    }
}
