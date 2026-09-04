import Foundation

/// The opener for a session that does not exist yet (`docs/WAKE_WORD_PLAN.md`).
///
/// Every other listening window is opened by something that already exists: an agent's
/// request, a held turn boundary, an attributed speech onset. A wake-word spotter is the
/// one opener that needs nothing running. It hears the room, on device, and fires once
/// when the wearer says the phrase; what the wearer says *after* the phrase is not its
/// business — the runtime opens a command window and the realtime session hears that.
///
/// Implemented over Apple's on-device speech recognition in `TapQAppleAdapters`. That is
/// the Speech framework used as a keyword spotter, not the deprecated Apple voice backend:
/// nothing a spotter hears is ever matched against a grammar or spoken by a local voice.
///
/// The runtime starts and stops it around everything else that wants the microphone: a
/// spotter never runs while a window is open, a request is waiting, a held-boundary loop
/// is listening, or TapQ's own speech is draining. A spotter that cannot start says so
/// through diagnostics and stays stopped; the caller decides whether to say it out loud.
@MainActor public protocol WakeWordSpotting: AnyObject {
    /// True between a successful `start` and the matching `stop`. A spotter that lost its
    /// recognizer mid-run and could not restart reports false here and fires `onStopped`.
    var isSpotting: Bool { get }

    /// Begins listening for the phrase. `onWake` fires on the main actor at most once per
    /// underlying recognition request, with the transcript the phrase was found in.
    /// Calling `start` while spotting is a no-op, recorded in diagnostics.
    func start(onWake: @escaping @MainActor (_ transcript: String) -> Void)

    /// Stops listening and releases the microphone. Idempotent.
    func stop()

    /// Fired once when the spotter gave up on its own — the recognizer became unavailable
    /// and restarts kept failing. Not fired for a caller's `stop()`. The runtime uses it to
    /// say "Wake word listening stopped." once, through the backend voice.
    var onStopped: (@MainActor (_ reason: String) -> Void)? { get set }
}
