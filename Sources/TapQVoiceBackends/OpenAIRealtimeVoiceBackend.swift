import Foundation
import TapQContracts

/// A `VoiceBackend` over the OpenAI Realtime API in **manual-turn mode**.
///
/// The entire adapter exists to make a duplex, VAD-happy cloud service behave like the
/// dumb speech pipe `VoiceBackend` describes:
///
/// - The first frame on every connection is a `session.update` carrying
///   `audio.input.turn_detection: null`, and the handshake is not considered complete until the
///   service acknowledges it with `session.updated`. Until that ack lands, the service
///   would be running its own voice-activity detection on settings TapQ never chose, and a
///   server-side commit would resolve an approval window TapQ never authorized.
/// - Audio only ever leaves during an open user turn, the buffer is committed only from
///   `endUserTurn()`, and a response is only ever created by TapQ — on commit, or on an
///   explicit `requestResponse(text:)`.
/// - `setNativeTurnDetection(true)` is the one documented exception, and it is a second
///   `session.update` on an already-established session, never a shortcut through the
///   handshake above. It moves `turn_detection` to `semantic_vad` with `create_response:
///   false` and `interrupt_response: false`, so the service may say where a sentence ended
///   and may not do anything else. The empty-turn guard, the "a response happens only when
///   TapQ asks" rule, and the half-duplex policy are all untouched by it. See the carve-out
///   on `VoiceBackend` for why TapQ ever asks.
/// - A native turn the adapter can prove was TapQ's own voice is dropped rather than
///   reported. With no AirPods the answer TapQ just spoke comes back through the open
///   microphone, the service's VAD calls it speech because it is speech, and the commit that
///   follows would have TapQ answering its own last sentence. `selfAudioActivity` is the one
///   thing that can tell the two apart; everything ambiguous is treated as the wearer. See
///   `committedSegmentWasSelfAudio()`.
/// - A cancel is bookkeeping, not an ending: the peer answers `response.cancel` with the
///   rest of the frames it had already produced and then that response's own
///   `response.done`, so the id is tombstoned rather than forgotten and its tail is drained
///   against the tombstone. Only a `response.done` for a response that is neither in flight
///   nor tombstoned is the contract violation it has always been. The same bookkeeping runs
///   in the other direction: TapQ cancelling something it has already cancelled is a
///   recorded no-op, because the caller learns a response ended from the audio it stops
///   receiving, and two paths can reach for the same ending.
/// - `capabilities` reports what the *transport* can do (barge-in, audio, duplex). TapQ
///   still runs half-duplex; that policy is enforced by `VoiceTurnStateMachine`, which
///   every inbound call and every server event routes through, so a protocol mistake
///   surfaces as `sessionFailed(.protocolViolation)` rather than as scrambled turns.
///
/// Nothing here can hang: the handshake is bounded by `timeout`, outbound frames drain
/// through one ordered pump whose failures end the session, and a dropped connection
/// arrives as `sessionFailed`. The API key lives in the transport's headers and appears in
/// no diagnostic, no failure description, and no frame this file builds.
@MainActor public final class OpenAIRealtimeVoiceBackend: VoiceBackend {
    // `nonisolated` because these are default arguments on this class's own initializers,
    // which are evaluated in the caller's isolation domain.
    public nonisolated static let defaultModel = RealtimeDefaults.model
    public nonisolated static let defaultEndpoint = RealtimeDefaults.endpoint
    public nonisolated static let defaultTimeout: TimeInterval = 5
    /// Audio is framed into blocks no longer than this before it is base64-encoded and
    /// sent. A caller handing over a second of audio would otherwise base64 a second of
    /// audio in one main-actor turn.
    public nonisolated static let maxChunkSeconds: TimeInterval = 0.1

    /// The wire format both directions of this session use.
    public nonisolated static let audioFormat = VoiceAudioFormat.pcm16Mono24k

    /// How many cancelled responses the adapter remembers the ids of at once.
    ///
    /// A response that is cancelled and whose `response.done` never arrives would otherwise
    /// leave its id behind forever, so the record is a small ring rather than a growing set.
    /// TapQ runs half-duplex — one response in flight, one cancel outstanding — so the depth
    /// only has to cover a tail still in transit; the oldest id is dropped with a diagnostic
    /// when a run somehow gets ahead of that.
    nonisolated static let maxCancelledResponses = 4

    public let capabilities = VoiceBackendCapabilities(supportsBargeIn: true,
                                                       producesAudio: true,
                                                       duplex: true,
                                                       supportsNativeTurnDetection: true,
                                                       supportsToolCalling: true)

    /// The id the peer gave the response it is producing now, published for callers that
    /// need to say *which* response they mean. Backed by the same `activeResponseID` the
    /// tombstone bookkeeping uses, so a caller and this adapter can never disagree about
    /// which response is live.
    public var activeResponseIdentity: String? { activeResponseID }

    private let transport: any RealtimeTransporting
    /// The session TapQ is asking for, as it stands right now.
    ///
    /// `var` rather than `let` because two things a caller may change mid-run live in here —
    /// the declared tool set and the standing instructions — and both must survive a
    /// reconnect. A session that came back up without its tools would be a microphone the
    /// wearer could talk into that could no longer do anything about it.
    private var configuration: RealtimeSessionConfiguration
    private let timeout: TimeInterval
    private let monotonicNow: @Sendable () -> TimeInterval
    private let diagnostics: TapQDiagnosticEmitter

    private var turns: VoiceTurnStateMachine
    private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    /// Invalidates late transport frames, drain loops, and timeout tasks belonging to a
    /// session that has already been torn down. Bumped on every open and every teardown.
    private var sessionGeneration: UInt64 = 0

    private var handshakeContinuation: CheckedContinuation<Void, any Error>?
    private var handshakeGeneration: UInt64?
    /// Set when the handshake settles before anyone is waiting on it — the ack can land in
    /// the same main-actor turn the frame was sent in.
    private var handshakeOutcome: (generation: UInt64, result: Result<Void, VoiceBackendFailure>)?

    /// Ordered outbound queue. `sendAudio` is synchronous by contract and the transport's
    /// send is not, so frames queue here and one pump drains them; two concurrent tasks
    /// would interleave appends into scrambled audio.
    private var outbound: [String] = []
    private var pumpRunning = false

    /// Set by `cancelResponse()` when the peer had not yet named the response being
    /// cancelled — the cancel raced `response.created`, or the peer names nothing at all.
    /// There is no id to tombstone, so the next terminal frame for *some* response is taken
    /// as this cancel's ack rather than as an unrequested completion (which would throw
    /// `.noResponseInFlight` from `.open` and kill the session). A cancel racing a
    /// just-completed response produces an `error` event instead; that is also absorbed
    /// while this is set.
    ///
    /// Cleared when that frame arrives, when the id finally lands (the cancel is promoted to
    /// a proper tombstone), and by teardown — deliberately *not* by `beginUserTurn`, for the
    /// reason `cancelledResponseIDs` gives: the window that opens between a cancel and its
    /// tail is the normal case, not an anomaly.
    private var expectCancelAck = false

