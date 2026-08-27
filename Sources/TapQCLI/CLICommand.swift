import Foundation
import TapQClaudeAdapter
import TapQContextBaseline
import TapQDetectionBaseline
import TapQInteractionBaseline
import TapQVoiceBackends

enum CLIHelpTopic: Equatable {
    case root
    case serve
    case capture
    case replay
    case bench
    case calibration
    case integration
    case instruct
    case policy
}

enum CaptureFormat: String, Equatable {
    case jsonl
    case csv
}

struct CaptureOptions: Equatable {
    var duration: TimeInterval = 10
    var outputPath = "-"
    var format: CaptureFormat = .jsonl
    var force = false
    /// Sidecar path for the capture study's microphone ground-truth track. nil keeps the
    /// command microphone-free, which is what every non-study capture wants.
    var micEnvelopePath: String?
}

struct ServeOptions: Equatable {
    var brokerDirectoryPath: String?
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var interactionTimeout: TimeInterval = 240
    var voiceEnabled = true
    /// Synthesis voice for spoken output — unrelated to `voiceEnabled`, which gates the
    /// microphone. nil means unspecified, leaving `TAPQ_SPEECH_VOICE` and the en-US
    /// default their turn in `SpeechVoiceSelection.resolve`.
    var speechVoice: String?
    var announcementsEnabled = true
    var steeringEnabled = false
    var questionClassifier: QuestionClassifierProvider = .auto
    /// Provider that condenses an agent's final reply into what TapQ says about it.
    /// `off` restores the spoken content of every prompt and notification to what it was
    /// before spoken summaries existed.
    var speechSummarizer: SpeechSummarizerProvider = .auto
    /// Speech pipe for voice commands. `apple` is the shipped on-device path; the realtime
    /// provider is always composed with that same path underneath it as a fallback.
    var voiceBackend: VoiceBackendProvider = .apple
    var encoderModelPath: String?
    /// Meaningful only alongside `encoderModelPath`; shadow is the safe default —
    /// the encoder is observed, never trusted, until promoted explicitly.
    var encoderMode: EncoderMode = .shadow
    /// Stage-2 risk reasoner backend. `off` keeps deterministic confirmation policy.
    var reasonerProvider: ReasonerProvider = .off
    /// Meaningful only alongside a `reasonerProvider` other than `off`; shadow is the
    /// safe default — the reasoner is observed, never trusted, until promoted explicitly.
    var reasonerMode: ReasonerMode = .shadow
    /// IMU-based wearer-speech attribution gate. Default off; needs AirPods motion.
    /// Uses `wearer-speech-calibration.json` when present, provisional thresholds
    /// otherwise. Always fail-open: a degraded or absent signal reproduces today's
    /// shipped behavior verbatim.
    var wearerGateEnabled = false
    /// IMU-based turn control: endpointing (wearer speech-end commits the user turn)
    /// and barge-in (wearer speech-onset during response playback interrupts audio).
    /// Default off; implies a wearer-speech signal source (shared with --wearer-gate
    /// when both are active). Always fail-open: a dead signal means match/timeout
    /// fallback, exactly as without the flag.
    var imuTurnControlEnabled = false
    /// Free-form voice answers for selection/multi-option stop questions. Default off;
    /// requires a voice backend that produces transcripts (i.e. not `.apple` alone).
    /// When enabled, an unmatched final transcript is offered as a free-text reply
    /// with mandatory read-back confirmation (nod to send, shake to discard).
    var voiceFreeformEnabled = false
    /// Dictated instructions to the agent. Default off; under `--voice-trust wearer` it
    /// requires `--wearer-gate`, because an instruction is free text entering the agent's
    /// session and is accepted only from a voice the IMU can attribute to the wearer. When
    /// off the dictation grammar still matches and reaches nothing at all.
    var voiceInstructionsEnabled = false
    /// Whose voice may instruct (RE1). `wearer` is the default and is today's behavior;
    /// `environment` trusts the microphone as the user, which is what makes dictation work
    /// with the AirPods in their case. It never touches an approval.
    var voiceTrust: VoiceTrust = .wearer
    /// Voice sessions (RH1). Default off; requires `--voice-instructions`. TapQ holds the
    /// agent's turn boundary open and keeps listening, so the next instruction can be
    /// spoken instead of typed.
    var voiceSessionEnabled = false
    /// Delegation filter (RD1). Default off; requires a stage-2 reasoner in `primary`
    /// mode, because the tier the filter gates on is a decision only a primary reasoner
    /// is allowed to act on. `routine` answers routine approvals silently; every other
    /// tier, every abstention, and every timeout still go to the wearer.
    var autoAnswerMode: AutoAnswerMode = .off
    /// Always-on attention (RD3). Default off; requires `--wearer-gate`, because the onset
    /// that opens a command window has to be attributable to the wearer. `imu` holds the
    /// motion subscription open between windows and costs continuous IMU power.
    var attentionMode: AttentionMode = .off
    /// Voice-processing spike (RD4). Default off, experimental, macOS-only. Enables
    /// Apple's echo cancellation and AGC on the capture input node. Half-duplex is
    /// unchanged either way: this is plumbing for a later barge-in, not barge-in.
    var voiceProcessingEnabled = false
    /// Quiet output (RD5). Default off. Attention-seeking utterances become short
    /// synthesized cues; anything the wearer asked for is still spoken.
    var quietEnabled = false
}

