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
    }

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

    private let settings: Settings
    private let waits: SessionWaitRegistry
    /// Sessions announced as waiting and not yet finished or forgotten.
    private var announced: Set<String> = []

    public init(settings: Settings = Settings(), waits: SessionWaitRegistry) {
        self.settings = settings
        self.waits = waits
    }

    /// Routes one announcement, spending its dedupe slot.
    ///
    /// Named for the side effect as much as the answer: calling it twice for the same
    /// waiting session is how the second call gets `.suppress`, so a caller that wants to
    /// know the verdict without consuming the slot wants `Verdict` arithmetic it does not
    /// have — deliberately, because a "peek" that drifted out of sync with the route would
    /// announce the same wait twice.
    public func route(_ announcement: Announcement) -> Verdict {
        switch announcement {
        case .agentNotification(let kind, let sessionID):
            return routeAgentNotification(kind: kind, sessionID: sessionID)
        case .requestPrompt(let sessionID):
            // The wearer is being asked about this session right now, which is the
            // strongest possible form of "already announced": a `waitingForInput` arriving
            // behind the prompt says nothing the prompt did not.
            announced.insert(sessionID)
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