    /// The id the peer gave the response it is producing now, learned from
    /// `response.created`. `nil` between responses, and for a peer that names none.
    private var activeResponseID: String?

    /// Responses TapQ cancelled whose terminal `response.done` has not landed yet.
    ///
    /// A cancel does not stop the peer mid-sentence. It finishes the frames it had already
    /// produced — `response.output_audio.done`, `response.output_audio_transcript.done`,
    /// `conversation.item.done`, `response.output_item.done` — and then sends that
    /// response's own `response.done`, all of it *after* the cancel. Forgetting the response
    /// at the cancel makes that done a completion TapQ never requested, which is the strict
    /// protocol check below, which ends the session and degrades the run. So the id is kept
    /// here instead and the done it names is drained silently.
    ///
    /// Not cleared on a turn boundary: under `--voice-session` every turn end cancels the
    /// finish notice and opens a listening window in the same breath, so a tombstone that
    /// did not survive `beginUserTurn` would be a tombstone that never survived anything.
    /// Bounded by `maxCancelledResponses` and cleared with the session instead.
    private var cancelledResponseIDs: [String] = []

    /// Cumulative transcript for the current turn — the whole utterance so far, which is
    /// the shape `VoiceCommandMatcher` expects. The service sends deltas.
    private var transcript = ""

    /// Bytes of audio appended since the last commit. An `endUserTurn` with zero appended
    /// audio sends neither `commit` nor `response.create` — the OpenAI service rejects an
    /// empty commit, and a silent teardown turn must not create spurious responses. Reset
    /// on `beginUserTurn` and on every commit, including the service's own: what it counts
    /// is what is sitting in the input buffer right now.
    private var turnAudioByteCount = 0

    /// The mode TapQ has asked for, which outlives any one session: a caller sets it once
    /// per window and a reconnect must come back up in it rather than silently reverting to
    /// manual. Applied to a session only through `applyTurnDetection`.
    private var nativeTurnDetectionRequested = false
    /// The mode this session is actually in. Separate from the request so `applyTurnDetection`
    /// can be called freely — from `open`, from a caller, from a caller before `open` — and
    /// send a frame only when something really changed.
    private var nativeTurnDetectionApplied = false
    /// The exact configuration this session hands the service when native detection is on.
    ///
    /// Held rather than reached for, because the eagerness inside it comes from the
    /// environment and must be resolved once per run — a value re-read per window could
    /// change under a wearer mid-session, and the whole point of `sendSessionUpdate`
    /// restating turn detection is that the frame says what TapQ believes.
    private let nativeTurnDetection: RealtimeTurnDetection
    /// What TapQ's own voice is doing in the room, or `nil` where nothing renders it.
    ///
    /// The one seam that lets this adapter tell a wearer from an echo. On the voice-only
    /// path — no AirPods, no IMU turn signal — every sentence TapQ says leaves the Mac's
    /// speaker and arrives back at the open microphone, and the service's VAD reports it as
    /// speech because it *is* speech. Nothing in a frame distinguishes it. Composition wires
    /// this to the audio player that is producing the sound; a composition that wires nothing
    /// — every test that does not ask for it, and the Apple path, which has no realtime
    /// session at all — suppresses nothing and behaves exactly as it did before 2026-08-30.
    ///
    /// A closure rather than a reference because this target is portable and the renderer is
    /// `AVAudioEngine`-shaped, and because the answer is a fact about *now* rather than a
    /// dependency: it is sampled at the instant an event arrives and never held.
    public var selfAudioActivity: (@MainActor () -> VoiceSelfAudioActivity)?

    /// How long after TapQ's audio stops the microphone is still assumed to be hearing it.
    /// Resolved once per adapter, from the environment, for the reason `turnEagerness` is:
    /// a value re-read per window could change under a wearer mid-session.
    private let selfAudioHysteresis: TimeInterval

    /// When the service's VAD last said speech began, and whether TapQ's own voice was in
    /// the room at that instant and again when it said the speech ended.
    ///
    /// Sampled at the moment each event arrives rather than reconstructed at the commit,
    /// because only the *most recent* stretch of self-audio is knowable from one sample: a
    /// segment that began during one sentence and ended during the next would be judged
    /// against the wrong span if the question were asked late.
    private var nativeSpeechStartedAt: TimeInterval?
    private var nativeSpeechStoppedAt: TimeInterval?
    private var nativeSpeechBeganInSelfAudio = false
    private var nativeSpeechEndedInSelfAudio: Bool?

    /// How many native turns this session has dropped as TapQ's own voice. A count only —
    /// what was said is the wearer's and the log is not the place for it.
    private var selfAudioSuppressions = 0

    /// `conversation.item.delete` frames whose outcome has not landed yet. The service
    /// answers a delete with `conversation.item.deleted`, which decodes to `.unsupported`
    /// and is ignored; a delete it refuses arrives as an `error`, and that error must not
    /// take a wearer's only channel down over a piece of bookkeeping about audio nobody
    /// wanted. Bounded by the round trip: one is added per delete and one is spent per
    /// absorbed error.
    private var pendingItemDeletes = 0

    /// Commits this adapter issued that the service has not yet echoed back as
    /// `input_audio_buffer.committed`.
    ///
    /// The service sends that event for TapQ's own commits *and* for the ones its VAD makes,
    /// with nothing in the payload that distinguishes them. Counting is the distinction:
    /// an echo that matches an outstanding commit is an ack, and one that does not is the
    /// service ending an utterance on its own — legal only in native mode, fatal otherwise.
    private var pendingOwnCommits = 0

    /// - Parameters:
    ///   - transport: the frame pipe. Injected so tests drive a scripted server and never a
    ///     socket, and so Linux never links a `URLSessionWebSocketTask`.
    ///   - monotonicNow: clock for stamping inbound audio chunks, injectable for tests.
    ///   - turnEagerness: how readily the model ends a turn once TapQ has handed it
    ///     end-of-speech detection. Read from the environment once, here, so the whole run
    ///     shares one setting; injectable so a test can state it rather than export it.
    ///   - selfAudioHysteresis: how long after TapQ's own audio drains the microphone is
    ///     still assumed to be hearing it. Same environment-once rule, same reason.
    public init(transport: any RealtimeTransporting,
                configuration: RealtimeSessionConfiguration = RealtimeSessionConfiguration(
                    // instructions(grounding: nil), not baseInstructions: tools are declared
                    // on this same first frame, so the policy governing them must be too.
                    instructions: RealtimeDefaults.instructions(grounding: nil)
                ),
                timeout: TimeInterval = OpenAIRealtimeVoiceBackend.defaultTimeout,
                turnEagerness: RealtimeTurnEagerness = RealtimeDefaults.resolvedTurnEagerness(),
                selfAudioHysteresis: TimeInterval = VoiceSelfAudioEcho.resolvedHysteresis(),
                monotonicNow: @escaping @Sendable () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.transport = transport
        // The one setting the adapter refuses to take on faith: whatever a caller passes,
        // this session runs without server-side turn detection.
        var manualTurns = configuration
        manualTurns.turnDetection = nil
        self.configuration = manualTurns
        self.nativeTurnDetection = .semanticVAD(eagerness: turnEagerness)
        self.selfAudioHysteresis = selfAudioHysteresis
        self.timeout = timeout
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "OpenAIRealtime", sink: diagnosticSink)
        self.turns = VoiceTurnStateMachine(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
        // Recorded at composition, not at the window that first needs it: an operator
        // reading a cut-off complaint out of a log needs to know what this run was tuned to
        // even when the run never left manual turns.
        diagnostics.record("turn_detection.configured", fields: [
            "type": nativeTurnDetection.type,
            "eagerness": turnEagerness.rawValue,
            // The echo knob rides the same line for the same reason: an operator reading a
            // "it answered itself" or "it ignored me" report needs both numbers this run
            // was tuned to, and neither has a flag to grep the command line for.
            "self_audio_hysteresis_ms": "\(Int((selfAudioHysteresis * 1_000).rounded()))",
        ])
    }

