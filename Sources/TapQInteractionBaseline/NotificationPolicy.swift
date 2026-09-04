import Foundation
import TapQContracts

/// Everything TapQ might make a sound about, in the categories that decide whether it
/// *should*.
///
/// Not the utterances themselves and not their `SpeechPriority`: priority orders speech
/// against other speech, and this orders speech against the wearer's attention. The two
/// disagree — a recall answer and an agent notification are both `.notification` priority,
/// and quiet mode silences exactly one of them.
public enum Announcement: Sendable, Equatable {
    /// An agent state change arriving at the runtime's notification chokepoint.
    case agentNotification(kind: AgentNotification.Kind, sessionID: String)
    /// A request the wearer is about to be asked to answer.
    case requestPrompt(sessionID: String)
    /// "Deferring to the screen." — TapQ saying where the question went.
    case deferToScreen
    /// A hardware state change mid-interaction ("AirPods motion disconnected.").
    case motionLost
    /// Anything the wearer asked for: recall answers, repeats, read-backs, window cues.
    ///
    /// Always spoken, in every mode. A wearer who asks a question out loud and hears a
    /// chime back has been given a worse answer than silence, because they cannot tell it
    /// from a misheard question.
    case wearerInitiated

    /// The session this announcement is about, when it is about one. Read by the deferral
    /// queue, which has to know when a held notice has been overtaken by fresher news about
    /// the same agent.
    public var sessionID: String? {
        switch self {
        case .agentNotification(_, let sessionID), .requestPrompt(let sessionID):
            return sessionID
        case .deferToScreen, .motionLost, .wearerInitiated:
            return nil
        }
    }
}

/// A short non-speech sound. Two of them, because the wearer has to be able to tell
/// "something needs you" from "something happened" without looking.
///
/// The enum is portable and carries no audio: which waveform a cue is, and which engine
/// plays it, belongs to the Apple side. This is the vocabulary they agree on.
public enum NotificationCue: String, Sendable, Equatable {
    /// Something is waiting for the wearer to answer it.
    case prompt
    /// Something happened that the wearer did not have to answer.
    case notification
}

/// Decides how an announcement reaches the wearer: spoken, chimed, or not at all.
///
/// Three jobs, and the first two used to be nowhere:
///
/// * **Quiet routing.** Under `--quiet` the utterances that exist to get the wearer's
///   attention become a cue, and the ones that answer the wearer stay speech.
/// * **Per-session dedupe.** A session already known to be waiting is not announced
///   again. The registry answers for the sessions queued at the gate right now; the
///   policy's own marks answer for the ones announced earlier and not yet finished.
/// * **One door for unprompted speech.** Everything TapQ says without being asked in the
///   moment — agent notifications, and the deliberation loop's own review speech through
///   `routeLoopSpeech` — arrives here, so the deferral around a command window is one lock
///   with one key rather than a rule each producer is trusted to remember. A second,
///   unguarded path into the speech channel is precisely how "spoken into an open window
///   while that window's timer keeps counting" gets back in, from a new door.
///
/// **The verdict is about audio and nothing else.** There is no case here that means "do
/// not record": suppressing a sound and forgetting an event are different acts, and
/// conflating them is the bug this type was written next to — a wearer who hears nothing
/// can still ask what happened, and must get an answer. Callers record unconditionally
/// and consult this only for what to play.
@MainActor public final class NotificationPolicy {
    /// How the announcement reaches the wearer.
    public enum Verdict: Sendable, Equatable {
        case speak
        case chime(NotificationCue)
        /// Nothing is played. The event is still recorded by the caller — see the note on
        /// the type.
        case suppress
        /// Nothing is played *now*. The policy is holding this one and will play it —
        /// through the caller's own `whenDeferred` closure — at the next moment it is legal
        /// to make a sound. The caller does nothing; in particular it must not fall back to
        /// speaking, which is the race this case exists to end.
        case deferred
    }

    /// Whether a command window is open right now.
    ///
    /// A question rather than a notification, and that is load-bearing: a voice session
    /// re-opens its windows back to back for as long as a turn boundary is held, so
    /// a "window closed" callback would fire in the gap between two windows of the same
    /// session and the notice would land in the next one. Asking gets the true answer —
    /// "is the wearer inside a listening window" — instead of an edge that means something
    /// narrower than it looks.
    public typealias CommandWindowPresence = @MainActor () -> Bool

