import Foundation
import TapQContracts

/// When a matched command is allowed to fire, given that the transcript it matched may
/// still be growing.
///
/// `VoiceCommandMatcher` answers *what* a transcript means. This answers *when* that
/// meaning can be acted on, and the two questions are genuinely separate: the grammar is
/// right about "OK" — that text is an approval — and it is right about "ok, skip the
/// command" — that text is a deferral. What went wrong on hardware was neither answer but
/// the moment of the question. A streaming recognizer reports the utterance so far, so the
/// grammar was handed "OK" while the wearer was still saying the rest of the sentence, the
/// approval fired, and the recognizer was torn down before "skip" existed. The wearer meant
/// skip; the runtime approved. Observed twice, 2026-08-27.
///
/// The rule this gate applies, in one line: a command that decides something fires only on
/// a transcript that has stopped changing; a command that decides nothing fires at once.
///
/// "Stopped changing" is two conditions, either of which is enough:
///
/// 1. **The recognizer says so.** A result flagged final is the whole utterance by
///    definition, and no later text can contradict it, so it fires immediately.
/// 2. **It has held still long enough.** `SFSpeechRecognizer` fed from a live buffer does
///    not reliably flag anything final until the audio is closed, which on this path only
///    happens at teardown — so waiting for finality alone would mean a spoken "yes" never
///    resolving a window at all. Instead the same match on the same unchanged text, held
///    for `stabilityWindow`, is treated as settled.
///
/// The window is deliberately long enough to cover the gap between two partials of one
/// fluent sentence, because that gap is exactly what the defect exploited: a wearer part
/// way through "ok, skip …" must not be read as a wearer who finished saying "ok". The
/// asymmetry that sets the length is the same one the grammar is built around — a `.no`
/// that lands half a second late costs a beat of latency, a `.yes` that fires on a
/// fragment runs an action nobody authorized — so when in doubt this waits.
///
/// Growth restarts the window rather than extending the old candidate: text that is still
/// arriving is a wearer who is still talking, and the command their next word produces is
/// the one that counts. A transcript that revises down to no match at all drops the
/// candidate outright and fires nothing, which is TapQ's usual fail-open — an unmatched
/// transcript leaves the request to the on-screen prompt, and silence is recoverable in a
/// way a wrong approval is not.
///
/// The gate is a value with no clock and no timer of its own: callers pass the time they
/// read and schedule their own re-check from the interval a `.hold` hands back. That keeps
/// the whole policy testable at wall-clock speeds and keeps timer ownership with the object
/// that already owns a session generation to validate the callback against.
public struct VoicePartialCommandGate {
    /// What the caller should do with the transcript it just admitted.
    public enum Outcome: Equatable {
        /// Deliver this command now.
        case fire(VoiceCommand)
        /// A command matched but is not settled yet. Ask again after this interval unless a
        /// further transcript arrives first, which supersedes the pending re-check.
        case hold(recheckAfter: TimeInterval)
        /// Nothing to act on: the transcript matched no command, or none is pending.
        case idle
    }

    /// How long a matched, mutating command must sit unchanged before it is treated as
    /// settled.
    ///
    /// 0.7 s is the top of the range this fix was scoped to. It sits above the gap between
    /// consecutive partials of a fluent sentence — which is what has to be covered for
    /// "ok, skip the command" to be heard as one sentence rather than two decisions — and
    /// close enough to the silence thresholds speech endpointers use that a wearer who has
    /// actually finished speaking does not notice the wait.
    public static let defaultStabilityWindow: TimeInterval = 0.7

    private let stabilityWindow: TimeInterval
    private var pending: (command: VoiceCommand, transcript: String, since: TimeInterval)?

    public init(stabilityWindow: TimeInterval = VoicePartialCommandGate.defaultStabilityWindow) {
        self.stabilityWindow = stabilityWindow
    }

    /// Offers one recognizer result to the grammar and reports whether its command may fire.
    ///
    /// - Parameters:
    ///   - transcript: the utterance so far, cumulative rather than a delta — the same
    ///     input `VoiceCommandMatcher` has always been given.
    ///   - isFinal: whether the recognizer has settled this transcript.
    ///   - now: a monotonic reading, in seconds. Only differences between readings matter.
    public mutating func admit(
        transcript: String,
        isFinal: Bool,
        at now: TimeInterval
    ) -> Outcome {
        guard let command = VoiceCommandMatcher.match(transcript) else {
            // The recognizer revised the text away from whatever it used to mean. Holding a
            // candidate the current transcript no longer supports would fire a command the
            // wearer's own words have already withdrawn.
            pending = nil
            return .idle
        }
        guard command.mutatesAgentState else {
            pending = nil
            return .fire(command)
        }
        if isFinal {
            pending = nil
            return .fire(command)
        }
        if let candidate = pending,
           candidate.command == command,
           candidate.transcript == transcript {
            return settle(candidate, at: now)
        }
        // Either the first sighting of this command or a transcript that is still growing.
        // Both start the clock over: what matters is how long the text has been still, not
        // how long some earlier reading of it was.
        pending = (command, transcript, now)
        return .hold(recheckAfter: stabilityWindow)
    }

    /// Re-asks about the held candidate without a new transcript — the case a timer covers.
    ///
    /// This is not a nicety. Partials stop arriving the moment the wearer stops speaking,
    /// so a rule that could only be re-evaluated by the next callback would leave the last
    /// word of every utterance waiting for a callback that never comes.
    public mutating func recheck(at now: TimeInterval) -> Outcome {
        guard let candidate = pending else { return .idle }
        return settle(candidate, at: now)
    }

    /// Forgets any held candidate. Called when the window ends: a command that was still
    /// waiting when the microphone closed is one the wearer never got a decision out of,
    /// and it must not survive into whatever opens next.
    public mutating func reset() {
        pending = nil
    }

    /// Fires the candidate if it has been still for the whole window, and otherwise hands
    /// back what is left of it.
    ///
    /// The remainder is recomputed rather than assumed so that a re-check arriving a hair
    /// early — clocks read on two different sources rarely agree to the microsecond —
    /// simply schedules the sliver again instead of firing early or hanging.
    private mutating func settle(
        _ candidate: (command: VoiceCommand, transcript: String, since: TimeInterval),
        at now: TimeInterval
    ) -> Outcome {
        let elapsed = now - candidate.since
        guard elapsed >= stabilityWindow else {
            return .hold(recheckAfter: stabilityWindow - elapsed)
        }
        pending = nil
        return .fire(candidate.command)
    }
}