    #if canImport(Darwin)
    /// Composition-time convenience: the live WebSocket transport, built from an API key.
    ///
    /// Apple-only for the same reason `URLSessionWebSocketRealtimeTransport` is.
    public convenience init(apiKey: String,
                            model: String = OpenAIRealtimeVoiceBackend.defaultModel,
                            endpoint: URL = OpenAIRealtimeVoiceBackend.defaultEndpoint,
                            timeout: TimeInterval = OpenAIRealtimeVoiceBackend.defaultTimeout,
                            diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        let url = components?.url ?? endpoint
        self.init(transport: URLSessionWebSocketRealtimeTransport(url: url, apiKey: apiKey),
                  // Set here as well as in the designated initializer's default: this path
                  // passes a configuration of its own, so a session opened from an API key
                  // would otherwise be the one session that ran with no standing rules.
                  configuration: RealtimeSessionConfiguration(
                      model: model,
                      instructions: RealtimeDefaults.instructions(grounding: nil),
                      // The live path, and the only one that reads the environment. Both
                      // ride the opening frame and neither moves again: the service will
                      // not change a voice once a session has produced audio, and a speed
                      // that drifted mid-run would be one more thing for a wearer to
                      // account for. Passed explicitly rather than left to the audio
                      // configuration's defaults, which are the constants and know nothing
                      // about this run's environment.
                      voice: RealtimeDefaults.resolvedVoice(),
                      speed: RealtimeDefaults.resolvedSpeed()
                  ),
                  timeout: timeout,
                  diagnosticSink: diagnosticSink)
    }
    #endif

    var turnStateForTesting: VoiceTurnStateMachine.State { turns.state }
    var cancelledResponseIDsForTesting: [String] { cancelledResponseIDs }

