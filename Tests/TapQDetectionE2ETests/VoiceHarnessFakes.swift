// The voice-side edges of the E2E harness.
//
// The IMU half of this suite substitutes exactly four things — the motion stream, the
// recognizer, the speech engine, and the clocks — and keeps everything between them real.
// The voice half needs the same treatment one layer lower: a transcript has to be able to
// enter through the *production* provider rather than around it, an utterance has to be
// able to carry its own attribution verdict, and a cue has to be observable where the
// runtime plays one.
//
// So the fakes here are all edges, never logic. `ScriptedVoiceBackend` is a dumb pipe that
// emits the events a test writes down; the turn/session rules that read them belong to the
// real `VoiceBackendCommandProvider`. `ScriptedWearerSignal` answers the two questions
// `WearerSpeechSignaling` asks and decides nothing; the fail-open/fail-closed split that
// consumes them belongs to the real `WearerGatedVoice`. `CueRecorder` writes down cues;
// the speak-or-chime decision belongs to the real `QuietSpeech`.

import Foundation
import XCTest
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

// MARK: - The channel seam

/// The transcript sink `DetectionPathHarness.hear` delivers into.
///
/// Two implementations, and the difference between them is the point of the provider
/// track: `TranscriptVoiceChannel` starts the tested surface at the grammar, while
/// `ProviderVoiceChannel` starts it at the backend event stream and runs the real
/// turn/session machinery in between. A test swaps one for the other and changes nothing
/// else.
@MainActor
protocol HarnessVoiceChannel: VoiceCommandProviding {
    /// Delivers one utterance. `partial` is the recognizer's best guess mid-utterance and
    /// is only meaningful to a channel that has a notion of partials; `final` is the
    /// settled transcript every channel sees.
    func deliver(partial: String?, final: String)

    /// Delivers a transcript the grammar does not know as the free-form command the
    /// realtime path would produce for it.
    func deliverFreeform(_ transcript: String)

    /// False while the channel is still opening on a later main-actor turn — a transcript
    /// delivered now would be dropped. `waitForWindow` waits on this, so a test never has
    /// to know which channel it is driving.
    var isReadyForDelivery: Bool { get }
}

extension HarnessVoiceChannel {
    func deliver(_ transcript: String) {
        deliver(partial: transcript, final: transcript)
    }
}

extension TranscriptVoiceChannel: HarnessVoiceChannel {
    /// The partial is dropped: this channel's `hear` *is* the settled transcript, and
    /// inventing a partial delivery here would fake the one thing the provider channel
    /// exists to test for real.
    func deliver(partial: String?, final: String) {
        hear(final)
    }

    func deliverFreeform(_ transcript: String) {
        hearFreeform(transcript)
    }

    var isReadyForDelivery: Bool { true }
}

/// The production voice path from the backend event stream up: a `ScriptedVoiceBackend`
/// inside a REAL `VoiceBackendCommandProvider` matching with the REAL grammar.
///
/// What this buys over `TranscriptVoiceChannel` is everything the provider wraps around
/// the match and the harness channel used to restate by hand — session and turn lifecycle,
/// teardown-on-match, the handler-nil guard, and the one-shot-per-turn free-form rule. A
/// drift in any of those now fails a test instead of passing one.
@MainActor
final class ProviderVoiceChannel: HarnessVoiceChannel {
    let backend: ScriptedVoiceBackend
    let provider: VoiceBackendCommandProvider

    /// A settable box for the liveness answer. A box rather than a stored property because
    /// the provider's closure is built in `init`, before `self` exists to capture.
    @MainActor private final class Liveness {
        var isLive = true
    }

    private let liveness: Liveness

    /// Whether TapQ's own wearer turn signal is live, as the provider reads it at each
    /// window open. `true` is the IMU-armed run; flipping it between windows is a pair of
    /// AirPods going in or coming out mid-run.
    var isWearerTurnSignalLive: Bool {
        get { liveness.isLive }
        set { liveness.isLive = newValue }
    }

