import XCTest
@testable import TapQCLI
import TapQVoiceBackends

final class CLICommandParserTests: XCTestCase {
    func testNoArgumentsShowsRootHelp() throws {
        XCTAssertEqual(try CLICommandParser.parse([]), .help(.root))
    }

    func testVersionForms() throws {
        XCTAssertEqual(try CLICommandParser.parse(["version"]), .version(json: false))
        XCTAssertEqual(try CLICommandParser.parse(["--version", "--json"]), .version(json: true))
    }

    func testCaptureOptions() throws {
        let command = try CLICommandParser.parse([
            "capture", "--duration", "2.5", "--format", "csv",
            "--output", "samples.csv", "--force",
        ])
        XCTAssertEqual(command, .capture(CaptureOptions(
            duration: 2.5,
            outputPath: "samples.csv",
            format: .csv,
            force: true
        )))
    }

    func testServeOptions() throws {
        let command = try CLICommandParser.parse([
            "serve", "--broker-dir", "runtime", "--gesture-profile", "gesture.json",
            "--tap-profile", "tap.json", "--timeout", "20", "--no-voice",
            "--no-announcements", "--steering",
            "--question-classifier", "anthropic",
        ])
        XCTAssertEqual(command, .serve(ServeOptions(
            brokerDirectoryPath: "runtime",
            gestureProfilePath: "gesture.json",
            tapProfilePath: "tap.json",
            interactionTimeout: 20,
            voiceEnabled: false,
            announcementsEnabled: false,
            steeringEnabled: true,
            questionClassifier: .anthropic
        )))
    }