/// Options for `tapq policy show`.
///
/// Only a reader, deliberately. The policy file is small, hand-written, and the thing it
/// controls is whether TapQ answers for you — a `set` subcommand that could widen that
/// from a shell one-liner is exactly the affordance this feature should not have.
struct PolicyShowOptions: Equatable {
    /// Override for the policy document's location, matching every other profile flag.
    var policyPath: String?
    var json = false
}

enum PolicyCommand: Equatable {
    case show(PolicyShowOptions)
}

/// Options for `tapq instruct`, the debug/SDK seam that submits an instruction without a
/// microphone. See `CLICommand.instruct`.
struct InstructOptions: Equatable {
    /// The agent session the instruction is addressed to, as the adapter reports it.
    var sessionID = ""
    /// The instruction itself. Multiple trailing words are joined with single spaces, so
    /// quoting is optional at a shell.
    var text = ""
    /// Runtime discovery directory, for a broker started with `serve --broker-dir`.
    var brokerDirectoryPath: String?
    /// The agent behind the session, when the caller knows it. Optional because the
    /// broker's session identifiers carry no agent; supplying it moves the "this agent
    /// cannot be instructed" refusal off the wire and onto the command line, where it
    /// costs nothing and reads better.
    var agentID: String?
}

struct ReplayOptions: Equatable {
    var inputPath = ""
    var labelsPath: String?
    var format: CaptureFormat?
    var tolerance: TimeInterval = 1.0
    var json = false
    var encoderModelPath: String?
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var wearerSpeechProfilePath: String?
    /// Envelope sidecar from `tapq capture --mic-envelope`, used as wearer-speech ground
    /// truth when the label file carries no `wearer_speech` segments.
    var micEnvelopePath: String?
}

/// Options for `tapq bench reasoner`.
///
/// The provider defaults to `apple` rather than to `off`: `off` is the safe default for
/// *serving*, where no reasoner means no escalation, but a bench run without a reasoner
/// measures nothing at all, so the parser rejects it outright.
struct BenchOptions: Equatable {
    var scenariosPath = ""
    var reasonerProvider: ReasonerProvider = .apple
    /// Run only the first N scenarios in corpus order. nil runs the whole corpus.
    var limit: Int?
    var json = false
}

enum CalibrationTarget: String, Equatable {
    case all
    case gesture
    case tap
    case wearerSpeech = "wearer-speech"

    var profileKinds: [CalibrationProfileKind] {
        switch self {
        case .all: [.gesture, .tap, .wearerSpeech]
        case .gesture: [.gesture]
        case .tap: [.tap]
        case .wearerSpeech: [.wearerSpeech]
        }
    }

    func includes(_ kind: CalibrationProfileKind) -> Bool {
        profileKinds.contains(kind)
    }
}

struct CalibrationRunOptions: Equatable {
    var target: CalibrationTarget = .all
    var restDuration: TimeInterval = 3
    var nodDuration: TimeInterval = 4
    var shakeDuration: TimeInterval = 4
    var tapDuration: TimeInterval = 4
    /// Read-aloud phase. Longer than the others by default: the wearer-speech statistic is
    /// a median over a sustained tremor, not a peak, so it needs continuous speech to
    /// summarise rather than a handful of discrete events.
    var speakDuration: TimeInterval = 6
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var wearerSpeechProfilePath: String?
    var nonInteractive = false
}