    // MARK: - Session lifecycle

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        do {
            try turns.open()
        } catch {
            throw VoiceBackendFailure.protocolViolation(Self.describe(error))
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.onEvent = onEvent
        transcript = ""
        // A new session starts in manual-turn mode no matter what the last one was doing.
        // `nativeTurnDetectionRequested` survives, and is re-applied once the handshake
        // lands — a reconnect must come back up in the mode the caller asked for.
        nativeTurnDetectionApplied = false
        pendingOwnCommits = 0
        pendingItemDeletes = 0
        selfAudioSuppressions = 0
        clearNativeSpeechEvidence()
        activeResponseID = nil
        cancelledResponseIDs.removeAll()

        do {
            try await transport.connect()
        } catch {
            guard sessionGeneration == generation else {
                throw VoiceBackendFailure.closed("the session was torn down while connecting")
            }
            let failure = Self.failure(from: error)
            diagnostics.record("connect.failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            turns.sessionFailed()
            teardown(expectedGeneration: generation)
            throw failure
        }
        guard sessionGeneration == generation else {
            // `close()` landed while the connection was still being established. Nobody
            // else owns this transport, so it is ours to shut.
            transport.close()
            throw VoiceBackendFailure.closed("the session was torn down while connecting")
        }

        startReceiveLoop(generation: generation)
        handshakeGeneration = generation
        // Manual-turn mode before anything else, including before any audio can exist.
        enqueue(.sessionUpdate(configuration), generation: generation)
        try await awaitHandshake(generation: generation)
        // Only now, on an established session whose settings the service has acknowledged,
        // is the degraded mode allowed to be asked for. Folding `semantic_vad` into the
        // handshake frame would save one round trip and give away the property the handshake
        // exists for: that there is no instant in a session's life where the service is
        // running turn detection TapQ did not deliberately turn on.
        applyTurnDetection(generation: generation)
        // The voice and the rate ride this line because a wearer's report is always "it
        // sounded different", never "audio.output.voice was cedar": an operator reading one
        // has to be able to see what this run actually asked for, and neither setting has a
        // CLI flag to grep the command line for. "service default" where the configuration
        // states nothing, which is what every session did before 2026-09-01.
        diagnostics.record("session.opened", fields: [
            "model": configuration.model,
            "voice": configuration.audio.output.voice ?? "service default",
            "speed": configuration.audio.output.speed.map { "\($0)" } ?? "service default",
        ])
    }

    public func close() {
        let wasOpen = turns.isOpen || onEvent != nil
        teardown()
        if wasOpen { diagnostics.record("session.closed") }
    }

    // MARK: - Turns

    public func beginUserTurn() {
        do {
            try turns.beginUserTurn()
        } catch {
            return violated(error)
        }
        transcript = ""
        turnAudioByteCount = 0
        // A new turn hears nothing of the last one's segment: whatever the service said
        // about speech before this microphone opened is evidence about audio that is
        // already committed or already discarded.
        clearNativeSpeechEvidence()
        // Neither `expectCancelAck` nor `cancelledResponseIDs` is cleared here. A cancelled
        // response's tail arrives *after* the window that cancelled it has opened — that is
        // the whole shape of the race — so a turn boundary is precisely the wrong place to
        // forget one. They end with the session.
        diagnostics.record("turn.began")
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        do {
            try turns.sendAudio()
        } catch {
            return violated(error)
        }
        guard chunk.format == Self.audioFormat else {
            // A caller feeding the wrong encoding produces audio the service will happily
            // transcribe as noise. Loud beats a session that silently mishears everything.
            return violated(VoiceBackendFailure.protocolViolation(
                "the session speaks \(Int(Self.audioFormat.sampleRate)) Hz PCM16 mono; "
                    + "a chunk arrived as \(Int(chunk.format.sampleRate)) Hz "
                    + "\(chunk.format.channels)-channel"))
        }
        guard !chunk.data.isEmpty else { return }
        turnAudioByteCount += chunk.data.count
        let generation = sessionGeneration
        for block in Self.split(chunk, maxSeconds: Self.maxChunkSeconds) {
            enqueue(.appendInputAudio(block), generation: generation)
        }
    }

    @discardableResult
    public func endUserTurn(expectingResponse: Bool) -> Bool {
        do {
            try turns.endUserTurn()
        } catch {
            violated(error)
            return false
        }
        // Empty-turn guard: if no audio was appended during this turn, skip the commit
        // and response.create entirely. The OpenAI service rejects an empty commit, and a
        // silent teardown turn must not create spurious responses.
        guard turnAudioByteCount > 0 else {
            diagnostics.record("turn.empty_skipped")
            return false
        }
        let generation = sessionGeneration
        // In native mode the service owns commits, and whatever is in the buffer at window
        // teardown is the tail end of an utterance its VAD has not called finished. TapQ
        // must not commit it: the fragment is usually shorter than the 100 ms the service
        // accepts, and a rejected commit arrives as an `error` frame that ends the session.
        // Dropping it is the right answer anyway — nobody is listening for it any more, and
        // the buffer outlives this window.
        guard !nativeTurnDetectionApplied else {
            turnAudioByteCount = 0
            enqueue(.clearInputAudio, generation: generation)
            diagnostics.record("turn.ended_native")
            return false
        }
        pendingOwnCommits += 1
        enqueue(.commitInputAudio, generation: generation)
        // When TapQ does not want a spoken reply (match-resolved, gesture stop,
        // activity pause), commit for transcription only — no response.create.
        // Input transcription rides the commit, not the response, so match-by-transcript
        // still works on the committed audio.
        guard expectingResponse else {
            diagnostics.record("turn.committed_no_response")
            return false
        }
        // Manual-turn mode is commit-then-create: the service produces nothing until asked,
        // so the commit that ends the wearer's turn is immediately followed by the request
        // that starts the model's.
        do {
            try turns.requestResponse()
        } catch {
            violated(error)
            return false
        }
        enqueue(.createResponse(instructions: nil), generation: generation)
        diagnostics.record("turn.committed")
        return true
    }

    public func requestResponse(text: String) {
        do {
            try turns.requestResponse()
        } catch {
            return violated(error)
        }
        diagnostics.record("response.requested", fields: ["length": "\(text.count)"])
        enqueue(.createResponse(instructions: text), generation: sessionGeneration)
    }

    /// One sentence TapQ wrote, read back out of band.
    ///
    /// Everything about the response *lifecycle* is identical to `requestResponse`: the
    /// same state machine call, so the half-duplex rule and the "only TapQ starts a
    /// response" rule are the same rules; the same `response.created` naming, so the same
    /// `activeResponseID`; the same cancellability, so barge-in and the match-resolved
    /// suppression tombstone it exactly as they tombstone any other response. An
    /// out-of-band response is a response — only its input and its effect on the
    /// conversation differ.
    ///
    /// The wire difference is `RealtimeClientEvent.createScriptedResponse`, which documents
    /// why `conversation: "none"` and `input: []` are both load-bearing.
    public func requestScriptedSpeech(text: String) {
        do {
            try turns.requestResponse()
        } catch {
            return violated(error)
        }
        diagnostics.record("scripted_speech.requested", fields: ["length": "\(text.count)"])
        enqueue(.createScriptedResponse(text: text), generation: sessionGeneration)
    }

    /// Abandons the response the peer is producing, and does nothing at all when it is not
    /// producing one.
    ///
    /// Cancelling is idempotent from TapQ's side, and that is the mirror of the tombstone
    /// above rather than a second rule. The tombstone absorbs the *peer's* late
    /// `response.done` for a response TapQ already cancelled; this absorbs *TapQ's own*
    /// second cancel of it. Both arise from one shape: a response is retired down one path
    /// — the match-resolved suppression, the coordinator's barge-in — while another path
    /// still believes it is speaking, because the straggler audio a cancel does not stop
    /// re-arms the caller's response-in-flight tracking. Observed live 2026-08-27 under
    /// `--voice-session`: suppression cancelled a dictation read-back, the next listening
    /// window cancelled it again, and `noResponseInFlight` took hands-free voice down for
    /// the run under the no-degradation policy.
    ///
    /// Narrow on purpose. Only `noResponseInFlight` — TapQ asking twice for an ending it
    /// already has — is absorbed. `bargeInUnsupported` (a composition wired against a
    /// backend that cannot abandon a response) and `notOpen` (a cancel into a session that
    /// no longer exists) still end the session, and nothing about what the *peer* sends is
    /// relaxed: a `response.done` for a response that is neither in flight nor tombstoned
    /// is the contract violation it has always been.
    public func cancelResponse() {
        do {
            try turns.cancelResponse()
        } catch VoiceTurnViolation.noResponseInFlight {
            // Nothing is speaking, so there is nothing to stop. No frame goes out: a
            // `response.cancel` the peer has nothing to answer comes back as an `error`,
            // and an error absorbed by `expectCancelAck` bookkeeping that no real cancel
            // owns is a worse lie than the one silence tells.
            diagnostics.record("response.cancel_skipped_idle",
                               fields: ["state": turns.state.rawValue])
            return
        } catch {
            return violated(error)
        }
        // The response is not over on the wire: the peer still owes every frame it had
        // already produced, plus that response's own `response.done`. Remembering which
        // response this was is what keeps the done from reading as a completion nobody asked
        // for. With no id yet, the ack is the next terminal frame instead.
        let cancelled = activeResponseID
        if let cancelled {
            tombstone(cancelled)
            activeResponseID = nil
        } else {
            expectCancelAck = true
        }
        diagnostics.record("response.cancelled", fields: ["response_id": cancelled ?? "unnamed"])
        enqueue(.cancelResponse, generation: sessionGeneration)
    }

    /// Remembers a cancelled response so its terminal frames can be drained instead of
    /// ending the session, dropping the oldest id when the ring is full.
    private func tombstone(_ id: String) {
        guard !cancelledResponseIDs.contains(id) else { return }
        cancelledResponseIDs.append(id)
        while cancelledResponseIDs.count > Self.maxCancelledResponses {
            let dropped = cancelledResponseIDs.removeFirst()
            diagnostics.record("response.cancelled_tombstone_dropped",
                               fields: ["response_id": dropped])
        }
    }

    // MARK: - Turn detection mode

    public func setNativeTurnDetection(_ enabled: Bool) {
        nativeTurnDetectionRequested = enabled
        // Before a session exists, or while its handshake is still in flight, the request is
        // recorded and nothing is sent: `open` applies it the moment the service has
        // acknowledged the manual-turn configuration, which is the only ordering that keeps
        // the "no unauthorized VAD, ever" property of the handshake intact.
        guard turns.isOpen, handshakeGeneration == nil else { return }
        applyTurnDetection(generation: sessionGeneration)
    }

    /// Brings the live session into the requested mode, or does nothing if it is already
    /// there. Idempotent by construction, so every caller can call it unconditionally.
    private func applyTurnDetection(generation: UInt64) {
        guard sessionGeneration == generation else { return }
        guard nativeTurnDetectionApplied != nativeTurnDetectionRequested else { return }
        nativeTurnDetectionApplied = nativeTurnDetectionRequested
        // The state machine learns the mode before the frame goes out, not after: the
        // service can answer a `session.update` with a VAD commit in the same breath, and a
        // machine that still thought the session was manual would call that a violation and
        // kill the session TapQ had just degraded on purpose.
        turns.setNativeTurnDetection(nativeTurnDetectionApplied)
        sendSessionUpdate(generation: generation)
        diagnostics.record("turn_detection.updated", fields: [
            "mode": nativeTurnDetectionApplied ? nativeTurnDetection.type : "null",
            "eagerness": nativeTurnDetectionApplied
                ? (nativeTurnDetection.eagerness?.rawValue ?? "unset") : "n/a",
        ])
    }

    /// Restates the whole session object, with turn detection pinned to the mode this
    /// session is actually in.
    ///
    /// The pin is why every live change goes through one function. GA's `session.update` is
    /// a merge, so a partial update that omitted `turn_detection` would leave whatever the
    /// session already had — which is right for every field except this one, where "whatever
    /// it already had" is a mode TapQ may have moved out of. Restating everything makes the
    /// frame say what TapQ believes rather than what it is changing.
    /// Every restatement goes through this one property, so the mode the session opened in,
    /// the mode a live flip moves it to, and the mode a tool declaration or an instruction
    /// change happens to restate are all the same object by construction — there is no
    /// second spelling of `semantic_vad` for one of them to drift from.
    private func sendSessionUpdate(generation: UInt64) {
        var update = configuration
        update.turnDetection = nativeTurnDetectionApplied ? nativeTurnDetection : nil
        enqueue(.sessionUpdate(update), generation: generation)
    }

    /// Whether a `session.update` sent right now would land on an established session.
    ///
    /// Before `open`, and while the handshake is still outstanding, a change is recorded in
    /// `configuration` and nothing is sent — `open` carries it in the very first frame,
    /// which is both cheaper and the only ordering that keeps the handshake's promise that
    /// the service is never running settings TapQ did not choose.
    private var isSessionLive: Bool { turns.isOpen && handshakeGeneration == nil }

    // MARK: - Tools

    public func declareTools(_ tools: [VoiceToolDeclaration]) {
        let rendered = tools.map(RealtimeTool.init)
        guard configuration.tools != rendered else { return }
        configuration.tools = rendered
        // `auto` and nothing else. `required` would make the model call *something* for every
        // turn the wearer takes, which is the guessing this whole path exists to remove; and
        // pinning one tool would be TapQ deciding the wearer's meaning after all.
        configuration.toolChoice = rendered.isEmpty ? nil : "auto"
        diagnostics.record("tool.declared", fields: [
            "count": "\(rendered.count)",
            "names": rendered.map(\.name).joined(separator: ","),
        ])
        guard isSessionLive else { return }
        sendSessionUpdate(generation: sessionGeneration)
    }

    /// Restates the session's instructions as the standing rules *plus* this turn's window
    /// context, never as the context alone.
    ///
    /// The assembly happens here because this is the only layer that can do it: the caller
    /// is `VoiceBackendCommandProvider`, which is portable and cannot see `RealtimeDefaults`,
    /// so what it passes is the window brief and nothing else. Before 2026-08-28 that brief
    /// was written straight into `configuration.instructions`, and since GA restates the
    /// whole field, the first grounded turn of every session *overwrote the standing rules
    /// with the window context* — the exact ordering failure
    /// `RealtimeDefaults.instructions(grounding:)` was written to make impossible, by a
    /// function nothing was calling. A session running on window context alone has no rule
    /// against guessing a tool from a word, no rule against narrating its own results, and
    /// no rule requiring a directed request to be answered out loud.
    ///
    /// Found by the audible-refusal sweep, and it is what made that decision's prompt work
    /// reachable at all: strengthening a policy the live session never received would have
    /// changed nothing.
    public func updateInstructions(_ instructions: String) {
        let assembled = RealtimeDefaults.instructions(grounding: instructions)
        guard configuration.instructions != assembled else { return }
        configuration.instructions = assembled
        // Length only. These carry what the wearer is being asked to authorize, and a
        // diagnostic that quoted them would put a request's own words in the log file that
        // the speech-safe surface exists to keep them out of.
        diagnostics.record("session.instructions_updated",
                           fields: ["length": "\(instructions.count)"])
        guard isSessionLive else { return }
        sendSessionUpdate(generation: sessionGeneration)
    }

    /// Asks the model to act on a segment the service's own VAD already committed.
    ///
    /// No commit frame goes with it, and that is the whole difference from `endUserTurn`: in
    /// native mode the buffer is already gone — the service took it — and a second commit
    /// over an empty buffer is an `error` frame that ends the session.
    ///
    /// `instructions: nil`, deliberately. The session's standing instructions are the tool
    /// policy plus this turn's grounding, and a per-response instruction would replace them
    /// for exactly the response that most needs them.
    @discardableResult
    public func requestModelTurn() -> Bool {
        do {
            try turns.requestResponse()
        } catch {
            violated(error)
            return false
        }
        enqueue(.createResponse(instructions: nil), generation: sessionGeneration)
        diagnostics.record("tool.model_turn_requested")
        return true
    }

    /// Closes one tool call, and starts nothing.
    ///
    /// No `response.create` follows, deliberately, and the reason is the same one that made
    /// `requestScriptedSpeech` a separate channel: what the wearer hears about a tool is a
    /// sentence TapQ wrote, spoken verbatim, and a model narrating its own tool results would
    /// paraphrase refusals and double-announce everything else. The item alone is what the
    /// model is waiting on.
    ///
    /// Legal from any state, including `.responding` — which is the normal one. The call
    /// arrived inside a response that has not finished yet (`response.output_item.done`
    /// precedes `response.done`), so the answer is nearly always sent while the peer is still
    /// speaking. `conversation.item.create` is not a response and the half-duplex rule has
    /// nothing to say about it.
    public func sendToolResult(callID: String, output: String) {
        guard turns.isOpen else {
            // The session died between the call and the answer. Nothing is waiting on the
            // other end any more, and reaching for a dead transport would be the one way this
            // path could turn a closed session into a reported failure.
            diagnostics.record("tool.result_skipped", fields: ["reason": "session_closed"])
            return
        }
        enqueue(.sendToolOutput(callID: callID, output: output),
                generation: sessionGeneration)
        diagnostics.record("tool.result_sent", fields: [
            "call_id": callID, "length": "\(output.count)",
        ])
    }

    // MARK: - Inbound

    private func startReceiveLoop(generation: UInt64) {
        let frames = transport.receiveFrames()
        Task { @MainActor [weak self] in
            do {
                for try await frame in frames {
                    guard let self, self.sessionGeneration == generation else { return }
                    self.handle(frame: frame, generation: generation)
                }
            } catch {
                guard let self, self.sessionGeneration == generation else { return }
                return self.failSession(Self.failure(from: error), generation: generation)
            }
            guard let self, self.sessionGeneration == generation else { return }
            self.failSession(.closed("the realtime peer closed the connection"),
                             generation: generation)
        }
    }

    private func handle(frame: String, generation: UInt64) {
        let event: RealtimeServerEvent
        do {
            event = try RealtimeServerEvent.decode(frame)
        } catch {
            return failSession(.protocolViolation(Self.describe(error)), generation: generation)
        }

        switch event {
        case .sessionCreated:
            // Not the ack: the service has a session, but it is still the service's own
            // VAD running it until `session.updated` confirms otherwise.
            diagnostics.record("session.created")
        case .sessionUpdated:
            settleHandshake(.success(()), generation: generation)
        case .speechStarted:
            // Still not acted on: this does not open a window, attribute a speaker, or arm
            // barge-in. What it now does is *witness* — the instant it names is the one
            // moment TapQ can ask whether its own voice was in the room, and asking later
            // would be asking about a playback that has already drained.
            noteNativeSpeechStarted()
        case .speechStopped:
            noteNativeSpeechStopped()
        case .inputAudioCommitted(let itemID):
            handleInputAudioCommitted(itemID: itemID, generation: generation)
        case .transcriptDelta(let delta):
            guard !delta.isEmpty else { return }
            transcript += delta
            emit(.transcriptPartial(transcript))
        case .transcriptCompleted(let settled):
            if !settled.isEmpty { transcript = settled }
            emit(.transcriptFinal(transcript))
        case .spokenTranscript(let settled):
            // The other direction, and it accumulates nothing: `transcript` above is the
            // wearer's turn being assembled from deltas, and mixing TapQ's own words into it
            // would put them in front of a matcher. This frame is already settled, so it is
            // passed on whole and forgotten.
            //
            // An empty one is dropped rather than emitted: the contract says the event is
            // never empty, and a host recording "" would file a sentence nobody said.
            guard !settled.isEmpty else {
                diagnostics.record("spoken_transcript.empty")
                return
            }
            emit(.spokenByBackend(settled))
        case .audioDelta(let audio):
            emit(.audio(VoiceAudioChunk(data: audio, format: Self.audioFormat,
                                        timestamp: monotonicNow())))
        case .responseCreated(let id):
            handleResponseCreated(id: id)
        case .responseCompleted(let id):
            handleResponseCompleted(id: id, generation: generation)
        case .functionCall(let callID, let name, let arguments):
            handleFunctionCall(callID: callID, name: name, argumentsJSON: arguments)
        case .failure(let failure):
            if hasOutstandingCancel, !failure.isAuthorization {
                // A cancel racing a just-completed response: the server returns an error
                // because there is nothing to cancel. This is expected and benign — the
                // response finished normally, and the cancel was simply too late.
                //
                // An outstanding *tombstone* absorbs it too, and keeps its id: the error
                // names no response, so it cannot be matched to one, and the done the peer
                // already owes is still the only thing that retires a tombstone.
                expectCancelAck = false
                diagnostics.record("cancel_ack.race_error",
                                   fields: ["message": failure.message])
                return
            }
            if pendingItemDeletes > 0, !failure.isAuthorization {
                // A delete the service would not carry out — the item was already gone, or
                // it will not remove that kind. The mirror of the cancel race above and
                // absorbed for the same reason, one narrow window wide: the frame was
                // housekeeping about audio TapQ never wanted, and ending a wearer's only
                // channel over it would be a worse outcome than the echo it was tidying up.
                pendingItemDeletes -= 1
                diagnostics.record("item_delete.refused", level: .warning,
                                   fields: ["message": failure.message])
                return
            }
            let mapped: VoiceBackendFailure = failure.isAuthorization
                ? .authorization(failure.message)
                : .protocolViolation(failure.message)
            failSession(mapped, generation: generation)
        case .unsupported(let type):
            diagnostics.record("event.ignored", fields: ["type": type])
        }
    }

    // MARK: - Self-audio

    /// Whether TapQ's own voice was in the room at `instant`.
    ///
    /// `false` for a composition that wired no player: with no renderer there is no echo,
    /// and a run that guessed one would drop the wearer's turns for nothing.
    private func selfAudioWasAudible(at instant: TimeInterval) -> Bool {
        guard let selfAudioActivity else { return false }
        return selfAudioActivity().wasAudible(at: instant, hysteresis: selfAudioHysteresis)
    }

    /// Starts a fresh piece of evidence about one native segment.
    private func noteNativeSpeechStarted() {
        let now = monotonicNow()
        nativeSpeechStartedAt = now
        nativeSpeechStoppedAt = nil
        nativeSpeechEndedInSelfAudio = nil
        nativeSpeechBeganInSelfAudio = selfAudioWasAudible(at: now)
        diagnostics.record("native_turn.speech_started",
                           fields: ["self_audio": "\(nativeSpeechBeganInSelfAudio)"])
        // Passed up only in the mode that owns these frames: the contract promises a caller
        // that neither native event arrives while TapQ owns turn arbitration, and a frame
        // the service sent anyway is evidence about a mode that is not in force.
        if nativeTurnDetectionApplied {
            emit(.nativeSpeechStarted(selfAudio: nativeSpeechBeganInSelfAudio))
        }
    }

    private func noteNativeSpeechStopped() {
        let now = monotonicNow()
        nativeSpeechStoppedAt = now
        let audible = selfAudioWasAudible(at: now)
        nativeSpeechEndedInSelfAudio = audible
        diagnostics.record("native_turn.speech_stopped",
                           fields: ["self_audio": "\(audible)"])
        if nativeTurnDetectionApplied {
            emit(.nativeSpeechStopped)
        }
    }

    /// Forgets the current segment's evidence. Every commit spends it, whichever way the
    /// commit went: the next segment is judged on its own.
    private func clearNativeSpeechEvidence() {
        nativeSpeechStartedAt = nil
        nativeSpeechStoppedAt = nil
        nativeSpeechBeganInSelfAudio = false
        nativeSpeechEndedInSelfAudio = nil
    }

    /// Whether the segment the service just committed was TapQ hearing itself.
    ///
    /// The rule is deliberately narrow: **the whole of the detected speech has to have lain
    /// inside TapQ's own audible playback** (plus the echo hysteresis). Both ends are
    /// required, and the evidence for both is sampled at the instant the service reported
    /// them, so a segment that started before TapQ spoke — the wearer talking, with TapQ's
    /// answer landing on top of them — is not this and is left alone.
    ///
    /// Everything ambiguous falls the other way, on purpose. A commit with no
    /// `speech_started` behind it, a peer that skipped `speech_stopped` and whose commit
    /// arrives after the hysteresis, a composition with no player wired: all of them are
    /// "not proven to be TapQ", and they keep the empty-transcript rescue that a wearer
    /// whose transcription lagged depends on. The cost of guessing wrong in this direction
    /// is one repeated answer; the cost in the other direction is a question the wearer
    /// asked out loud and TapQ silently dropped.
    private func committedSegmentWasSelfAudio() -> Bool {
        // Only ever true in the mode that produces these events at all. Restated rather
        // than assumed: an adapter that suppressed a commit while TapQ owned turns would be
        // hiding the protocol violation that check exists to make fatal.
        guard nativeTurnDetectionApplied else { return false }
        guard nativeSpeechStartedAt != nil, nativeSpeechBeganInSelfAudio else { return false }
        // A peer that named the end of speech is believed about it; one that did not is
        // asked about now, which is the closest instant TapQ has.
        return nativeSpeechEndedInSelfAudio ?? selfAudioWasAudible(at: monotonicNow())
    }

    /// Sorts an `input_audio_buffer.committed` into an ack for a commit TapQ sent and a
    /// commit the service's own VAD made, and lets only the second one reach the caller.
    private func handleInputAudioCommitted(itemID: String?, generation: UInt64) {
        if pendingOwnCommits > 0 {
            pendingOwnCommits -= 1
            diagnostics.record("commit.acked")
            return
        }
        let endedUtterance: Bool
        do {
            endedUtterance = try turns.backendCommittedUserTurn()
        } catch {
            // Native mode is off and the service committed anyway. This is precisely the
            // failure non-negotiable 1 names: the transcript that follows such a commit can
            // match the grammar and resolve an approval window nobody authorized, so the
            // session dies here rather than one frame later with a decision attached.
            return failSession(
                .protocolViolation(
                    "the realtime peer committed the input buffer while TapQ owned turn arbitration"),
                generation: generation)
        }
        // The buffer the service just took is gone; what follows belongs to the next
        // utterance. The transcript is reset for the same reason — each VAD segment is a
        // whole utterance as far as the grammar is concerned, and carrying the previous
        // sentence's words into the next one would have the matcher answering a question
        // out of two half-heard ones.
        turnAudioByteCount = 0
        transcript = ""
        let wasSelfAudio = committedSegmentWasSelfAudio()
        let speechMilliseconds = nativeSpeechStartedAt.map { started in
            Int((((nativeSpeechStoppedAt ?? monotonicNow()) - started) * 1_000).rounded())
        }
        clearNativeSpeechEvidence()
        guard endedUtterance else {
            // A segment that closed outside an open user turn: between windows, or while a
            // response is playing. Tolerated (the service's VAD tracks the audio stream, not
            // TapQ's windows) and reported to nobody — there is no window it could resolve.
            diagnostics.record("native_turn.commit_ignored",
                               fields: ["state": turns.state.rawValue])
            return
        }
        guard !wasSelfAudio else {
            // TapQ answering itself. Reported and dropped: the caller never learns of this
            // commit, so it never ends its turn and never asks for the model turn that
            // would have the model reading its own last answer back as a wearer's question
            // — the repeated-answer loop observed on hardware 2026-08-30.
            //
            // The microphone stays open and the window stays exactly as it was: the wearer
            // may be about to speak for real, and this segment was never theirs to lose.
            selfAudioSuppressions += 1
            let deleted = itemID != nil
            diagnostics.record("native_turn.suppressed_self_audio", fields: [
                "speech_ms": speechMilliseconds.map { "\($0)" } ?? "unknown",
                "hysteresis_ms": "\(Int((selfAudioHysteresis * 1_000).rounded()))",
                "count": "\(selfAudioSuppressions)",
                "item_deleted": "\(deleted)",
            ])
            if let itemID {
                // The immediate repeat is already prevented above; this is about the next
                // turn. The item the service just created holds TapQ's own answer as
                // something the wearer said, and a model handed that as context answers it
                // again a window later. Deleting it is the only way to say it never
                // happened. No buffer clear goes with it: the service took the buffer with
                // this commit, and TapQ does not send frames about a buffer it believes is
                // already empty.
                pendingItemDeletes += 1
                enqueue(.deleteConversationItem(id: itemID), generation: generation)
            }
            return
        }
        diagnostics.record("native_turn.committed")
        emit(.userAudioCommittedByBackend)
    }

    /// Forwards a tool call, unless it belongs to a response TapQ has already abandoned.
    ///
    /// The tombstone check is the whole of this method's judgement and it is worth being
    /// explicit about. A cancelled response keeps producing the frames it had already made,
    /// and one of those can be a completed function call — the wearer began a sentence the
    /// model read as `approve`, then talked over it, or the window resolved by nod while the
    /// model was still deciding. Both are "this response has lost its audience", and a tool
    /// call is the one frame in that tail that would *do* something: an approval nobody was
    /// waiting for any more, executed a beat after the wearer changed their mind.
    ///
    /// So a call from a tombstoned response is dropped, and no result is sent — there is
    /// nothing on the far side still parked on it, because TapQ cancelled the response it
    /// belonged to. An unnamed response (`expectCancelAck`) is treated the same way for the
    /// same reason: TapQ has an outstanding cancel and no way to tell whether this call
    /// belongs to it, and the safe reading of "might be from a response I abandoned" is to
    /// abandon it.
    private func handleFunctionCall(callID: String, name: String, argumentsJSON: String) {
        guard !hasOutstandingCancel else {
            diagnostics.record("tool.call_dropped_cancelled",
                               fields: ["call_id": callID, "name": name])
            return
        }
        diagnostics.record("tool.called", fields: [
            "name": name, "call_id": callID, "arguments_length": "\(argumentsJSON.count)",
        ])
        emit(.toolCall(VoiceToolCall(callID: callID, name: name,
                                     argumentsJSON: argumentsJSON)))
    }

    /// Whether a cancel TapQ issued is still waiting for the peer to answer it, in either
    /// bookkeeping form.
    private var hasOutstandingCancel: Bool {
        expectCancelAck || !cancelledResponseIDs.isEmpty
    }

    /// Learns the id of the response the peer has just started.
    ///
    /// Recorded, never acted on: the state machine already knows a response is in flight —
    /// TapQ asked for it — and the only thing the id adds is the ability to name this
    /// response later, when a cancel has to be remembered by something more durable than
    /// "the next `response.done`".
    private func handleResponseCreated(id: String?) {
        guard let id else {
            diagnostics.record("response.created", fields: ["response_id": "unnamed"])
            return
        }
        // A cancel that raced the naming: this is the response it was aimed at, so the
        // unidentified cancel is promoted to a tombstone. Skipped once TapQ has asked for a
        // *new* response, because then this id belongs to that one and the older cancel is
        // still owed an ack of its own.
        if expectCancelAck, turns.state != .responding {
            expectCancelAck = false
            tombstone(id)
            diagnostics.record("response.cancelled_named_late", fields: ["response_id": id])
            return
        }
        activeResponseID = id
        diagnostics.record("response.created", fields: ["response_id": id])
    }

    /// Sorts a `response.done` into the tail of a response TapQ cancelled, the ack for a
    /// cancel the peer never named, and a genuine completion — and lets only the last one
    /// reach the state machine.
    private func handleResponseCompleted(id: String?, generation: UInt64) {
        if let id, let index = cancelledResponseIDs.firstIndex(of: id) {
            // The expected tail of a cancel, and the one done that response owed: the
            // tombstone is spent here rather than left to age out.
            cancelledResponseIDs.remove(at: index)
            diagnostics.record("response.cancelled_done_drained", fields: ["response_id": id])
            // The caller was told this response was over at the cancel, but straggler audio
            // arriving after it re-arms the provider's response-in-flight tracking, and
            // nothing else would ever clear it. Forwarded unless a *newer* response is
            // running: then this terminal belongs to one the caller has already stopped
            // caring about, and forwarding it would retire the live one instead.
            if turns.state != .responding { emit(.responseCompleted) }
            return
        }
        if expectCancelAck {
            // The server acked a locally-initiated cancel with response.done (cancelled).
            // The state machine is already in .open from cancelResponse(); calling
            // responseCompleted() would throw .noResponseInFlight. Still emit the event
            // so the caller clears any response-in-flight tracking (straggler audio
            // deltas after the cancel re-arm the provider's _responseInFlight, and
            // without a terminal responseCompleted the next start() would hit the same
            // violation path).
            expectCancelAck = false
            if let id, id == activeResponseID { activeResponseID = nil }
            diagnostics.record("cancel_ack.received")
            emit(.responseCompleted)
            return
        }
        do {
            try turns.responseCompleted()
        } catch {
            // Nothing was in flight, and no cancelled response answers to this id: the
            // service produced a response nobody asked for, which is the manual-turn
            // contract being broken from the far side.
            return failSession(
                .protocolViolation("the realtime peer completed a response TapQ never requested"),
                generation: generation)
        }
        activeResponseID = nil
        emit(.responseCompleted)
    }

    // MARK: - Outbound pump

    private func enqueue(_ event: RealtimeClientEvent, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        let frame: String
        do {
            frame = try event.encodedFrame()
        } catch {
            return failSession(.protocolViolation(Self.describe(error)), generation: generation)
        }
        outbound.append(frame)
        guard !pumpRunning else { return }
        pumpRunning = true
        Task { @MainActor [weak self] in
            await self?.drainOutbound(generation: generation)
        }
    }

    private func drainOutbound(generation: UInt64) async {
        while true {
            // A stale pump touches nothing: the live session owns `pumpRunning` now.
            guard sessionGeneration == generation else { return }
            guard !outbound.isEmpty else {
                pumpRunning = false
                return
            }
            let frame = outbound.removeFirst()
            do {
                try await transport.send(frame)
            } catch {
                guard sessionGeneration == generation else { return }
                pumpRunning = false
                return failSession(Self.failure(from: error), generation: generation)
            }
        }
    }

    // MARK: - Handshake

    private func awaitHandshake(generation: UInt64) async throws {
        if let outcome = handshakeOutcome, outcome.generation == generation {
            handshakeOutcome = nil
            return try outcome.result.get()
        }
        guard handshakeGeneration == generation else {
            throw VoiceBackendFailure.closed("the session was torn down during the handshake")
        }

        let bound = timeout
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard !Task.isCancelled else { return }
            self?.failSession(
                .network("the realtime session handshake timed out after \(Self.format(bound))s"),
                generation: generation)
        }
        defer { deadline.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            handshakeContinuation = continuation
        }
    }

