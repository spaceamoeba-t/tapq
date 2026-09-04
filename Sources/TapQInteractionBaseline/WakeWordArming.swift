import Foundation
import TapQContracts

/// Decides what a wake word does, and opens exactly one window for it
/// (`docs/WAKE_WORD_PLAN.md` §3).
///
/// Deliberately shaped like `AttentionArming`, whose job it is doing for a different
/// opener: the spotter decides that the phrase was said, `CommandWindowController` decides
/// what a window may do, and this decides *whether there should be one*. The difference is
/// that a wake word is a sentence the wearer chose to say to TapQ, so where the attention
/// arming can ignore an onset in silence, two of the three refusals here are spoken (§1,
/// rule 7).
///
/// Three ways not to open, in the order they are asked:
///
/// 1. **Something is waiting.** A request at the gate is a question the wearer is already
///    being asked, and its own window has the microphone. Said out loud, because the wearer
///    said a word expecting an answer and would otherwise be standing in silence.
/// 2. **A held-boundary loop is listening.** The wake word is redundant — TapQ is already
///    listening, and the sentence after it is going to be heard by the window that is open.
///    Nothing is said: an answer here would talk over the window doing the listening.
/// 3. **A wake window is already open.** Same reasoning, one step earlier.
@MainActor public final class WakeWordArming {
    /// Said when a request is waiting at the gate. It is the whole answer: what is waiting
    /// is not this arming's to describe (the request window will say it), and a wake word
    /// answered with a list of agents would be TapQ using the wearer's attention to talk
    /// about itself.
    public nonisolated static let requestWaitingRefusal = "Something is waiting for you first."

    private let waits: SessionWaitRegistry
    private let isVoiceSessionListening: @MainActor () -> Bool
    private let speak: @MainActor (String) -> Void
    private let makeController: @MainActor () -> CommandWindowController
    private let diagnostics: TapQDiagnosticEmitter
    private var isRunning = false

    /// Fired when a window opens and again when it closes, so the gate can suspend the
    /// spotter for exactly as long as the window it opened is running. A closure rather
    /// than the gate itself, because the arming is built first and neither should hold the
    /// other.
    public var onWindowChanged: (@MainActor () -> Void)?

    /// Whether a wake window is open right now. The gate's first condition, and the reason
    /// one wake word cannot produce two windows.
    public var isWindowOpen: Bool { isRunning }

    public init(waits: SessionWaitRegistry,
                isVoiceSessionListening: @escaping @MainActor () -> Bool,
                speak: @escaping @MainActor (String) -> Void,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                makeController: @escaping @MainActor () -> CommandWindowController) {
        self.waits = waits
        self.isVoiceSessionListening = isVoiceSessionListening
        self.speak = speak
        self.makeController = makeController
        self.diagnostics = TapQDiagnosticEmitter(category: "WakeWord", sink: diagnosticSink)
    }

    /// The phrase was heard. The transcript it was found in is not used and never spoken:
    /// what the wearer says *after* the phrase is the realtime session's to hear, and this
    /// one recognizer's guess at the words around a keyword is not evidence of anything.
    public func wakeWordHeard() {
        guard waits.waitingCount == 0 else {
            diagnostics.record("wake.refused_request_waiting", fields: [
                "waiting": "\(waits.waitingCount)",
            ])
            speak(Self.requestWaitingRefusal)
            return
        }
        guard !isVoiceSessionListening() else {
            diagnostics.record("wake.ignored_listening")
            return
        }
        guard !isRunning else {
            diagnostics.record("wake.ignored_window_open")
            return
        }
        isRunning = true
        diagnostics.record("window.arming")
        onWindowChanged?()
        // Detached from the caller's turn for the reason the attention arming detaches from
        // the motion callback: this is running inside a recognition callback, and a
        // twenty-second window must not run inside one.
        let controller = makeController()
        Task { @MainActor [weak self] in
            let outcome = await controller.run()
            self?.isRunning = false
            self?.diagnostics.record("window.finished", fields: [
                "answers": "\(outcome.answers)",
                "ignored": "\(outcome.ignored)",
                "dictations": "\(outcome.dictations)",
            ])
            self?.onWindowChanged?()
        }
    }
}