struct CalibrationShowOptions: Equatable {
    var target: CalibrationTarget = .all
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var wearerSpeechProfilePath: String?
    var json = false
}

struct CalibrationResetOptions: Equatable {
    var target: CalibrationTarget = .all
    var gestureProfilePath: String?
    var tapProfilePath: String?
    var wearerSpeechProfilePath: String?
    var confirmed = false
}

enum CalibrationCommand: Equatable {
    case run(CalibrationRunOptions)
    case show(CalibrationShowOptions)
    case reset(CalibrationResetOptions)
}

enum IntegrationAction: String, Equatable {
    case install
    case status
    case uninstall
}

struct ClaudeIntegrationOptions: Equatable {
    let action: IntegrationAction
    var settingsPath: String?
    var hookPath: String?
    var permissionPolicy: ClaudePermissionPolicy = .strict
}

struct CodexIntegrationOptions: Equatable {
    let action: IntegrationAction
    var hooksPath: String?
    var hookPath: String?
}

struct CursorIntegrationOptions: Equatable {
    let action: IntegrationAction
    var hooksPath: String?
    var hookPath: String?
}

struct OpenCodeIntegrationOptions: Equatable {
    let action: IntegrationAction
    var pluginPath: String?
    var hookPath: String?
}

enum IntegrationOptions: Equatable {
    case claude(ClaudeIntegrationOptions)
    case codex(CodexIntegrationOptions)
    case cursor(CursorIntegrationOptions)
    case openCode(OpenCodeIntegrationOptions)
}

enum CLICommand: Equatable {
    case help(CLIHelpTopic)
    case version(json: Bool)
    case serve(ServeOptions)
    /// Submit an instruction to a running broker without speaking it. A debug and
    /// device-adapter seam, not a way to drive an agent from a terminal: everything the
    /// wearer path enforces before an instruction is queued — attribution, read-back,
    /// confirmation — is skipped here, and the only thing standing in for it is that the
    /// caller already has the runtime's private discovery record.
    case instruct(InstructOptions)
    case capture(CaptureOptions)
    case replay(ReplayOptions)
    case bench(BenchOptions)
    case calibration(CalibrationCommand)
    case integration(IntegrationOptions)
    /// Inspect the auto-answer policy `serve` would run under.
    case policy(PolicyCommand)
}