    private func settleHandshake(_ result: Result<Void, VoiceBackendFailure>, generation: UInt64) {
        guard handshakeGeneration == generation else { return }
        handshakeGeneration = nil
        guard let continuation = handshakeContinuation else {
            handshakeOutcome = (generation, result)
            return
        }
        handshakeContinuation = nil
        continuation.resume(with: result.mapError { $0 as any Error })
    }

    // MARK: - Failure and teardown

    private func violated(_ error: any Error) {
        let failure = (error as? VoiceBackendFailure) ?? .protocolViolation(Self.describe(error))
        failSession(failure, generation: sessionGeneration)
    }

    /// Ends the session and reports it exactly once.
    ///
    /// While the handshake is still outstanding the failure is delivered by throwing out of
    /// `open`, not as an event — a caller whose `open` threw never installed a window and
    /// must not also be told the window died.
    private func failSession(_ failure: VoiceBackendFailure, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        diagnostics.record("session.failed", level: .warning,
                           fields: ["detail": failure.localizedDescription])
        let callback = onEvent
        let handshaking = handshakeGeneration == generation
        turns.sessionFailed()
        if handshaking {
            settleHandshake(.failure(failure), generation: generation)
            teardown(expectedGeneration: generation)
            return
        }
        teardown(expectedGeneration: generation)
        callback?(.sessionFailed(failure))
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != sessionGeneration { return }
        let generation = sessionGeneration
        sessionGeneration &+= 1
        onEvent = nil
        outbound.removeAll()
        pumpRunning = false
        transcript = ""
        expectCancelAck = false
        turnAudioByteCount = 0
        pendingOwnCommits = 0
        pendingItemDeletes = 0
        selfAudioSuppressions = 0
        clearNativeSpeechEvidence()
        // The session boundary is where cancelled-response bookkeeping ends: ids are the
        // peer's, and the next connection's are a different peer's.
        activeResponseID = nil
        cancelledResponseIDs.removeAll()
        // The applied mode belongs to the session that just died; the requested one belongs
        // to the caller and is re-applied by the next `open`.
        nativeTurnDetectionApplied = false
        turns.close()
        transport.close()
        // A continuation that is never resumed is a task leaked forever, so teardown from
        // any path settles an outstanding handshake before it forgets about it.
        if handshakeGeneration == generation {
            settleHandshake(
                .failure(.closed("the session was torn down during the handshake")),
                generation: generation)
        }
    }

