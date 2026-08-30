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
/// Two jobs, both of which used to be nowhere:
///
/// * **Quiet routing.** Under `--quiet` the utterances that exist to get the wearer's
///   attention become a cue, and the ones that answer the wearer stay speech.
/// * **Per-session dedupe.** A session already known to be waiting is not announced
///   again. The registry answers for the sessions queued at the gate right now; the
///   policy's own marks answer for the ones announced earlier and not yet finished.
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
    /// re-opens eight-second windows back to back for as long as a turn boundary is held, so
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
    static let maximumDeferralSeconds: TimeInterval = 60

    private let settings: Settings
    private let waits: SessionWaitRegistry
    private let commandWindowOpen: CommandWindowPresence?
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

    /// One held notice: what it would have played, who plays it, and when it started waiting.
    private struct Pending {
        let announcement: Announcement
        let verdict: Verdict
        let deferredAt: ContinuousClock.Instant
        /// The caller's own replay. The policy composes no utterances and holds no
        /// `AgentNotification`, so the only honest way to say a held sentence later is to
        /// hand the verdict back to whoever knew how to say it in the first place.
        let play: @MainActor (Verdict) -> Void
        /// What two notices have to share to be the same piece of news.
        let key: String
    }

    /// - Parameter commandWindowOpen: absent means this policy never defers, which is what
    ///   every composition without command windows wants and what the tests that predate
    ///   them assert.
    public init(settings: Settings = Settings(),
                waits: SessionWaitRegistry,
                commandWindowOpen: CommandWindowPresence? = nil,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.settings = settings
        self.waits = waits
        self.commandWindowOpen = commandWindowOpen
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
    ///   open. A caller that supplies nothing cannot be handed `.deferred` — it would have no
    ///   way to honour it, and "later" with no later is the silent drop this whole mechanism
    ///   is against — so such a call routes exactly as it always did.
    public func route(_ announcement: Announcement,
                      whenDeferred: (@MainActor (Verdict) -> Void)? = nil) -> Verdict {
        switch announcement {
        case .agentNotification(let kind, let sessionID):
            let verdict = routeAgentNotification(kind: kind, sessionID: sessionID)
            return hold(announcement, verdict: verdict, play: whenDeferred) ?? verdict
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

    /// Drops a session's dedupe mark, so its next wait announces again.
    ///
    /// Called when a request for the session resolves. Nothing expires on its own here,
    /// for `SessionWaitRegistry`'s reason: a mark that timed itself out would re-announce
    /// a wait the wearer is still looking at.
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

    /// Holds `announcement` back if it would make a sound into an open command window.
    ///
    /// The shape is ratified and it is *defer, not race*: the alternative — speak now, at
    /// `.notification` priority, into a window whose recognizer the speech gate then tears
    /// down while the window's own timer keeps counting — spends most of an eight-second
    /// window on a sentence about a different session, and the wearer's answer to the
    /// question they were actually being asked lands in a microphone that was closed for it.
    /// `StopQuestionCoordinator.noteNarrationNotice` is the precedent: a notice that cannot
    /// be said now is queued for the next legal moment, not shouted over the moment in hand.
    ///
    /// Returns `.deferred` when it took the announcement, `nil` when the caller should
    /// proceed with the verdict it already has.
    private func hold(_ announcement: Announcement,
                      verdict: Verdict,
                      play: (@MainActor (Verdict) -> Void)?) -> Verdict? {
        // Nothing to hold back: a suppressed announcement makes no sound to begin with, and
        // there is no window to protect.
        guard verdict != .suppress, commandWindowOpen?() == true else { return nil }
        guard let play else {
            // A caller with no replay is told to go ahead. It is the lesser wrong: speaking
            // into a window is a bad turn, and holding a notice nobody can ever play is a
            // notice that vanishes — and the one thing this type may not do is lose an event
            // quietly. Recorded, so a log can tell the two apart.
            diagnostics.record("notification.deferral_unavailable", level: .warning,
                               fields: ["announcement": Self.key(announcement)])
            return nil
        }
        let key = Self.key(announcement)
        if pending.contains(where: { $0.key == key }) {
            // The same sentence twice, both of them waiting out the *same* window. Two
            // finishes separated by real time are two pieces of news and both are still
            // announced — that rule is untouched. Two finishes separated by nothing are one
            // sentence said twice in a row, which is not news, it is a stutter.
            diagnostics.record("notification.dropped_stale",
                               fields: ["reason": "duplicate", "held": "\(pending.count)"])
            return .deferred
        }
        pending.append(Pending(announcement: announcement, verdict: verdict,
                               deferredAt: now(), play: play, key: key))
        diagnostics.record("notification.deferred",
                           fields: ["held": "\(pending.count)"])
        startDraining()
        return .deferred
    }

    /// Marks everything held for `sessionID` stale, because the wearer has just been told
    /// something more current about it through a route that was not deferred.
    ///
    /// "Claude Code finished" is worth saying until the wearer is being asked a fresh
    /// question from that same session, at which point it is a sentence about the past
    /// arriving after the present. Dropped, and counted — never silently.
    private func markSuperseded(sessionID: String) {
        let before = pending.count
        pending.removeAll { $0.announcement.sessionID == sessionID }
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
                    self.deliverPending()
                    break
                }
                self.expireOverdue()
                guard !self.pending.isEmpty else { break }
                await self.sleep(Self.deferralPollSeconds)
            }
            self?.drainTask = nil
        }
    }

    /// Plays everything held, oldest first, and empties the queue.
    ///
    /// The queue is emptied *before* anything is played: a replay closure speaks, speaking
    /// can re-enter this actor, and a re-entrant drain that still saw the entries would say
    /// them twice.
    private func deliverPending() {
        let due = pending
        pending.removeAll()
        let current = now()
        for entry in due {
            diagnostics.record("notification.delivered", fields: [
                "waited": secondsField(current.seconds(after: entry.deferredAt)),
            ])
            entry.play(entry.verdict)
        }
    }

    /// Drops notices that have waited longer than a notice is worth. See
    /// `maximumDeferralSeconds` for why the bound exists and why expiry drops rather than
    /// finally speaks.
    private func expireOverdue() {
        let current = now()
        let before = pending.count
        pending.removeAll {
            current.seconds(after: $0.deferredAt) >= Self.maximumDeferralSeconds
        }
        let dropped = before - pending.count
        guard dropped > 0 else { return }
        diagnostics.record("notification.dropped_expired", level: .warning, fields: [
            "count": "\(dropped)",
            "after": secondsField(Self.maximumDeferralSeconds),
        ])
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