    func testServeSpeechVoiceOption() throws {
        guard case .serve(let options) = try CLICommandParser.parse(
            ["serve", "--speech-voice", "zh-CN"]
        ) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.speechVoice, "zh-CN")
    }

    /// nil means "unspecified" so `TAPQ_SPEECH_VOICE` still gets a turn; the en-US
    /// default is applied downstream by SpeechVoiceSelection, not by the parser.
    func testServeSpeechVoiceDefaultsToUnspecified() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"])
        else { return XCTFail("Expected a serve command.") }
        XCTAssertNil(options.speechVoice)
    }

    func testServeSpeechVoiceRequiresValue() {
        XCTAssertThrowsError(try CLICommandParser.parse(["serve", "--speech-voice"]))
    }

    /// `--no-voice` gates the microphone; `--speech-voice` picks the synthesis voice.
    /// They are independent, and disabling input must not silence output.
    func testSpeechVoiceIsIndependentOfMicrophoneToggle() throws {
        guard case .serve(let options) = try CLICommandParser.parse(
            ["serve", "--no-voice", "--speech-voice", "zh-CN"]
        ) else { return XCTFail("Expected a serve command.") }
        XCTAssertFalse(options.voiceEnabled)
        XCTAssertEqual(options.speechVoice, "zh-CN")
    }

    func testServeDefaultsToAutomaticQuestionClassifier() throws {
        XCTAssertEqual(
            try CLICommandParser.parse(["serve"]),
            .serve(ServeOptions(questionClassifier: .auto))
        )
    }

    func testServeAcceptsOpenAIQuestionClassifier() throws {
        XCTAssertEqual(
            try CLICommandParser.parse([
                "serve", "--question-classifier", "openai",
            ]),
            .serve(ServeOptions(questionClassifier: .openai))
        )
    }

    func testServeRejectsUnknownQuestionClassifier() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--question-classifier", "unknown",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--question-classifier must be 'auto', 'apple', 'anthropic', 'openai', or 'local'."
            )
        }
    }

    func testServeDefaultsToTheAppleVoiceBackend() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"])
        else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.voiceBackend, .apple)
    }

    /// Every spelling the enum offers has to be a spelling the flag takes: a case the parser
    /// rejects would be a provider nobody can select.
    func testServeAcceptsEveryVoiceBackendSpelling() throws {
        for provider in VoiceBackendProvider.allCases {
            XCTAssertEqual(
                try CLICommandParser.parse(["serve", "--voice-backend", provider.rawValue]),
                .serve(ServeOptions(voiceBackend: provider))
            )
        }
    }

    func testServeRejectsUnknownVoiceBackend() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--voice-backend", "whisper",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--voice-backend must be 'apple' or 'openai-realtime'."
            )
        }
    }

    func testServeVoiceBackendRequiresValue() {
        XCTAssertThrowsError(try CLICommandParser.parse(["serve", "--voice-backend"]))
    }

    /// The two provider flags are unrelated knobs on the same command, and the parser must
    /// not let one shadow the other.
    func testVoiceBackendAndQuestionClassifierAreIndependent() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--question-classifier", "local", "--voice-backend", "openai-realtime",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.questionClassifier, .local)
        XCTAssertEqual(options.voiceBackend, .openaiRealtime)
    }

    func testServeWearerGateFlag() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--wearer-gate",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertTrue(options.wearerGateEnabled)
    }

    func testServeDefaultsToWearerGateOff() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"])
        else { return XCTFail("Expected a serve command.") }
        XCTAssertFalse(options.wearerGateEnabled)
    }

    func testServeHelpHasDedicatedTopic() throws {
        XCTAssertEqual(try CLICommandParser.parse(["serve", "--help"]), .help(.serve))
        XCTAssertEqual(try CLICommandParser.parse(["help", "serve"]), .help(.serve))
    }

    func testCaptureAcceptsExplicitStdoutPath() throws {
        let command = try CLICommandParser.parse(["capture", "--output", "-"])
        XCTAssertEqual(command, .capture(CaptureOptions()))
    }

    func testCaptureMicEnvelopeSidecarPath() throws {
        let command = try CLICommandParser.parse([
            "capture", "--output", "imu.jsonl", "--mic-envelope", "env.jsonl", "--force",
        ])
        XCTAssertEqual(command, .capture(CaptureOptions(
            outputPath: "imu.jsonl",
            force: true,
            micEnvelopePath: "env.jsonl"
        )))
    }

    func testCaptureMicEnvelopeIsOptionalAndNeedsAPath() throws {
        XCTAssertEqual(
            try CLICommandParser.parse(["capture"]),
            .capture(CaptureOptions()),
            "a capture without the flag stays microphone-free"
        )
        XCTAssertThrowsError(try CLICommandParser.parse(["capture", "--mic-envelope"]))
        XCTAssertThrowsError(
            try CLICommandParser.parse(["capture", "--mic-envelope", "--force"]))
    }

    func testCalibrateAliasParsesRunOptions() throws {
        let command = try CLICommandParser.parse([
            "calibrate", "tap", "--rest-seconds", "1", "--nod-seconds", "2",
            "--shake-seconds", "3", "--tap-seconds", "4",
            "--profile", "profile.json", "--non-interactive",
        ])
        XCTAssertEqual(command, .calibration(.run(CalibrationRunOptions(
            target: .tap,
            restDuration: 1,
            nodDuration: 2,
            shakeDuration: 3,
            tapDuration: 4,
            tapProfilePath: "profile.json",
            nonInteractive: true
        ))))
    }

    func testFullCalibrationAcceptsSeparateProfilePaths() throws {
        let command = try CLICommandParser.parse([
            "calibration", "run", "all",
            "--gesture-profile", "gesture.json",
            "--tap-profile", "tap.json",
        ])
        var options = CalibrationRunOptions()
        options.gestureProfilePath = "gesture.json"
        options.tapProfilePath = "tap.json"
        XCTAssertEqual(command, .calibration(.run(options)))
    }

    func testCombinedProfilePathIsRejected() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "calibration", "run", "--profile", "combined.json",
        ])) { error in
            // The message has to name all three documents, or it sends the user looking
            // for a flag pair that no longer covers the `all` target.
            let message = (error as? CLIUsageError)?.message ?? ""
            XCTAssertTrue(message.contains("--gesture-profile"), message)
            XCTAssertTrue(message.contains("--tap-profile"), message)
            XCTAssertTrue(message.contains("--wearer-speech-profile"), message)
        }
    }

    func testWearerSpeechTargetParsesRunOptions() throws {
        let command = try CLICommandParser.parse([
            "calibration", "run", "wearer-speech",
            "--rest-seconds", "2", "--speak-seconds", "8",
            "--profile", "speech.json", "--non-interactive",
        ])
        var options = CalibrationRunOptions(target: .wearerSpeech)
        options.restDuration = 2
        options.speakDuration = 8
        options.wearerSpeechProfilePath = "speech.json"
        options.nonInteractive = true
        XCTAssertEqual(command, .calibration(.run(options)))
    }

    func testAllTargetAcceptsTheWearerSpeechProfilePathAlongsideTheOthers() throws {
        let command = try CLICommandParser.parse([
            "calibration", "run", "all",
            "--gesture-profile", "gesture.json",
            "--tap-profile", "tap.json",
            "--wearer-speech-profile", "speech.json",
            "--speak-seconds", "5",
        ])
        var options = CalibrationRunOptions()
        options.speakDuration = 5
        options.gestureProfilePath = "gesture.json"
        options.tapProfilePath = "tap.json"
        options.wearerSpeechProfilePath = "speech.json"
        XCTAssertEqual(command, .calibration(.run(options)))
    }

    func testWearerSpeechShowAndResetRouteTheSelectedProfilePath() throws {
        var show = CalibrationShowOptions(target: .wearerSpeech)
        show.wearerSpeechProfilePath = "speech.json"
        show.json = true
        XCTAssertEqual(
            try CLICommandParser.parse([
                "calibration", "show", "wearer-speech", "--profile", "speech.json", "--json",
            ]),
            .calibration(.show(show))
        )

        var reset = CalibrationResetOptions(target: .wearerSpeech)
        reset.wearerSpeechProfilePath = "speech.json"
        reset.confirmed = true
        XCTAssertEqual(
            try CLICommandParser.parse([
                "calibration", "reset", "wearer-speech", "--wearer-speech-profile",
                "speech.json", "--yes",
            ]),
            .calibration(.reset(reset))
        )
    }

    func testUnknownCalibrationTargetNamesEveryValidTarget() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "calibration", "show", "speech",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "Calibration target must be 'all', 'gesture', 'tap', or 'wearer-speech'."
            )
        }
    }

    /// `all` now means three documents, not two.
    func testAllTargetCoversEveryProfileKind() {
        XCTAssertEqual(
            CalibrationTarget.all.profileKinds,
            [.gesture, .tap, .wearerSpeech]
        )
        XCTAssertTrue(CalibrationTarget.all.includes(.wearerSpeech))
        XCTAssertFalse(CalibrationTarget.tap.includes(.wearerSpeech))
        XCTAssertFalse(CalibrationTarget.wearerSpeech.includes(.tap))
    }

    func testCalibrationManagementCommands() throws {
        XCTAssertEqual(
            try CLICommandParser.parse(["calibration", "show", "tap", "--json"]),
            .calibration(.show(CalibrationShowOptions(target: .tap, json: true)))
        )
        XCTAssertEqual(
            try CLICommandParser.parse(["calibration", "reset", "gesture", "--yes"]),
            .calibration(.reset(CalibrationResetOptions(target: .gesture, confirmed: true)))
        )
    }

    func testClaudeIntegrationCommand() throws {
        let command = try CLICommandParser.parse([
            "integration", "claude", "install",
            "--settings", "settings.json", "--hook", "tapq-hook",
            "--permission-policy", "native",
        ])
        XCTAssertEqual(command, .integration(.claude(ClaudeIntegrationOptions(
            action: .install,
            settingsPath: "settings.json",
            hookPath: "tapq-hook",
            permissionPolicy: .native
        ))))
    }

    func testClaudeIntegrationDefaultsToStrictPolicy() throws {
        let command = try CLICommandParser.parse([
            "integration", "claude", "install",
        ])
        XCTAssertEqual(command, .integration(.claude(ClaudeIntegrationOptions(
            action: .install,
            permissionPolicy: .strict
        ))))
    }

    func testCodexIntegrationCommand() throws {
        let command = try CLICommandParser.parse([
            "integration", "codex", "install",
            "--hooks", "hooks.json", "--hook", "tapq-codex-hook",
        ])
        XCTAssertEqual(command, .integration(.codex(CodexIntegrationOptions(
            action: .install,
            hooksPath: "hooks.json",
            hookPath: "tapq-codex-hook"
        ))))
    }

    func testCodexIntegrationRejectsClaudeOptions() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "integration", "codex", "install", "--permission-policy", "native",
        ]))
        XCTAssertThrowsError(try CLICommandParser.parse([
            "integration", "codex", "status", "--settings", "settings.json",
        ]))
    }

    func testIntegrationRejectsUnknownProviderBeforeActionParsing() {
        XCTAssertThrowsError(try CLICommandParser.parse(["integration", "unknown"]))
    }

    func testClaudeIntegrationRejectsUnknownPermissionPolicy() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "integration", "claude", "install", "--permission-policy", "unsafe",
        ]))
    }

    func testClaudeIntegrationRejectsPermissionPolicyForStatus() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "integration", "claude", "status", "--permission-policy", "native",
        ]))
        XCTAssertThrowsError(try CLICommandParser.parse([
            "integration", "claude", "uninstall", "--permission-policy", "native",
        ]))
    }

    func testGestureAnalyzeIsNotACommand() {
        XCTAssertThrowsError(try CLICommandParser.parse(["gesture", "analyze"]))
    }

    func testRejectsInvalidDuration() {
        XCTAssertThrowsError(try CLICommandParser.parse(["capture", "--duration", "0"]))
        XCTAssertThrowsError(try CLICommandParser.parse(["capture", "--duration", "nan"]))
    }
}