    /// - Parameters:
    ///   - freeformEnabled: the `--voice-freeform` switch, read by the provider itself.
    ///   - sessionPolicy: `.perWindow` is M1's shape and the default here for the same
    ///     reason it is the default there — it holds no timers.
    ///   - backendCapabilities: what the pipe underneath can do. `.transcriptOnly` is the
    ///     Apple shape; a cloud pipe declares `supportsNativeTurnDetection` and is the only
    ///     kind the degrade path can reach.
    ///   - idleSleep: conversation mode's idle-close timer. The default never fires within
    ///     a test run, so a `.conversation` harness that does not script one keeps its
    ///     session for the whole test rather than closing it at some wall-clock moment.
    init(diagnosticSink: RecordingSink,
         freeformEnabled: Bool = false,
         sessionPolicy: SessionPolicy = .perWindow,
         supportsBargeIn: Bool = false,
         responseAudio: (any VoiceResponseAudioPlaying)? = nil,
         backendCapabilities: VoiceBackendCapabilities = .transcriptOnly,
         idleSleep: @escaping @MainActor (TimeInterval) async -> Void = { _ in
             try? await Task.sleep(nanoseconds: 3_600_000_000_000)
         }) {
        let backend = ScriptedVoiceBackend(capabilities: backendCapabilities)
        self.backend = backend
        // Read through a box the channel owns, so a test can flip the answer between
        // windows exactly as a mid-run AirPods connect would.
        let liveness = Liveness()
        self.liveness = liveness
        provider = VoiceBackendCommandProvider(
            backend: backend,
            // R3: the grammar stays real and is passed explicitly, exactly as the host
            // passes it — this module cannot see `VoiceCommandMatcher` on its own.
            match: { VoiceCommandMatcher.match($0) },
            sessionPolicy: sessionPolicy,
            supportsBargeIn: supportsBargeIn,
            responseAudio: responseAudio,
            freeformEnabled: freeformEnabled,
            isWearerTurnSignalLive: { liveness.isLive },
            idleSleep: idleSleep,
            diagnosticSink: diagnosticSink
        )
    }

    /// The realtime shape: a duplex cloud pipe that can do its own end-of-speech detection.
    /// The only capabilities under which the degrade path can be reached at all.
    static let realtimeCapabilities = VoiceBackendCapabilities(
        supportsBargeIn: true, producesAudio: true, duplex: true,
        supportsNativeTurnDetection: true)

    // MARK: VoiceCommandProviding — straight through to the real provider.

    func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        provider.start(onCommand: onCommand)
    }

    func stop() { provider.stop() }

    func pauseListening() { provider.pauseListening() }

    // MARK: HarnessVoiceChannel

    /// The session opens on a later main-actor turn (`start` posts a `Task`), and the
    /// provider ignores events while its handler is nil. Both have to be true before a
    /// scripted transcript can reach the grammar.
    var isReadyForDelivery: Bool {
        backend.isOpen && provider.isWindowOpenForTesting
    }

    /// The degraded ordering, exactly as the realtime service produces it: the backend's own
    /// VAD commits the buffered audio, and only then does a transcript for it exist.
    ///
    /// There is no partial. Under `turn_detection: server_vad` the conversation item — and
    /// therefore input transcription — is created by the commit, so nothing about the
    /// utterance is available before it, which is the whole reason this path needs the
    /// commit to happen at all.
    func deliverAfterNativeCommit(_ transcript: String) {
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(.transcriptFinal(transcript))
    }

    /// Emits the partial, then the final — the ordering every streaming recognizer
    /// produces. A match on the partial resolves the window and tears the turn down, which
    /// leaves the final to be dropped by the provider's handler-nil guard; that is the
    /// production sequence, not a test artifact.
    func deliver(partial: String?, final: String) {
        if let partial { backend.emit(.transcriptPartial(partial)) }
        backend.emit(.transcriptFinal(final))
    }

    /// Free-form delivery is the provider's decision, not the channel's: an unmatched final
    /// transcript becomes `.freeform` only when the provider was built with it enabled, and
    /// only once per turn. So this is an ordinary delivery, and the assertion is on what
    /// came out.
    func deliverFreeform(_ transcript: String) {
        XCTAssertNil(VoiceCommandMatcher.match(transcript),
                     "'\(transcript)' matches the grammar and would never be free-form")
        deliver(partial: nil, final: transcript)
    }
}

// MARK: - Fakes

/// A `VoiceBackend` that does nothing but carry the events a test writes down.
///
/// Every method records and returns; no state machine, no VAD, no opinions about turns.
/// That is the contract's own position — turn arbitration lives on TapQ's side — so a
/// backend fake with rules of its own would be testing the wrong half.
@MainActor
final class ScriptedVoiceBackend: VoiceBackend {
    let capabilities: VoiceBackendCapabilities

    /// Set to make the next `open` throw, for the session-that-cannot-start path.
    var openFailure: VoiceBackendFailure?
    /// What `endUserTurn(expectingResponse: true)` reports back. `false` matches a
    /// transcript-only backend, which never creates a response.
    var createsResponseOnCommittedTurn = false