    private func emit(_ event: VoiceBackendEvent) {
        onEvent?(event)
    }

    // MARK: - Pure helpers

    /// Splits a chunk into blocks of at most `maxSeconds` of PCM16 audio, preserving order
    /// and never splitting a sample frame in half.
    static func split(_ chunk: VoiceAudioChunk, maxSeconds: TimeInterval) -> [Data] {
        let bytesPerFrame = max(1, 2 * chunk.format.channels)
        let framesPerBlock = max(1, Int(maxSeconds * chunk.format.sampleRate))
        let blockSize = framesPerBlock * bytesPerFrame
        guard chunk.data.count > blockSize else { return chunk.data.isEmpty ? [] : [chunk.data] }

        var blocks: [Data] = []
        var index = chunk.data.startIndex
        while index < chunk.data.endIndex {
            let end = chunk.data.index(index, offsetBy: blockSize, limitedBy: chunk.data.endIndex)
                ?? chunk.data.endIndex
            blocks.append(Data(chunk.data[index..<end]))
            index = end
        }
        return blocks
    }

    private static func failure(from error: any Error) -> VoiceBackendFailure {
        switch error {
        case let failure as VoiceBackendFailure:
            return failure
        case let failure as RealtimeTransportFailure:
            switch failure {
            case .connectFailed(let detail):
                return .network("connect failed: \(detail)")
            case .sendFailed(let detail):
                return .network("send failed: \(detail)")
            case .receiveFailed(let detail):
                return .network("receive failed: \(detail)")
            case .closed(let detail):
                return .closed(detail)
            }
        default:
            return .network(String(describing: error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let violation = error as? VoiceTurnViolation { return violation.localizedDescription }
        if let failure = error as? VoiceBackendFailure { return failure.localizedDescription }
        if let message = error as? RealtimeMessageError { return message.localizedDescription }
        return String(describing: error)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }
}
