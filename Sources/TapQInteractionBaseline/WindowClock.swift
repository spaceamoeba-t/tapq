import Foundation
import TapQContracts

/// When a command window's eight seconds are allowed to start counting, and how long a
/// listen has to stay open for speech that happened inside them.
///
/// ## The bug these constants exist for
///
/// A command window used to set `deadline = now() + 8s` at controller entry, consulting
/// nothing about whether TapQ was still talking. It very often was: the window before it
/// speaks its last answer *as it closes* (`CommandWindowController.loop`'s residual
/// `pending`), and `VoiceSessionListening` opens the next window in the same actor turn. So
/// the countdown started while the audio was still draining, and `SpeechGatedVoice` — doing
/// exactly its job — held the microphone shut for the first several seconds of it.
///
/// The sweep measured it on hardware: 12 of 40 eight-second voice-session windows opened
/// with `[SpeechGate] microphone.held_closed`. The clock and the microphone disagreed about
/// when the window began, and the wearer paid the difference.
///
/// The cure is stated once, here, and applied in `CommandWindowController`: **a window
/// delivers eight seconds of microphone that can actually hear, and TapQ's own voice is
/// never charged to the wearer.**
enum WindowClock {
    /// How long after the wearer stops speaking their turn actually commits.
    ///
    /// Two delays in series, both on the IMU turn-control path: the wearer-speech detector's
    /// own hangover keeps the state `speaking` for a beat after the last active window, and
    /// `WearerTurnCoordinator` then waits out an endpoint delay before calling `endpoint()`.
    /// Sweep finding F11: a listen that closes exactly on the deadline throws away speech
    /// that arrived inside the window and was still being committed when it closed.
    ///
    /// The endpoint delay is read from its owner. The hangover is mirrored rather than read:
    /// it lives in `WearerSpeechConfig.hangoverSeconds` (TapQDetectionBaseline), and this
    /// module depends only on TapQContracts. `VoiceSessionE2ETests` — a target that can see
    /// both — pins the two numbers together so the mirror cannot drift in silence.
    static let detectorHangover: TimeInterval = 0.6

    /// The allowance a listen adds so speech that started inside the window can finish
    /// committing. Not extra window: extra *wait* for an answer already given.
    static var commitAllowance: TimeInterval {
        WearerTurnCoordinator.defaultEndpointDelay + detectorHangover
    }

    /// The longest a window will hold its clock back waiting for TapQ's own audio to stop.
    ///
    /// Long enough for any sentence TapQ composes — `SpokenText.condensed` caps a read-back
    /// at 160 characters, about 13 seconds at `SpokenPace.charactersPerSecond` — and short
    /// enough that a wedged synthesizer or a stuck player costs one window rather than the
    /// session. Waiting is cheap while the signal is honest (the microphone really is shut,
    /// so nothing is being missed) and this bound is what keeps it cheap when it is not.
    static let maxDrainWait: TimeInterval = 15

    /// How often the deferral loop re-reads the busy signal.
    ///
    /// A poll rather than an edge: `SpeechActivitySignaling.onSpeakingChange` is a
    /// single-observer slot and `SpeechGatedVoice` owns it. Reading `isSpeaking` takes
    /// nothing away from that owner, which is the whole reason the seam below is a getter and
    /// not a subscription.
    static let drainPollInterval: TimeInterval = 0.1
}

/// What TapQ's own voice is doing, asked in the two ways it can be answered.
///
/// Neither reading is sufficient alone, which is why this type holds both:
///
/// - **The live signal** (`isSounding`) is the truth about whether audio is sounding *right
///   now*, and it is the same signal `SpeechGatedVoice` gates the microphone on — on the
///   Apple path the speech engine, and with a backend player composed the
///   `CombinedSpeechActivity` merge of engine and player. It is the only thing that knows
///   about audio TapQ never handed over as text, which on the realtime path is most of what
///   the wearer hears. What it cannot say is *how much longer*: it is a `Bool`.
/// - **The pace estimate** (`estimatedRemainder`) knows how much longer, because it is
///   computed from the text at hand-over time by `SpokenPace`. It is also the only reading
///   that covers the gap `SpokenTurnBudget` documents at length: `onFinish` fires when the
///   backend *accepts* a sentence, and playback starts hundreds of milliseconds later, so
///   for that window "not speaking yet" and "already drained" are the same reading from the
///   live signal.
///
/// So a window waits out the live signal and then credits whatever the estimate still has
/// ahead of it. Where no signal is reachable the estimate carries the whole weight, which is
/// the honest degrade: it is deterministic, it errs long, and a window that over-waits costs
/// the wearer a pause, while one that under-waits costs them the sentence.
///
/// ## Why it is shared, and by whom
///
/// One instance per run, held by the composition and handed to every window it builds. The
/// sentence a window speaks as it closes is drained by the window *after* it — different
/// controller, same voice — so the record has to outlive any one of them. Only
/// `CommandWindowController` writes to it.
@MainActor public final class VoiceChannelDrain {
    /// Reads the live busy signal. `nil` where no signal is reachable, and the estimate is
    /// then the only reading — never an assumption that the channel is quiet.
    private let isSounding: (@MainActor () -> Bool)?
    /// When everything handed over so far will have finished sounding, by the pace estimate.
    private var quietAt: ContinuousClock.Instant?

    /// - Parameter isSounding: a *read* of `SpeechActivitySignaling.isSpeaking`, never a
    ///   claim on `onSpeakingChange` — that slot belongs to `SpeechGatedVoice`, and a second
    ///   assignment would silently disable the self-hearing guard.
    public init(isSounding: (@MainActor () -> Bool)? = nil) {
        self.isSounding = isSounding
    }

    /// Whether the live signal says audio is sounding. `false` when there is no signal —
    /// callers pair this with `estimatedRemainder`, which is what actually covers that case.
    var isLiveSounding: Bool { isSounding?() ?? false }

    /// Whether TapQ's own voice is occupying the channel right now, by either reading.
    ///
    /// Both, because either alone is wrong in a way that matters to a caller outside a
    /// window: the live signal cannot see a sentence that has been accepted by a backend and
    /// has not started playing, and the estimate cannot see audio TapQ never handed over as
    /// text. A window resolves that pair by waiting out one and adding the other; a caller
    /// that only needs a yes or no — the wake-word gate, deciding whether a spotter may hold
    /// the microphone — asks it here rather than restating the arithmetic.
    public var isBusy: Bool {
        isLiveSounding || estimatedRemainder(at: .now) > 0
    }

    /// Records that `text` has been handed to the speech channel at `instant`.
    ///
    /// Utterances queue rather than overlap — the speech engine speaks them in order — so a
    /// sentence handed over while the previous one is still sounding starts when that one
    /// ends. Empty and absent text occupy nothing.
    func willSpeak(_ text: String?, at instant: ContinuousClock.Instant) {
        guard let text, !text.isEmpty else { return }
        let starts = max(instant, quietAt ?? instant)
        quietAt = starts.advanced(by: .seconds(SpokenPace.drainSeconds(of: text)))
    }

    /// Estimated seconds of TapQ's own audio still ahead at `instant`; zero once it has
    /// drained, and zero before anything has been said.
    func estimatedRemainder(at instant: ContinuousClock.Instant) -> TimeInterval {
        guard let quietAt else { return 0 }
        return max(0, quietAt.seconds(after: instant))
    }
}