    /// The two flags that shape routing, as they were parsed.
    public struct Settings: Sendable, Equatable {
        /// `--quiet`: attention-seeking utterances become cues.
        public let quiet: Bool
        /// `--no-announcements`, inverted. Covers agent state changes only — exactly what
        /// it covered before this type existed. Widening it to prompts, deferrals, or
        /// motion loss would make requests unanswerable, which is quiet mode's problem to
        /// solve with a cue rather than this flag's to solve with silence.
        public let announcementsEnabled: Bool

        public init(quiet: Bool = false, announcementsEnabled: Bool = true) {
            self.quiet = quiet
            self.announcementsEnabled = announcementsEnabled
        }
    }

    /// How often the pending queue asks whether the window has closed yet. A quarter of a
    /// second against an eight-second window: fine enough that the notice lands in the pause
    /// after the window rather than a beat later, cheap enough to be uninteresting.
    static let deferralPollSeconds: TimeInterval = 0.25

    /// How long a notice may wait for a window to close before it is dropped.
    ///
    /// There has to be a bound, because a voice session holds windows open for as long as
    /// the wearer keeps talking to it and that is deliberately indefinite. At the bound the
    /// notice is dropped rather than finally spoken: speaking it would be the exact race
    /// this deferral exists to end, only later and with worse timing. Dropping is safe here
    /// in a way it is nowhere else, because the caller recorded the event unconditionally
    /// before asking for a verdict — the wearer can still ask what changed and be told. A
    /// minute is about as long as "the agent finished" is news.
    ///
    /// One bound covers loop speech too, dropped for the same reason and safe under the same
    /// condition — which `routeLoopSpeech` states as a requirement on its callers rather
    /// than an observation about them. What is *not* shared is the diagnostic: a review TapQ
    /// decided to say and never said is a different thing to find in a log than a stale
    /// notice about an agent, and only one of the two has an escalation to offer
    /// composition (`onExpiredLoopSpeech`).
    ///
    /// What the bound is no longer reachable *from* is an idle wait. Since 2026-09-01 an
    /// idle wait is a legal moment to make a sound in — for both kinds — so a queue behind
    /// one drains instead of running out the clock. Reaching this bound therefore means a
    /// window with a wearer inside it: an attention window, or a request they have not
    /// answered, held open for a minute. That is the case it was written for.
    static let maximumDeferralSeconds: TimeInterval = 60

    /// What to do about a loop sentence that waited out the bound and was dropped.
    ///
    /// Composition's hook, not the policy's business: this type knows that a sentence was
    /// never said and nothing more. Whether that is a line in a run log, a mark against the
    /// directive that produced it, or something the wearer is told later is a question about
    /// the wearer's work, and it is answered above here. Handed the text so the answer can
    /// be about the sentence and not just its absence.
    public typealias ExpiredLoopSpeechHandler = @MainActor (String) -> Void

