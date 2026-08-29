import Foundation
import TapQContracts

/// What became of one sentence handed to a voice backend.
///
/// Notice what is missing: there is no "the backend declined, say it yourself". That
/// outcome is what this whole seam exists to delete — see `BackendSpeechSink`.
public enum BackendSpeechDelivery: Sendable, Equatable {
    /// Handed to the backend now.
    case spoken
    /// Accepted, and waiting for a legal moment on a pipe that is momentarily busy. It
    /// keeps its place in line; nothing further is required of the caller.
    case queued
    /// Not spoken, and nothing is wrong: there was nothing to say, or the run is ending.
    case dropped(String)
}

/// The one voice a run with a specified backend has.
///
/// ## What changed, and why
///
/// This replaces `BackendPreferredSpeech`, whose rule was that only `.notification`
/// utterances went to the backend and everything else — prompts, read-backs, "Listening.",
/// "Queued for Codex.", every declined route — went to the local synthesizer. The reasoning
/// was sound in isolation (a duplex backend renders text by *generating* from it, and no
/// model should get to rewrite the sentence that names what a wearer is authorizing) and it
/// produced a run that did not work:
///
/// * Two voices alternated sentence by sentence, which is not the backend the operator
///   asked for by name on the command line.
/// * The local synthesizer plays out of the Mac's speaker into the same room as the open
///   realtime microphone. On hardware (2026-08-27) the service reported
///   `native_turn.speech_started` during TapQ's own playback and transcribed it as wearer
///   speech; one such transcript matched the grammar as `no` and ended a session.
///
/// So the sink is total: **every sentence TapQ speaks goes to the specified backend**. The
/// consent problem the old split worried about is real and is answered where it belongs —
/// on the wire, by asking for the sentence back verbatim
/// (`VoiceBackend.requestScriptedSpeech`, and for the realtime adapter an out-of-band
/// response whose only instruction is to repeat the text between markers) rather than by
/// keeping a second synthesizer alive for it.
///
/// ## After the break
///
/// The rule is "no second voice **while the backend is alive**", and the qualifier is the
/// whole of the exception. Once the run's voice pipe has died — `VoiceBrokenState` latched,
/// the wearer told once, the microphone gone for good — there is no pipe to route to, and a
/// run that then said nothing at all would open windows with silent prompts and expect a nod
/// for a question nobody heard. So from the break onwards, and only from then, utterances go
/// to `localAfterBreak`.
///
/// This is not the fallback the type exists to delete. That one fired per utterance, while
/// the backend was healthy and speaking other sentences, and produced the two alternating
/// voices. This one is a one-way gate on a dead pipe: it can only open after a failure that
/// has already been reported at error level and announced to the wearer, and once open it
/// never closes, because the break never lifts. A composition that passes no
/// `localAfterBreak` — every test, and any host with no synthesizer — simply records the
/// utterance and says nothing, which is the honest behavior for a run with no voice left.
///
/// ## Failure
///
/// A sentence the backend cannot carry is a voice-pipeline failure, not a cue to fall back.
/// The provider reports those to its own `onScriptedSpeechUndeliverable`, which composition
/// wires to the run's break latch; this sink only records what it was told, because the
/// discovery is usually asynchronous (a handshake that fails a second later) and the caller
/// that spoke has long since moved on.
@MainActor public final class BackendSpeechSink: SpeechPresenting {
    /// Offers `text` to the backend and reports what became of it. Composition passes
    /// `VoiceBackendCommandProvider.speakScripted`.
    public typealias SpeechRouting = @MainActor (String) -> BackendSpeechDelivery

    private let route: SpeechRouting
    private let stop: @MainActor () -> Void
    private let localAfterBreak: (any SpeechPresenting)?
    private let isBackendBroken: @MainActor () -> Bool
    private let diagnostics: TapQDiagnosticEmitter

    /// - Parameters:
    ///   - route: where a sentence goes. A closure rather than a provider reference so this
    ///     module keeps its one-way dependency on `TapQContracts` and so the routing policy
    ///     is testable with no backend at all.
    ///   - stop: what `stopAll()` means for a backend-voiced run: forget the sentences that
    ///     have not gone out yet. While the backend is alive it cannot mean "silence the
    ///     synthesizer", because there isn't one in use.
    ///   - localAfterBreak: the synthesizer that takes over once the run's voice pipe is
    ///     dead, and at no other time. See "After the break". `nil` — every test, and any
    ///     host without one — means a broken run says nothing.
    ///   - isBackendBroken: the run's break latch, read per utterance. It answers `false`
    ///     for the whole of a healthy run, which is what keeps the local engine unreachable
    ///     while there is a pipe to reach instead.
    public init(route: @escaping SpeechRouting,
                stop: @escaping @MainActor () -> Void = {},
                localAfterBreak: (any SpeechPresenting)? = nil,
                isBackendBroken: @escaping @MainActor () -> Bool = { false },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.route = route
        self.stop = stop
        self.localAfterBreak = localAfterBreak
        self.isBackendBroken = isBackendBroken
        self.diagnostics = TapQDiagnosticEmitter(category: "BackendSpeech", sink: diagnosticSink)
    }

    /// `onFinish` fires as soon as the backend has taken the sentence — or accepted it into
    /// the queue — rather than when its audio drains.
    ///
    /// The backend reports acceptance, not completion: `requestScriptedSpeech` has no
    /// finish callback to relay. Callers use `onFinish` to sequence what happens next, and
    /// holding it for a signal that never arrives would strand them. Nothing is lost by
    /// firing early, because the thing that happens next is almost always a listening
    /// window, and the *provider* is what protects that: it knows a response is pending and
    /// defers the user turn rather than opening a microphone over TapQ's own voice.
    public func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
        let length = "\(text.count)"
        guard !isBackendBroken() else {
            // The pipe the operator named is gone and is never coming back this run. Windows
            // still open and still resolve by gesture, tap, and timeout, and a prompt nobody
            // can hear would make those windows unanswerable.
            diagnostics.record("utterance.spoken_locally_after_break",
                               fields: ["length": length, "priority": Self.name(priority)])
            guard let localAfterBreak else {
                onFinish?()
                return
            }
            localAfterBreak.speak(text, priority: priority, onFinish: onFinish)
            return
        }
        switch route(text) {
        case .spoken:
            diagnostics.record("utterance.spoken_by_backend",
                               fields: ["length": length, "priority": Self.name(priority)])
        case .queued:
            diagnostics.record("utterance.queued_for_backend",
                               fields: ["length": length, "priority": Self.name(priority)])
        case .dropped(let reason):
            diagnostics.record("utterance.dropped",
                               fields: ["length": length, "priority": Self.name(priority),
                                        "reason": reason])
        }
        onFinish?()
    }

    /// Drops what has not been said yet. An utterance already handed to the backend is the
    /// backend's to end, and the paths that must end one — barge-in, a window resolving —
    /// cancel it through the provider's own suppression paths rather than through here.
    public func stopAll() {
        stop()
        // After the break the local engine is the one holding utterances, so it is the one
        // that has to be silenced. Before it, this is a no-op on an engine nothing is using.
        localAfterBreak?.stopAll()
    }

    private static func name(_ priority: SpeechPriority) -> String {
        switch priority {
        case .progress: return "progress"
        case .notification: return "notification"
        case .approval: return "approval"
        }
    }
}