    private(set) var isOpen = false
    private(set) var isTurnOpen = false
    private(set) var beganTurns = 0
    private(set) var endedTurns: [Bool] = []
    private(set) var closes = 0
    private(set) var cancellations = 0
    private(set) var sentAudio: [VoiceAudioChunk] = []
    private(set) var requestedResponses: [String] = []

    private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?

    init(capabilities: VoiceBackendCapabilities = .transcriptOnly) {
        self.capabilities = capabilities
    }

    func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        if let openFailure { throw openFailure }
        self.onEvent = onEvent
        isOpen = true
    }

    func close() {
        closes += 1
        isOpen = false
        isTurnOpen = false
        onEvent = nil
    }

    func beginUserTurn() {
        beganTurns += 1
        isTurnOpen = true
    }

    @discardableResult
    func endUserTurn(expectingResponse: Bool) -> Bool {
        endedTurns.append(expectingResponse)
        isTurnOpen = false
        return expectingResponse && createsResponseOnCommittedTurn
    }

    func sendAudio(_ chunk: VoiceAudioChunk) { sentAudio.append(chunk) }

    func requestResponse(text: String) { requestedResponses.append(text) }

    func cancelResponse() { cancellations += 1 }

    /// Every turn-detection mode the provider asked for, in order — the whole record of the
    /// degrade decision as a backend experiences it.
    private(set) var nativeTurnDetection: [Bool] = []

    func setNativeTurnDetection(_ enabled: Bool) {
        nativeTurnDetection.append(enabled)
    }

    /// Pushes one event at whoever opened the session. A no-op when nobody has — which is
    /// the honest shape of a closed backend, and the reason `isReadyForDelivery` exists.
    func emit(_ event: VoiceBackendEvent) {
        onEvent?(event)
    }
}

/// Who the IMU says just spoke, for one utterance.
///
/// Three states rather than two, because the third is the one the whole attribution design
/// turns on: an unavailable signal is not a "not the wearer" answer, and the command path
/// and the instruction path are required to draw opposite conclusions from it.
enum UtteranceAttribution {
    /// The wearer is speaking. Commands pass; dictation is accepted.
    case wearer
    /// The signal is live and says this is somebody else, with the wearer's last speech
    /// well outside the trailing attribution window. Commands are dropped at the gate.
    case bystander
    /// The signal cannot answer — no motion stream, asleep, or stale. Commands fail OPEN
    /// (they reach the controller exactly as they did before attribution existed) and
    /// instructions fail CLOSED.
    case signalUnavailable
}

/// `WearerSpeechSignaling` as two settable booleans.
///
/// The IMU path already has an end-to-end test that drives a real `WearerSpeechMonitor`
/// with a synthetic jerk envelope (`WearerPathE2ETests`), and that stays the test of the
/// detector. This is for the layer above it, where the question is not "does the envelope
/// read as speech" but "does *this utterance's* verdict reach the two gates that disagree
/// about it". An envelope cannot say "this one, unattributed" without also saying a great
/// deal about thresholds.
///
/// R7: one instance per `WearerGatedVoice` — the gate asserts sole ownership of
/// `onWearerSpeakingChange`.
@MainActor
final class ScriptedWearerSignal: WearerSpeechSignaling {
    /// Fires `onWearerSpeakingChange` on transitions only, never per assignment — the
    /// contract promises the observer sees edges, and `WearerGatedVoice` stamps its
    /// trailing window from them.
    var isWearerSpeaking: Bool {
        didSet {
            guard isWearerSpeaking != oldValue else { return }
            onWearerSpeakingChange?(isWearerSpeaking)
        }
    }

    var isSignalAvailable: Bool

    var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

    init(isWearerSpeaking: Bool = false, isSignalAvailable: Bool = true) {
        self.isWearerSpeaking = isWearerSpeaking
        self.isSignalAvailable = isSignalAvailable
    }
}

/// Captures the cues `QuietSpeech` plays instead of speaking.
///
/// The cue player itself is `AudioCue`, which lives in the Apple adapter layer this target
/// cannot see (R8) — and does not need to: `QuietSpeech` takes the player as a closure for
/// exactly this reason, so the decision under test (speak, chime, or suppress) is fully
/// observable from a portable target.
@MainActor
final class CueRecorder {
    private(set) var cues: [NotificationCue] = []

    func record(_ cue: NotificationCue) { cues.append(cue) }

    var played: Bool { !cues.isEmpty }
}

/// The monotonic clock the scripted attribution gate reads. Moves only when a verdict says
/// it should, so "outside the trailing attribution window" is a fact rather than a race.
@MainActor
final class ScriptedMonotonicClock {
    /// Well clear of zero so `now - attributionWindow` stays positive and readable.
    var now: TimeInterval = 1_000
}