    private let settings: Settings
    private let waits: SessionWaitRegistry
    private let commandWindowOpen: CommandWindowPresence?
    private let idleListening: CommandWindowPresence?
    private let onExpiredLoopSpeech: ExpiredLoopSpeechHandler?
    /// Sessions announced as waiting and not yet finished or forgotten.
    private var announced: Set<String> = []
    /// Notices held back while a command window is open, oldest first.
    private var pending: [Pending] = []
    /// The task watching for the window to close. One at a time; `nil` when nothing is held.
    private var drainTask: Task<Void, Never>?
    /// Clock and sleep seams, so the deferral's timing can be driven by a test instead of
    /// waited out. The same shape the controllers use for `now`.
    var now: () -> ContinuousClock.Instant = { .now }
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }

    /// What a held entry is.
    ///
    /// The two kinds share one queue, because the wearer hears one sequence. Replay is
    /// arrival order across both, and a second queue drained by kind would have TapQ
    /// re-ordering its own half of a conversation around news about somebody else's — the
    /// wearer would hear a reply before the thing it replies to.
    private enum PendingKind {
        /// News about an agent session, and so overtakable by fresher news about that same
        /// session.
        case announcement(Announcement)
        /// A sentence the deliberation loop composed, carried along so an expiry can hand it
        /// back. Nothing supersedes it: it is not a state that can go stale behind a newer
        /// reading, it is a thing TapQ decided to say.
        case loopSpeech(String)

        /// The session this entry is about, when it is about one. Read by supersession,
        /// which is therefore about announcements and only announcements.
        var sessionID: String? {
            switch self {
            case .announcement(let announcement): return announcement.sessionID
            case .loopSpeech: return nil
            }
        }

        /// How a diagnostic line names this kind, so one queue reads as two producers.
        var diagnosticLabel: String {
            switch self {
            case .announcement: return "announcement"
            case .loopSpeech: return "loop_speech"
            }
        }
    }

    /// One held notice: what it would have played, who plays it, and when it started waiting.
    private struct Pending {
        let kind: PendingKind
        let verdict: Verdict
        let deferredAt: ContinuousClock.Instant
        /// The caller's own replay. The policy composes no utterances and holds no
        /// `AgentNotification`, so the only honest way to say a held sentence later is to
        /// hand the verdict back to whoever knew how to say it in the first place.
        let play: @MainActor (Verdict) -> Void
        /// What two entries have to share to be the same thing said twice.
        let key: String
    }

    /// - Parameter commandWindowOpen: absent means this policy never defers, which is what
    ///   every composition without command windows wants and what the tests that predate
    ///   them assert.
    /// - Parameter idleListening: whether the open window is a voice session's idle wait —
    ///   TapQ listening at a held turn boundary with nothing in hand. Absent means no window
    ///   is ever idle, which is the pre-M3 behavior. Asked about *everything* held: see
    ///   below.
    ///
    ///   Second hardware run of M3 (2026-09-01): the follow-up's review composed the test
    ///   result and the sentence sat deferred until it expired, because a voice session
    ///   re-opens its windows with no gap and `commandWindowOpen` never
    ///   answered no. But that window is exactly where the wearer is waiting to hear the
    ///   result — nobody is mid-answer in an idle wait, so the race the deferral exists to
    ///   end is not running. A request in hand (an approval, a selection) ends the listening
    ///   loop before its window opens, so "idle" is not ambiguous at the composition.
    ///
    ///   That first fix exempted loop speech alone, and the exemption was drawn too narrow
    ///   (2026-09-01, reviewing the same run): an agent notification held behind the same
    ///   never-closing windows expires at the same bound, so every `finished`,
    ///   `waitingForInput`, and `permissionWaiting` about a *second* agent was dropped for
    ///   as long as the wearer stayed in a voice session — `notification.dropped_expired`,
    ///   nothing said. The reason the deferral does not apply in an idle wait is a fact
    ///   about the window, not about who is speaking into it, so it applies to both kinds.
    ///   The bound and the deferral are untouched everywhere else, which is where a wearer
    ///   is actually mid-answer.
    /// - Parameter onExpiredLoopSpeech: absent means an expired loop sentence is a
    ///   diagnostic and nothing else, which is right for every composition with no loop.
    public init(settings: Settings = Settings(),
                waits: SessionWaitRegistry,
                commandWindowOpen: CommandWindowPresence? = nil,
                idleListening: CommandWindowPresence? = nil,
                onExpiredLoopSpeech: ExpiredLoopSpeechHandler? = nil,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.settings = settings
        self.waits = waits
        self.commandWindowOpen = commandWindowOpen
        self.idleListening = idleListening
        self.onExpiredLoopSpeech = onExpiredLoopSpeech
        self.diagnostics = TapQDiagnosticEmitter(category: "Notification", sink: diagnosticSink)
    }

    private let diagnostics: TapQDiagnosticEmitter

    /// Routes one announcement, spending its dedupe slot.
    ///
    /// Named for the side effect as much as the answer: calling it twice for the same
    /// waiting session is how the second call gets `.suppress`, so a caller that wants to
    /// know the verdict without consuming the slot wants `Verdict` arithmetic it does not
    /// have — deliberately, because a "peek" that drifted out of sync with the route would
    /// announce the same wait twice.
    /// - Parameter whenDeferred: how to play this announcement later, if the policy holds it
    ///   back. Only `.agentNotification` is ever held, and only while a command window is
    ///   open and is not the session's idle wait — see `idleListening`, where a notice about
    ///   another agent is said rather than queued behind windows that never close. A caller
    ///   that supplies nothing cannot be handed `.deferred` — it would have no
    ///   way to honour it, and "later" with no later is the silent drop this whole mechanism
    ///   is against — so such a call routes exactly as it always did.
    public func route(_ announcement: Announcement,
                      whenDeferred: (@MainActor (Verdict) -> Void)? = nil) -> Verdict {
        switch announcement {
        case .agentNotification(let kind, let sessionID):
            let verdict = routeAgentNotification(kind: kind, sessionID: sessionID)
            return hold(.announcement(announcement), key: Self.key(announcement),
                        verdict: verdict, play: whenDeferred) ?? verdict
        case .requestPrompt(let sessionID):
            // The wearer is being asked about this session right now, which is the
            // strongest possible form of "already announced": a `waitingForInput` arriving
            // behind the prompt says nothing the prompt did not.
            //
            // Which is also true of anything about that session still waiting in the
            // deferral queue — see `markSuperseded`. A prompt is never itself deferred: it
            // is the one announcement the wearer has to hear to be able to answer at all.
            announced.insert(sessionID)
            markSuperseded(sessionID: sessionID)
            return settings.quiet ? .chime(.prompt) : .speak
        case .deferToScreen, .motionLost:
            // Never suppressed outright. Both are TapQ telling the wearer that the thing
            // they were about to answer has moved or broken; a wearer who hears nothing
            // waits for a prompt that is not coming.
            return settings.quiet ? .chime(.notification) : .speak
        case .wearerInitiated:
            return .speak
        }
    }

    /// Routes one sentence the deliberation loop composed, through the same lock the agent
    /// notifications obey.
    ///
    /// The loop speaks at run-finished boundaries, with nobody having spoken to it — which
    /// is exactly where a command window is likely to be open, and exactly the shape of the
    /// defect the deferral above exists to end. Before this entry point the loop's speech
    /// went straight to the presenter at `.notification` priority: a producer of unprompted
    /// speech entering through a door the deferral does not guard. Now it waits where the
    /// notifications wait, and comes out in the order the two arrived.
    ///
    /// Deliberately unlike `route` in three ways, each a decision rather than an omission:
    ///
    /// * **`--no-announcements` does not reach it.** That flag covers agent state changes —
    ///   ambient news that something happened elsewhere — and a loop sentence is not one: it
    ///   is the output of work the wearer asked for, standing where `wearerInitiated`
    ///   stands. A wearer who set a directive and then hears nothing has been given a worse
    ///   answer than silence, because they cannot tell it from a directive that never fired.
    ///   The two suppress policies are kept in separate functions with separate reach so
    ///   they cannot be unified by an edit that thinks it is tidying — see
    ///   `loopSpeechVerdict()` and `routeAgentNotification(kind:sessionID:)`.
    /// * **No per-session dedupe.** Two loop sentences are two things TapQ decided to say,
    ///   not one state announced twice; there is no slot to spend and none is spent. The one
    ///   thing collapsed is an *identical* sentence already waiting out the same window,
    ///   which is not news said twice but a stutter.
    /// * **The replay is required, not optional.** `route`'s escape hatch exists for callers
    ///   written before deferral did. A loop with no way to say its own sentence is not a
    ///   thing, so there is no such caller here and no branch pretending there might be.
    ///
    /// **Requirement on the caller: record the outcome before routing it.** Held speech is
    /// dropped at `maximumDeferralSeconds` rather than finally spoken, and that is only
    /// honest when the record is already made — then an expiry costs the wearer a sentence
    /// and not the event, and the wearer who never heard it can still ask what happened and
    /// be told. A caller that speaks first and records afterwards turns an expiry into a
    /// lost event, which is the one thing this type may not do.
    ///
    /// - Parameter whenDeferred: how to say this sentence at the next legal moment. Called
    ///   with the verdict the sentence would have had, exactly as `route`'s is.
    /// - Returns: `.speak` when it may be said now, `.deferred` when the policy took it.
    ///   `.suppress` and `.chime` are unreachable here — they are what the announcement
    ///   flags produce, and neither flag is asked.
    public func routeLoopSpeech(_ text: String,
                                whenDeferred: @escaping @MainActor (Verdict) -> Void) -> Verdict {
        let verdict = Self.loopSpeechVerdict()
        return hold(.loopSpeech(text), key: Self.loopSpeechKey(text),
                    verdict: verdict, play: whenDeferred) ?? verdict
    }

    /// The verdict for a loop sentence: spoken, in every mode.
    ///
    /// `static` on purpose, and that is the whole of the structure guarding point 3 above: it
    /// cannot reach `settings`, so `announcementsEnabled` cannot be threaded through here by
    /// a later edit without changing this function's shape in the diff. The symmetry it would
    /// be reaching for is the bug.
    ///
    /// `--quiet` is not asked either, and is not this type's to apply to the loop: the run's
    /// loop speech deliberately bypasses the quiet decorator ("answers are still spoken"),
    /// and a routing hop is not the place to quietly reverse that. A composition that ever
    /// decides review speech should chime instead has to say so where the loop is built.
    private static func loopSpeechVerdict() -> Verdict { .speak }

    /// Drops a session's dedupe mark, so its next wait announces again.
    ///
    /// Called when a request for the session resolves. Nothing expires on its own here,
    /// for `SessionWaitRegistry`'s reason: a mark that timed itself out would re-announce
    /// a wait the wearer is still looking at.
    /// A finished boundary the wearer has already heard the outcome of — the stop
    /// question narrated it a moment ago — is not spoken again, but it still ends the
    /// session's wait: the next waiting notification from it is news again, exactly as if
    /// "finished" had been routed. Counted, never silent.
    public func noteFinishedAlreadyNarrated(sessionID: String) {
        announced.remove(sessionID)
        diagnostics.record("notification.dropped_stale",
                           fields: ["reason": "narrated", "kind": "finished"])
    }

    public func forget(sessionID: String) {
        announced.remove(sessionID)
    }

    /// Forgets every mark. For a runtime restarting its broker without restarting itself.
    public func reset() {
        announced.removeAll()
    }

    /// Whether `sessionID` would be deduped right now. Read-only; for diagnostics and
    /// tests, never a substitute for `route`.
    public func hasAnnounced(sessionID: String) -> Bool {
        announced.contains(sessionID)
    }

    /// How many notices are waiting for a window to close. Read-only; for diagnostics and
    /// tests.
    public var deferredCount: Int { pending.count }

    // MARK: - Deferral

    /// Holds an entry back if it would make a sound into an open command window.
    ///
    /// The shape is ratified and it is *defer, not race*: the alternative — speak now, at
    /// `.notification` priority, into a window whose recognizer the speech gate then tears
    /// down while the window's own timer keeps counting — spends most of an eight-second
    /// window on a sentence about a different session, and the wearer's answer to the
    /// question they were actually being asked lands in a microphone that was closed for it.
    /// `StopQuestionCoordinator.noteNarrationNotice` is the precedent: a notice that cannot
    /// be said now is queued for the next legal moment, not shouted over the moment in hand.
    ///
    /// Returns `.deferred` when it took the entry, `nil` when the caller should proceed with
    /// the verdict it already has. Shared by both producers on purpose: one queue, one drain,
    /// one bound, and one place where "is a window open" is asked.
    private func hold(_ kind: PendingKind,
                      key: String,
                      verdict: Verdict,
                      play: (@MainActor (Verdict) -> Void)?) -> Verdict? {
        // Nothing to hold back: a suppressed announcement makes no sound to begin with, and
        // there is no window to protect.
        guard verdict != .suppress, commandWindowOpen?() == true else { return nil }
        if idleListening?() == true {
            // The window is a voice session's idle wait: nobody is mid-answer, so the race
            // the deferral exists to end is not running, and the wearer is listening. Said
            // now — whichever kind it is — and the log says the window was open when it was
            // said.
            //
            // Anything already held goes out first. The queue is one sequence in arrival
            // order (see `PendingKind`), and an entry that jumped a queue drained a poll
            // later would be TapQ answering ahead of the news it answers.
            deliverPending(into: .idleWait)
            diagnostics.record("notification.spoken_into_idle_wait",
                               fields: ["kind": kind.diagnosticLabel])
            return nil
        }
        guard let play else {
            // A caller with no replay is told to go ahead. It is the lesser wrong: speaking
            // into a window is a bad turn, and holding a notice nobody can ever play is a
            // notice that vanishes — and the one thing this type may not do is lose an event
            // quietly. Recorded, so a log can tell the two apart.
            //
            // Reachable from `route` alone: `routeLoopSpeech` takes its replay as a plain
            // parameter, so a loop sentence has nowhere to lose one.
            diagnostics.record("notification.deferral_unavailable", level: .warning,
                               fields: ["announcement": key])
            return nil
        }
        if pending.contains(where: { $0.key == key }) {
            // The same sentence twice, both of them waiting out the *same* window. Two
            // finishes separated by real time are two pieces of news and both are still
            // announced — that rule is untouched. Two finishes separated by nothing are one
            // sentence said twice in a row, which is not news, it is a stutter. A loop that
            // composed the identical sentence twice into one window is the same stutter,
            // and the only place loop speech is deduped at all.
            diagnostics.record("notification.dropped_stale",
                               fields: ["reason": "duplicate",
                                        "kind": kind.diagnosticLabel,
                                        "held": "\(pending.count)"])
            return .deferred
        }
        pending.append(Pending(kind: kind, verdict: verdict,
                               deferredAt: now(), play: play, key: key))
        diagnostics.record("notification.deferred",
                           fields: ["kind": kind.diagnosticLabel, "held": "\(pending.count)"])
        startDraining()
        return .deferred
    }

    /// Marks everything held for `sessionID` stale, because the wearer has just been told
    /// something more current about it through a route that was not deferred.
    ///
    /// "Claude Code finished" is worth saying until the wearer is being asked a fresh
    /// question from that same session, at which point it is a sentence about the past
    /// arriving after the present. Dropped, and counted — never silently.
    ///
    /// Held loop speech is never touched here, and the shape says so: it has no session to
    /// match. A review sentence is not a reading of a session's state that a newer reading
    /// replaces — it is something TapQ decided to say, and a prompt about some session is no
    /// reason to have decided otherwise.
    private func markSuperseded(sessionID: String) {
        let before = pending.count
        pending.removeAll { $0.kind.sessionID == sessionID }
        let dropped = before - pending.count
        guard dropped > 0 else { return }
        diagnostics.record("notification.dropped_stale",
                           fields: ["reason": "superseded", "count": "\(dropped)"])
    }

    /// Watches for the window to close, then plays what is held.
    ///
    /// One task at a time, and it owns the whole queue rather than one entry: notices that
    /// arrive while it is already watching join the queue it will drain.
    private func startDraining() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            while true {
                guard let self, !self.pending.isEmpty else { break }
                guard self.commandWindowOpen?() == true else {
                    self.deliverPending(into: .closedWindow)
                    break
                }
                // Held behind a request, released the moment the session goes back to idle
                // listening — the same rule `hold` applies on arrival — without waiting for
                // a window edge the voice session never produces. The whole queue, in
                // arrival order: an idle wait is a legal moment for both kinds, so draining
                // half of it would be the split sequence `PendingKind` argues against.
                if self.idleListening?() == true { self.deliverPending(into: .idleWait) }
                self.expireOverdue()
                guard !self.pending.isEmpty else { break }
                await self.sleep(Self.deferralPollSeconds)
            }
            self?.drainTask = nil
            // A replay closure speaks, and speaking can re-open a window; anything routed
            // from inside the replay therefore queues while *this* task is still the drain,
            // so `startDraining` declined to spawn a second one. Handing the queue back here
            // is what keeps such an entry from waiting on an unrelated arrival to notice it.
            if let self, !self.pending.isEmpty { self.startDraining() }
        }
    }

    /// Which of the two legal moments a held entry is coming out into.
    ///
    /// The queue, the order, and the whole of what is delivered are the same for both — the
    /// difference is only what a log reader is owed. "The window finally closed" and "the
    /// wearer was already listening" are different explanations for the same sentence
    /// arriving late, and a run being read after the fact has to be able to tell them apart.
    private enum DeliveryMoment: String {
        /// The command window closed: the pause the deferral was originally waiting for.
        case closedWindow = "closed_window"
        /// The window is open, and it is a voice session's idle wait — see `idleListening`.
        case idleWait = "idle_wait"
    }

    /// Plays everything held, oldest first, and empties the queue.
    ///
    /// The queue is emptied *before* anything is played: a replay closure speaks, speaking
    /// can re-enter this actor, and a re-entrant drain that still saw the entries would say
    /// them twice.
    ///
    /// One function for both moments, and deliberately not two: a drain that could deliver
    /// *part* of the queue is how the one sequence the wearer hears gets re-ordered, and the
    /// only thing the two moments disagree about is a field in a diagnostic.
    private func deliverPending(into moment: DeliveryMoment) {
        let due = pending
        guard !due.isEmpty else { return }
        pending.removeAll()
        let current = now()
        for entry in due {
            diagnostics.record("notification.delivered", fields: [
                "waited": secondsField(current.seconds(after: entry.deferredAt)),
                "kind": entry.kind.diagnosticLabel,
                "into": moment.rawValue,
            ])
            entry.play(entry.verdict)
        }
    }

    /// Drops entries that have waited longer than they are worth. See
    /// `maximumDeferralSeconds` for why the bound exists and why expiry drops rather than
    /// finally speaks.
    ///
    /// One bound, two events: a stale notice is a count in a log, and a review sentence TapQ
    /// composed and never said is its own line, with a hook for whoever wants to do more
    /// about it than log it. Anyone reading a log has to be able to tell the two apart
    /// without parsing fields, so they are separate names.
    private func expireOverdue() {
        let current = now()
        var kept: [Pending] = []
        var expiredAnnouncements = 0
        var expiredLoopSpeech: [String] = []
        for entry in pending {
            guard current.seconds(after: entry.deferredAt) >= Self.maximumDeferralSeconds else {
                kept.append(entry)
                continue
            }
            switch entry.kind {
            case .announcement: expiredAnnouncements += 1
            case .loopSpeech(let text): expiredLoopSpeech.append(text)
            }
        }
        guard kept.count != pending.count else { return }
        // Emptied before anything is handed out, for `deliverPending`'s reason: the expiry
        // hook is composition's code, it can route again, and a re-entrant drain that still
        // saw these entries would expire them twice.
        pending = kept
        if expiredAnnouncements > 0 {
            diagnostics.record("notification.dropped_expired", level: .warning, fields: [
                "count": "\(expiredAnnouncements)",
                "after": secondsField(Self.maximumDeferralSeconds),
            ])
        }
        for text in expiredLoopSpeech {
            // The text goes to the hook and not to the log: a diagnostic line carries the
            // shape of what happened, and what TapQ was about to say is the wearer's.
            diagnostics.record("notification.loop_speech_expired", level: .warning, fields: [
                "characters": "\(text.count)",
                "after": secondsField(Self.maximumDeferralSeconds),
            ])
            onExpiredLoopSpeech?(text)
        }
    }

    /// What two announcements have to share to be the same piece of news.
    private static func key(_ announcement: Announcement) -> String {
        switch announcement {
        case .agentNotification(let kind, let sessionID): return "\(kind)/\(sessionID)"
        case .requestPrompt(let sessionID): return "prompt/\(sessionID)"
        case .deferToScreen: return "deferToScreen"
        case .motionLost: return "motionLost"
        case .wearerInitiated: return "wearerInitiated"
        }
    }

    /// What two loop sentences have to share to be the same sentence: the sentence. Prefixed
    /// so the two producers cannot collide in the one queue — an announcement key is built
    /// from a fixed vocabulary of kinds, none of which is this one.
    private static func loopSpeechKey(_ text: String) -> String { "loop/\(text)" }

    /// The one function in this type that reads `announcementsEnabled`, and it takes an
    /// agent notification because that is all the flag is about. Loop speech does not come
    /// through here — see `routeLoopSpeech`.
    private func routeAgentNotification(kind: AgentNotification.Kind,
                                        sessionID: String) -> Verdict {
        // The flag is a hard gate, checked before the dedupe slot is spent, so a mark
        // always means "the wearer was told" rather than "an event went past".
        guard settings.announcementsEnabled else { return .suppress }
        switch kind {
        case .waitingForInput, .permissionWaiting:
            // Waiting is a state, and a state is announced once. The registry covers the
            // sessions queued at the gate — those are about to be spoken to directly —
            // and the mark covers the ones announced before that.
            if waits.agentDisplayName(forSession: sessionID) != nil
                || announced.contains(sessionID) {
                return .suppress
            }
            announced.insert(sessionID)
        case .finished:
            // Finishing ends the wait, so the next one is news again. Finishes themselves
            // are not deduped: a session that finishes twice has taken two turns, and the
            // wearer wanting to know both is the whole point of the notification.
            announced.remove(sessionID)
        }
        return settings.quiet ? .chime(.notification) : .speak
    }
}