struct CLIUsageError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum CLICommandParser {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help(.root) }
        let rest = Array(arguments.dropFirst())

        switch first {
        case "help", "--help", "-h":
            return .help(try helpTopic(from: rest))
        case "version", "--version", "-V":
            return .version(json: try parseVersion(rest))
        case "serve":
            if isHelp(rest) { return .help(.serve) }
            return .serve(try parseServe(rest))
        case "instruct":
            if isHelp(rest) { return .help(.instruct) }
            return .instruct(try parseInstruct(rest))
        case "capture":
            if isHelp(rest) { return .help(.capture) }
            return .capture(try parseCapture(rest))
        case "replay":
            if isHelp(rest) { return .help(.replay) }
            return .replay(try parseReplay(rest))
        case "bench":
            return try parseBench(rest)
        case "calibrate":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.run(try parseCalibrationRun(rest)))
        case "calibration":
            return try parseCalibration(rest)
        case "integration":
            return try parseIntegration(rest)
        case "policy":
            return try parsePolicy(rest)
        default:
            throw CLIUsageError(message: "Unknown command '\(first)'.")
        }
    }

    private static func helpTopic(from arguments: [String]) throws -> CLIHelpTopic {
        guard let topic = arguments.first else { return .root }
        guard arguments.count == 1 else {
            throw CLIUsageError(message: "Help accepts at most one command name.")
        }
        switch topic {
        case "serve": return .serve
        case "capture": return .capture
        case "replay": return .replay
        case "bench": return .bench
        case "calibrate", "calibration": return .calibration
        case "integration": return .integration
        case "instruct": return .instruct
        case "policy": return .policy
        default: throw CLIUsageError(message: "Unknown help topic '\(topic)'.")
        }
    }

    private static func parseVersion(_ arguments: [String]) throws -> Bool {
        switch arguments {
        case []: return false
        case ["--json"]: return true
        case ["--help"], ["-h"]: return false
        default: throw CLIUsageError(message: "Usage: tapq version [--json]")
        }
    }

    private static func parseCapture(_ arguments: [String]) throws -> CaptureOptions {
        var options = CaptureOptions()
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--duration":
                options.duration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--output", "-o":
                options.outputPath = try cursor.requireValue(for: argument)
            case "--format":
                let value = try cursor.requireValue(for: argument)
                guard let format = CaptureFormat(rawValue: value) else {
                    throw CLIUsageError(message: "--format must be 'jsonl' or 'csv'.")
                }
                options.format = format
            case "--force", "-f":
                options.force = true
            case "--mic-envelope":
                options.micEnvelopePath = try cursor.requireValue(for: argument)
            default:
                throw CLIUsageError(message: "Unknown capture option '\(argument)'.")
            }
        }
        return options
    }

    private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var encoderModeSpecified = false
        var reasonerModeSpecified = false
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--broker-dir":
                options.brokerDirectoryPath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--timeout":
                options.interactionTimeout = try duration(
                    cursor.requireValue(for: argument), flag: argument)
            case "--no-voice":
                options.voiceEnabled = false
            case "--speech-voice":
                options.speechVoice = try cursor.requireValue(for: argument)
            case "--no-announcements":
                options.announcementsEnabled = false
            case "--steering":
                options.steeringEnabled = true
            case "--question-classifier":
                let value = try cursor.requireValue(for: argument)
                guard let provider = QuestionClassifierProvider(rawValue: value) else {
                    throw CLIUsageError(
                        message: "--question-classifier must be 'auto', 'apple', 'anthropic', 'openai', or 'local'."
                    )
                }
                options.questionClassifier = provider
            case "--speech-summarizer":
                let value = try cursor.requireValue(for: argument)
                guard let provider = SpeechSummarizerProvider(rawValue: value) else {
                    throw CLIUsageError(
                        message: "--speech-summarizer must be 'auto', 'apple', 'anthropic', 'openai', 'heuristic', or 'off'."
                    )
                }
                options.speechSummarizer = provider
            case "--voice-backend":
                let value = try cursor.requireValue(for: argument)
                guard let provider = VoiceBackendProvider(rawValue: value) else {
                    throw CLIUsageError(
                        message: "--voice-backend must be 'apple' or 'openai-realtime'."
                    )
                }
                options.voiceBackend = provider
            case "--encoder-model":
                options.encoderModelPath = try cursor.requireValue(for: argument)
            case "--encoder-mode":
                let value = try cursor.requireValue(for: argument)
                guard let mode = EncoderMode(rawValue: value), mode != .off else {
                    throw CLIUsageError(message: "--encoder-mode must be 'shadow' or 'primary'.")
                }
                options.encoderMode = mode
                encoderModeSpecified = true
            case "--reasoner":
                let value = try cursor.requireValue(for: argument)
                guard let provider = ReasonerProvider(rawValue: value) else {
                    throw CLIUsageError(message: "--reasoner must be 'off' or 'apple'.")
                }
                options.reasonerProvider = provider
            case "--reasoner-mode":
                let value = try cursor.requireValue(for: argument)
                guard let mode = ReasonerMode(rawValue: value), mode != .off else {
                    throw CLIUsageError(message: "--reasoner-mode must be 'shadow' or 'primary'.")
                }
                options.reasonerMode = mode
                reasonerModeSpecified = true
            case "--wearer-gate":
                options.wearerGateEnabled = true
            case "--imu-turn-control":
                options.imuTurnControlEnabled = true
            case "--voice-freeform":
                options.voiceFreeformEnabled = true
            case "--voice-instructions":
                options.voiceInstructionsEnabled = true
            case "--voice-trust":
                let value = try cursor.requireValue(for: argument)
                guard let trust = VoiceTrust(rawValue: value) else {
                    throw CLIUsageError(
                        message: "--voice-trust must be 'wearer' or 'environment'."
                    )
                }
                options.voiceTrust = trust
            case "--voice-session":
                options.voiceSessionEnabled = true
            case "--auto-answer":
                let value = try cursor.requireValue(for: argument)
                guard let mode = AutoAnswerMode(rawValue: value) else {
                    throw CLIUsageError(message: "--auto-answer must be 'off' or 'routine'.")
                }
                options.autoAnswerMode = mode
            case "--attention":
                let value = try cursor.requireValue(for: argument)
                guard let mode = AttentionMode(rawValue: value) else {
                    throw CLIUsageError(message: "--attention must be 'off' or 'imu'.")
                }
                options.attentionMode = mode
            case "--voice-processing":
                options.voiceProcessingEnabled = true
            case "--quiet":
                options.quietEnabled = true
            default:
                throw CLIUsageError(message: "Unknown serve option '\(argument)'.")
            }
        }
        if encoderModeSpecified, options.encoderModelPath == nil {
            throw CLIUsageError(message: "--encoder-mode requires --encoder-model.")
        }
        if reasonerModeSpecified, options.reasonerProvider == .off {
            throw CLIUsageError(
                message: "--reasoner-mode requires a --reasoner provider other than 'off'."
            )
        }
        // The one flag dependency in TapQ that exists for safety rather than for
        // composition. Dictated instructions are fail-closed on wearer attribution (RC4),
        // and the attribution signal is composed only by `--wearer-gate` — so without it
        // every dictation would be refused, and a wearer would be talking to a feature
        // that had been silently switched off. Refused at startup, like
        // `--voice-freeform` on the Apple backend, rather than accepted and inert.
        //
        // `--voice-trust environment` is the operator saying the attribution is not wanted
        // (RE1): there is then nothing to be fail-closed about, so the pairing is dropped
        // rather than merely tolerated. The error text names the alternative, because a
        // wearer with no AirPods hitting this message has no other way to learn there is one.
        if options.voiceInstructionsEnabled,
           !options.wearerGateEnabled,
           options.voiceTrust == .wearer {
            throw CLIUsageError(
                message: "--voice-instructions requires --wearer-gate under "
                    + "--voice-trust wearer. A dictated instruction is accepted only from "
                    + "a voice TapQ can attribute to the wearer, and the attribution "
                    + "signal comes from the gate. Pass --voice-trust environment to "
                    + "instruct with no AirPods, trusting the microphone as the user."
            )
        }
        // A voice session is a turn boundary held open for the wearer to speak the next
        // instruction into. With no queue for that instruction to reach, the hold would be
        // a hook parked for ten minutes waiting on something that can never arrive —
        // refused here rather than accepted and left hanging.
        if options.voiceSessionEnabled, !options.voiceInstructionsEnabled {
            throw CLIUsageError(
                message: "--voice-session requires --voice-instructions. A held turn "
                    + "boundary exists so the wearer can dictate the agent's next "
                    + "instruction, and without the instruction channel there is nowhere "
                    + "for one to go."
            )
        }
        // The delegation filter gates on a tier, and a tier is a reasoner decision. Under
        // `--reasoner off` there are no decisions at all; under `shadow` there are
        // decisions the operator has explicitly said not to act on, and silently answering
        // an approval on the strength of one would be the largest possible way to act on
        // it. Both are refused here rather than accepted and left inert, so a run that
        // asked to delegate either delegates or says why it cannot.
        if options.autoAnswerMode != .off {
            guard options.reasonerProvider != .off else {
                throw CLIUsageError(
                    message: "--auto-answer requires a --reasoner provider other than "
                        + "'off'. The filter answers only what a stage-2 reasoner has "
                        + "called routine, and without a reasoner nothing is."
                )
            }
            guard options.reasonerMode == .primary else {
                throw CLIUsageError(
                    message: "--auto-answer requires --reasoner-mode primary. In shadow "
                        + "mode the reasoner's decisions are observed and deliberately "
                        + "not acted on; answering an approval from one would be acting "
                        + "on it."
                )
            }
        }
        // Attention windows open on an attributed wearer-speech onset, and attribution is
        // composed only by `--wearer-gate`. Without it the onset would be any voice in the
        // room, and TapQ would answer a stranger's question about the wearer's agents.
        if options.attentionMode != .off, !options.wearerGateEnabled {
            throw CLIUsageError(
                message: "--attention imu requires --wearer-gate. A command window opens "
                    + "on wearer speech, and only the gate can say whose speech it was."
            )
        }
        return options
    }

    /// `tapq policy show [--policy PATH] [--json]`.
    private static func parsePolicy(_ arguments: [String]) throws -> CLICommand {
        guard let action = arguments.first else { return .help(.policy) }
        if action == "--help" || action == "-h" { return .help(.policy) }
        guard action == "show" else {
            throw CLIUsageError(
                message: "Unknown policy action '\(action)'. Available actions: 'show'."
            )
        }
        let rest = Array(arguments.dropFirst())
        if isHelp(rest) { return .help(.policy) }

        var options = PolicyShowOptions()
        var cursor = ArgumentCursor(rest)
        while let argument = cursor.pop() {
            switch argument {
            case "--policy": options.policyPath = try cursor.requireValue(for: argument)
            case "--json": options.json = true
            default:
                throw CLIUsageError(message: "Unknown policy show option '\(argument)'.")
            }
        }
        return .policy(.show(options))
    }

    /// `tapq instruct <session-id> <text…>`.
    ///
    /// The text is positional and greedy: everything after the session identifier that is
    /// not a recognized option joins into one instruction, so an operator can type the
    /// sentence without quoting it. Options may appear before or after it.
    private static func parseInstruct(_ arguments: [String]) throws -> InstructOptions {
        var options = InstructOptions()
        var words: [String] = []
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--broker-dir":
                options.brokerDirectoryPath = try cursor.requireValue(for: argument)
            case "--agent":
                options.agentID = try cursor.requireValue(for: argument)
            default:
                guard !argument.hasPrefix("--") else {
                    throw CLIUsageError(message: "Unknown instruct option '\(argument)'.")
                }
                words.append(argument)
            }
        }
        guard let sessionID = words.first, !sessionID.isEmpty else {
            throw CLIUsageError(message: "Usage: tapq instruct <session-id> <text>")
        }
        options.sessionID = sessionID
        options.text = words.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.text.isEmpty else {
            throw CLIUsageError(message: "instruct requires instruction text.")
        }
        return options
    }

    private static func parseReplay(_ arguments: [String]) throws -> ReplayOptions {
        var options = ReplayOptions()
        var cursor = ArgumentCursor(arguments)
        while let argument = cursor.pop() {
            switch argument {
            case "--input", "-i":
                options.inputPath = try cursor.requireValue(for: argument)
            case "--labels":
                options.labelsPath = try cursor.requireValue(for: argument)
            case "--format":
                let value = try cursor.requireValue(for: argument)
                guard let format = CaptureFormat(rawValue: value) else {
                    throw CLIUsageError(message: "--format must be 'jsonl' or 'csv'.")
                }
                options.format = format
            case "--tolerance":
                options.tolerance = try duration(
                    cursor.requireValue(for: argument), flag: argument)
            case "--json":
                options.json = true
            case "--encoder-model":
                options.encoderModelPath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--wearer-speech-profile":
                options.wearerSpeechProfilePath = try cursor.requireValue(for: argument)
            case "--mic-envelope":
                options.micEnvelopePath = try cursor.requireValue(for: argument)
            default:
                throw CLIUsageError(message: "Unknown replay option '\(argument)'.")
            }
        }
        guard !options.inputPath.isEmpty else {
            throw CLIUsageError(message: "replay requires --input PATH.")
        }
        return options
    }

    private static func parseBench(_ arguments: [String]) throws -> CLICommand {
        guard let subject = arguments.first else { return .help(.bench) }
        let rest = Array(arguments.dropFirst())
        if subject == "--help" || subject == "-h" { return .help(.bench) }
        guard subject == "reasoner" else {
            throw CLIUsageError(
                message: "Unknown bench subject '\(subject)'. Available subjects: 'reasoner'."
            )
        }
        if isHelp(rest) { return .help(.bench) }

        var options = BenchOptions()
        var cursor = ArgumentCursor(rest)
        while let argument = cursor.pop() {
            switch argument {
            case "--scenarios":
                options.scenariosPath = try cursor.requireValue(for: argument)
            case "--reasoner":
                let value = try cursor.requireValue(for: argument)
                guard let provider = ReasonerProvider(rawValue: value) else {
                    throw CLIUsageError(message: "--reasoner must be 'apple'.")
                }
                // Rejected rather than accepted-and-ignored: `--reasoner off` reads like a
                // supported way to run the bench and there is nothing it could measure.
                guard provider != .off else {
                    throw CLIUsageError(
                        message: "bench needs a reasoner; '--reasoner off' has nothing to measure."
                    )
                }
                options.reasonerProvider = provider
            case "--limit":
                let value = try cursor.requireValue(for: argument)
                guard let limit = Int(value), limit > 0 else {
                    throw CLIUsageError(
                        message: "--limit must be a whole number greater than 0."
                    )
                }
                options.limit = limit
            case "--json":
                options.json = true
            default:
                throw CLIUsageError(message: "Unknown bench option '\(argument)'.")
            }
        }
        guard !options.scenariosPath.isEmpty else {
            throw CLIUsageError(message: "bench reasoner requires --scenarios PATH.")
        }
        return .bench(options)
    }

    private static func parseCalibration(_ arguments: [String]) throws -> CLICommand {
        guard let action = arguments.first else { return .help(.calibration) }
        let rest = Array(arguments.dropFirst())
        if action == "--help" || action == "-h" { return .help(.calibration) }

        switch action {
        case "run":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.run(try parseCalibrationRun(rest)))
        case "show":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.show(try parseCalibrationShow(rest)))
        case "reset":
            if isHelp(rest) { return .help(.calibration) }
            return .calibration(.reset(try parseCalibrationReset(rest)))
        default:
            throw CLIUsageError(message: "Unknown calibration action '\(action)'.")
        }
    }

    private static func parseCalibrationRun(_ arguments: [String]) throws -> CalibrationRunOptions {
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationRunOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--rest-seconds":
                options.restDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--nod-seconds":
                options.nodDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--shake-seconds":
                options.shakeDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--tap-seconds":
                options.tapDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--speak-seconds":
                options.speakDuration = try duration(cursor.requireValue(for: argument), flag: argument)
            case "--profile":
                selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile":
                options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile":
                options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--wearer-speech-profile":
                options.wearerSpeechProfilePath = try cursor.requireValue(for: argument)
            case "--non-interactive":
                options.nonInteractive = true
            default:
                throw CLIUsageError(message: "Unknown calibration option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func parseCalibrationShow(_ arguments: [String]) throws -> CalibrationShowOptions {
        if isHelp(arguments) { throw CLIUsageError(message: "Usage: tapq calibration show [all|gesture|tap|wearer-speech] [--json]") }
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationShowOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--profile": selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile": options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile": options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--wearer-speech-profile": options.wearerSpeechProfilePath = try cursor.requireValue(for: argument)
            case "--json": options.json = true
            default: throw CLIUsageError(message: "Unknown calibration show option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func parseCalibrationReset(_ arguments: [String]) throws -> CalibrationResetOptions {
        if isHelp(arguments) { throw CLIUsageError(message: "Usage: tapq calibration reset [all|gesture|tap|wearer-speech] [--yes]") }
        let (target, remaining) = try calibrationTarget(from: arguments)
        var options = CalibrationResetOptions(target: target)
        var selectedProfilePath: String?
        var cursor = ArgumentCursor(remaining)
        while let argument = cursor.pop() {
            switch argument {
            case "--profile": selectedProfilePath = try cursor.requireValue(for: argument)
            case "--gesture-profile": options.gestureProfilePath = try cursor.requireValue(for: argument)
            case "--tap-profile": options.tapProfilePath = try cursor.requireValue(for: argument)
            case "--wearer-speech-profile": options.wearerSpeechProfilePath = try cursor.requireValue(for: argument)
            case "--yes", "-y": options.confirmed = true
            default: throw CLIUsageError(message: "Unknown calibration reset option '\(argument)'.")
            }
        }
        try applySelectedProfilePath(selectedProfilePath, target: target, options: &options)
        return options
    }

    private static func calibrationTarget(
        from arguments: [String]
    ) throws -> (CalibrationTarget, [String]) {
        guard let first = arguments.first, !first.hasPrefix("-") else {
            return (.all, arguments)
        }
        guard let target = CalibrationTarget(rawValue: first) else {
            throw CLIUsageError(message: "Calibration target must be 'all', 'gesture', 'tap', or 'wearer-speech'.")
        }
        return (target, Array(arguments.dropFirst()))
    }

    /// `--profile` names the one document a single-target command touches, so it has no
    /// meaning under `all`, where three documents are in play.
    private static let combinedProfilePathMessage =
        "--profile requires the gesture, tap, or wearer-speech target; use --gesture-profile, --tap-profile, and --wearer-speech-profile when targeting all."

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationRunOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .wearerSpeech: options.wearerSpeechProfilePath = path
        case .all: throw CLIUsageError(message: combinedProfilePathMessage)
        }
    }

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationShowOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .wearerSpeech: options.wearerSpeechProfilePath = path
        case .all: throw CLIUsageError(message: combinedProfilePathMessage)
        }
    }

    private static func applySelectedProfilePath(
        _ path: String?,
        target: CalibrationTarget,
        options: inout CalibrationResetOptions
    ) throws {
        guard let path else { return }
        switch target {
        case .gesture: options.gestureProfilePath = path
        case .tap: options.tapProfilePath = path
        case .wearerSpeech: options.wearerSpeechProfilePath = path
        case .all: throw CLIUsageError(message: combinedProfilePathMessage)
        }
    }

    private static func parseIntegration(_ arguments: [String]) throws -> CLICommand {
        guard let provider = arguments.first else { return .help(.integration) }
        if provider == "--help" || provider == "-h" { return .help(.integration) }
        guard provider == "claude" || provider == "codex" || provider == "cursor"
            || provider == "opencode"
        else {
            throw CLIUsageError(
                message: "Unknown integration '\(provider)'. Available integrations: 'claude', 'codex', 'cursor', 'opencode'."
            )
        }
        let remaining = Array(arguments.dropFirst())
        guard let actionName = remaining.first else { return .help(.integration) }
        if actionName == "--help" || actionName == "-h" { return .help(.integration) }
        guard let action = IntegrationAction(rawValue: actionName) else {
            throw CLIUsageError(message: "Unknown \(provider) integration action '\(actionName)'.")
        }

        switch provider {
        case "claude":
            var options = ClaudeIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--settings": options.settingsPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                case "--permission-policy":
                    guard action == .install else {
                        throw CLIUsageError(message: "--permission-policy is only valid with 'install'.")
                    }
                    let value = try cursor.requireValue(for: argument)
                    guard let policy = ClaudePermissionPolicy(rawValue: value) else {
                        throw CLIUsageError(message: "--permission-policy must be 'strict' or 'native'.")
                    }
                    options.permissionPolicy = policy
                default:
                    throw CLIUsageError(message: "Unknown Claude integration option '\(argument)'.")
                }
            }
            return .integration(.claude(options))
        case "codex":
            var options = CodexIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--hooks": options.hooksPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                default:
                    throw CLIUsageError(message: "Unknown Codex integration option '\(argument)'.")
                }
            }
            return .integration(.codex(options))
        case "cursor":
            var options = CursorIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--hooks": options.hooksPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                default:
                    throw CLIUsageError(message: "Unknown Cursor integration option '\(argument)'.")
                }
            }
            return .integration(.cursor(options))
        case "opencode":
            var options = OpenCodeIntegrationOptions(action: action)
            var cursor = ArgumentCursor(Array(remaining.dropFirst()))
            while let argument = cursor.pop() {
                switch argument {
                case "--plugin": options.pluginPath = try cursor.requireValue(for: argument)
                case "--hook": options.hookPath = try cursor.requireValue(for: argument)
                default:
                    throw CLIUsageError(message: "Unknown OpenCode integration option '\(argument)'.")
                }
            }
            return .integration(.openCode(options))
        default:
            preconditionFailure("Validated integration provider")
        }
    }

    private static func duration(_ value: String, flag: String) throws -> TimeInterval {
        guard let parsed = Double(value), parsed.isFinite, parsed > 0, parsed <= 3_600 else {
            throw CLIUsageError(message: "\(flag) must be a number greater than 0 and no more than 3600.")
        }
        return parsed
    }

    private static func isHelp(_ arguments: [String]) -> Bool {
        arguments == ["--help"] || arguments == ["-h"]
    }
}

private struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func pop() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func requireValue(for flag: String) throws -> String {
        guard let value = pop(), !value.isEmpty,
              value == "-" || !value.hasPrefix("-") else {
            throw CLIUsageError(message: "\(flag) requires a value.")
        }
        return value
    }
}