/// Owns when the wake-word spotter runs (`docs/WAKE_WORD_PLAN.md` §2, "suspend and resume").
///
/// The spotter has its own microphone and its own recognizer, and TapQ has one of each to
/// give. So the rule is that it listens only when nothing else does: no wake window, no
/// attention window, no request waiting, no held-boundary loop, and no TapQ speech still
/// sounding. Every one of those is somebody else's state, which is why they arrive here as
/// closures and a call to ``reevaluate()`` rather than as a subscription this type invents
/// — one answer per question, read from the object that owns it.
///
/// The conditions are ordered, and the order is only about the diagnostic: `wake.suspended
/// reason=…` names the first one that holds, which is the one to read when a spotter is
/// unexpectedly deaf.
@MainActor public final class WakeWordGate {
    /// One reason the spotter may not run, and how to ask whether it holds now.
    public struct Condition: Sendable {
        /// What the diagnostic says. Short and closed: `window`, `attention`, `waiting`,
        /// `listening`, `speaking`.
        public let reason: String
        public let isBlocking: @MainActor () -> Bool

        public init(reason: String, isBlocking: @escaping @MainActor () -> Bool) {
            self.reason = reason
            self.isBlocking = isBlocking
        }
    }

    /// Said once, when the spotter gives up on its own. A wake word that is not being
    /// listened for is the one failure the wearer cannot discover by trying — they say the
    /// phrase into a room that was never going to answer — so it is announced rather than
    /// logged. Not a break: everything else about the run still works.
    public nonisolated static let listeningStoppedNotice = "Wake word listening stopped."

    private let spotter: any WakeWordSpotting
    private let conditions: [Condition]
    private let onWake: @MainActor () -> Void
    private let speak: @MainActor (String) -> Void
    private let diagnostics: TapQDiagnosticEmitter
    /// What this gate last decided, not what the spotter reports. The two agree except
    /// inside `stop()`, and a decision that read its own effect back would restart a
    /// spotter that had just been told to give up.
    private var wantsSpotting = false
    private var hasEverStarted = false
    private var gaveUp = false
    private var isShutDown = false

    public init(spotter: any WakeWordSpotting,
                conditions: [Condition],
                onWake: @escaping @MainActor () -> Void,
                speak: @escaping @MainActor (String) -> Void,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.spotter = spotter
        self.conditions = conditions
        self.onWake = onWake
        self.speak = speak
        self.diagnostics = TapQDiagnosticEmitter(category: "WakeWord", sink: diagnosticSink)
        spotter.onStopped = { [weak self] reason in
            self?.spotterGaveUp(reason)
        }
    }

    /// Whether the gate currently wants the spotter listening. For diagnostics and tests.
    public var isSpotting: Bool { wantsSpotting }

    /// Asks the question again. Called on every transition of anything a condition reads;
    /// cheap, idempotent, and safe to call when nothing changed.
    public func reevaluate() {
        guard !isShutDown, !gaveUp else { return }
        if let blocking = conditions.first(where: { $0.isBlocking() }) {
            guard wantsSpotting else { return }
            wantsSpotting = false
            spotter.stop()
            diagnostics.record("wake.suspended", fields: ["reason": blocking.reason])
            return
        }
        guard !wantsSpotting else { return }
        wantsSpotting = true
        spotter.start { [weak self] _ in
            self?.heard()
        }
        diagnostics.record(hasEverStarted ? "wake.resumed" : "wake.armed")
        hasEverStarted = true
    }

    /// The run is over. The spotter is stopped and stays stopped: a later transition must
    /// not put a microphone back up under a runtime that is tearing its voice down.
    public func shutdown() {
        isShutDown = true
        wantsSpotting = false
        spotter.stop()
    }

    private func heard() {
        onWake()
        // The window the arming just opened is itself a reason to suspend, and asking now
        // rather than waiting for its own signal is what keeps the spotter off the
        // microphone the window is about to want. The listener schedules its restart before
        // it calls back, precisely so a `stop()` from in here wins.
        reevaluate()
    }

    private func spotterGaveUp(_ reason: String) {
        guard !gaveUp, !isShutDown else { return }
        gaveUp = true
        wantsSpotting = false
        diagnostics.record("wake.gave_up", level: .warning, fields: ["reason": reason])
        speak(Self.listeningStoppedNotice)
    }
}
