import Foundation
import TapQClaudeAdapter
import TapQCodexAdapter
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol

public enum TapQVersion {
    public static let current = "0.2.0"
}

public struct TapQCLIIO {
    public let writeOutput: (String) -> Void
    public let writeError: (String) -> Void
    public let readInput: () -> String?

    public init(
        writeOutput: @escaping (String) -> Void,
        writeError: @escaping (String) -> Void,
        readInput: @escaping () -> String?
    ) {
        self.writeOutput = writeOutput
        self.writeError = writeError
        self.readInput = readInput
    }

    public static let live = TapQCLIIO(
        writeOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeError: { FileHandle.standardError.write(Data($0.utf8)) },
        readInput: { readLine(strippingNewline: true) }
    )
}

@MainActor public final class TapQCLIApplication {
    private let io: TapQCLIIO
    private let motionCapture: (any TapQMotionCapturing)?
    private let runtimeService: (any TapQRuntimeServing)?
    /// Loads a TapQ-1 model into a window scorer for `tapq replay --encoder-model`.
    /// nil on platforms without a Core ML host (the flag then reports unavailability).
    private let motionScorerLoader: ((URL) async throws -> any MotionWindowScoring)?
    /// Builds the stage-2 reasoner for `tapq serve --reasoner`. nil on platforms without
    /// a model backend, which the runtime reports as an unavailable reasoner and serves
    /// through — the same shape as `motionScorerLoader`, handed to the runtime host.
    private let reasonerLoader: TapQReasonerLoading?
    private let environment: [String: String]
    private let homeDirectory: URL
    private let executableURL: URL
    private let currentDirectory: URL
    private let monotonicNow: () -> TimeInterval

    public init(
        io: TapQCLIIO = .live,
        motionCapture: (any TapQMotionCapturing)? = nil,
        runtimeService: (any TapQRuntimeServing)? = nil,
        motionScorerLoader: ((URL) async throws -> any MotionWindowScoring)? = nil,
        reasonerLoader: TapQReasonerLoading? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.io = io
        self.motionCapture = motionCapture
        self.runtimeService = runtimeService
        self.motionScorerLoader = motionScorerLoader
        self.reasonerLoader = reasonerLoader
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL
        self.currentDirectory = currentDirectory
        self.monotonicNow = monotonicNow
    }

    @discardableResult
    public func run(arguments: [String]) async -> Int32 {
        do {
            let command = try CLICommandParser.parse(arguments)
            return try await execute(command)
        } catch let error as CLIUsageError {
            errorLine("error: \(error.localizedDescription)")
            errorLine("")
            errorLine(Self.rootHelp)
            return 64
        } catch TapQMotionCaptureError.unavailable {
            errorLine("error: \(TapQMotionCaptureError.unavailable.localizedDescription)")
            return 69
        } catch let error as TapQRuntimeUnavailableError {
            errorLine("error: \(error.localizedDescription)")
            return 69
        } catch {
            errorLine("error: \(error.localizedDescription)")
            return 1
        }
    }

    private func execute(_ command: CLICommand) async throws -> Int32 {
        switch command {
        case .help(let topic):
            outputLine(Self.help(for: topic))
        case .version(let json):
            if json {
                outputLine(#"{"name":"tapq","version":"\#(TapQVersion.current)","wire_protocol":\#(WireProtocol.version)}"#)
            } else {
                outputLine("tapq \(TapQVersion.current)")
            }
        case .serve(let options):
            try await runServe(options)
        case .capture(let options):
            try await runCapture(options)
        case .replay(let options):
            try await runReplay(options)
        case .calibration(let command):
            try await runCalibration(command)
        case .integration(let options):
            try runIntegration(options)
        }
        return 0
    }

    private func runServe(_ options: ServeOptions) async throws {
        guard let runtimeService else { throw TapQRuntimeUnavailableError() }
        let defaults = CalibrationStore.defaultStore(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let configuration = TapQRuntimeConfiguration(
            brokerDirectory: options.brokerDirectoryPath.map(resolvedURL(for:)),
            gestureProfileURL: options.gestureProfilePath.map(resolvedURL(for:))
                ?? defaults.gestureProfileURL,
            tapProfileURL: options.tapProfilePath.map(resolvedURL(for:))
                ?? defaults.tapProfileURL,
            interactionTimeout: min(
                options.interactionTimeout,
                InteractionBudget.maxListenWindow
            ),
            voiceEnabled: options.voiceEnabled,
            speechVoice: SpeechVoiceSelection.resolve(
                flag: options.speechVoice,
                environment: environment
            ),
            announcementsEnabled: options.announcementsEnabled,
            steeringEnabled: options.steeringEnabled,
            questionClassifier: options.questionClassifier,
            encoderModelURL: options.encoderModelPath.map(resolvedURL(for:)),
            encoderMode: options.encoderModelPath == nil ? .off : options.encoderMode,
            reasonerProvider: options.reasonerProvider,
            reasonerMode: options.reasonerProvider == .off ? .off : options.reasonerMode
        )
        try await runtimeService.serve(
            configuration: configuration,
            reasonerLoader: reasonerLoader
        ) { [io] endpoint in
            io.writeOutput("TapQ runtime is ready. Press Control-C to stop.\n")
            io.writeOutput("Broker socket: \(endpoint.socketPath)\n")
            io.writeOutput("Discovery: \(endpoint.discoveryPath)\n")
            io.writeOutput("Gesture profile: \(endpoint.gestureProfileLoaded ? "loaded" : "default")\n")
            io.writeOutput("Tap profile: \(endpoint.tapProfileLoaded ? "loaded" : "default")\n")
            io.writeOutput("AirPods motion: \(endpoint.motionAvailable ? "available" : "unavailable")\n")
            io.writeOutput("Voice input: \(endpoint.voiceAvailable ? "available" : "unavailable")\n")
            if let encoderStatus = endpoint.encoderStatus {
                io.writeOutput("TapQ-1 encoder: \(encoderStatus)\n")
            }
            if let reasonerStatus = endpoint.reasonerStatus {
                io.writeOutput("Stage-2 reasoner: \(reasonerStatus)\n")
            }
        }
    }

    private func runCapture(_ options: CaptureOptions) async throws {
        guard let motionCapture else { throw TapQMotionCaptureError.unavailable }

        let outputURL: URL? = options.outputPath == "-"
            ? nil
            : resolvedURL(for: options.outputPath)
        let writer = try outputURL.map {
            try CaptureFileWriter(url: $0, format: options.format, force: options.force)
        }
        defer { try? writer?.close() }

        if outputURL == nil, options.format == .csv {
            outputLine(MotionSampleFormatter.csvHeader)
        }

        let destination = outputURL?.path ?? "stdout"
        errorLine("Capturing headphone motion for \(display(options.duration)) seconds to \(destination)…")
        var sampleCount = 0
        try await motionCapture.capture(for: options.duration) { [io] sample in
            let line = MotionSampleFormatter.line(for: sample, format: options.format)
            if let writer {
                writer.write(line)
            } else {
                io.writeOutput(line + "\n")
            }
            sampleCount += 1
        }
        errorLine("Captured \(sampleCount) samples.")
    }

    private func runReplay(_ options: ReplayOptions) async throws {
        let inputURL = resolvedURL(for: options.inputPath)
        let samples = try MotionCaptureReader.samples(
            fromFileAt: inputURL, formatHint: options.format)
        guard let first = samples.first, let last = samples.last else {
            throw CLIExecutionError("The capture at \(inputURL.path) contains no samples.")
        }
        let duration = last.timestamp - first.timestamp

        let store = calibrationStore(
            gesturePath: options.gestureProfilePath,
            tapPath: options.tapProfilePath
        )
        let gestureConfig = store.exists(.gesture)
            ? (try? store.loadGesture().config) ?? HeadGestureConfig()
            : HeadGestureConfig()
        let tapConfig = store.exists(.tap)
            ? (try? store.loadTap().config) ?? TapConfig()
            : TapConfig()

        var backends: [(name: String, events: [ReplayEvent])] = [(
            "heuristic",
            ReplayBackendRunner.heuristicEvents(
                samples: samples, gestureConfig: gestureConfig, tapConfig: tapConfig)
        )]
        if let modelPath = options.encoderModelPath {
            guard let motionScorerLoader else {
                throw CLIExecutionError("Encoder replay requires the macOS build of tapq (Core ML is unavailable on this platform).")
            }
            let scorer = try await motionScorerLoader(resolvedURL(for: modelPath))
            backends.append((
                "encoder",
                ReplayBackendRunner.encoderEvents(samples: samples, scorer: scorer)
            ))
        }
        let segments = try options.labelsPath.map {
            try ReplayLabelReader.segments(fromFileAt: resolvedURL(for: $0))
        }

        if options.json {
            try outputReplayJSON(
                input: inputURL.path, sampleCount: samples.count, duration: duration,
                backends: backends, segments: segments, tolerance: options.tolerance)
            return
        }

        let rate = duration > 0 ? Double(samples.count - 1) / duration : 0
        outputLine("Replayed \(samples.count) samples over \(display(duration)) s (\(display(rate)) Hz) from \(inputURL.path).")
        for backend in backends {
            outputLine("")
            outputLine("Backend \(backend.name): \(backend.events.count) event\(backend.events.count == 1 ? "" : "s")")
            for event in backend.events {
                let offset = String(format: "%8.2f", event.time - first.timestamp)
                outputLine("  +\(offset)s  \(event.label.rawValue)")
            }
            if let segments {
                let report = ReplayEvaluator.evaluate(
                    events: backend.events, segments: segments,
                    tolerance: options.tolerance, duration: duration)
                outputLine("  " + pad("label", 12) + lpad("TP", 4) + lpad("FN", 4)
                    + lpad("FP", 4) + "  " + pad("precision", 9) + "  recall")
                for metric in report.metrics {
                    outputLine("  " + pad(metric.label.rawValue, 12)
                        + lpad("\(metric.truePositives)", 4)
                        + lpad("\(metric.falseNegatives)", 4)
                        + lpad("\(metric.falsePositives)", 4)
                        + "  " + pad(displayRatio(metric.precision), 9)
                        + "  " + displayRatio(metric.recall))
                }
                if let perMinute = report.falsePositivesPerMinute {
                    outputLine("  false positives: \(report.falsePositives) (\(display(perMinute))/min)")
                }
            }
        }
    }

    private func outputReplayJSON(
        input: String, sampleCount: Int, duration: TimeInterval,
        backends: [(name: String, events: [ReplayEvent])],
        segments: [ReplayLabelSegment]?, tolerance: TimeInterval
    ) throws {
        struct EventJSON: Encodable {
            let time: Double
            let label: String
        }
        struct MetricJSON: Encodable {
            let label: String
            let truePositives: Int
            let falseNegatives: Int
            let falsePositives: Int
            let precision: Double?
            let recall: Double?
            enum CodingKeys: String, CodingKey {
                case label
                case truePositives = "true_positives"
                case falseNegatives = "false_negatives"
                case falsePositives = "false_positives"
                case precision, recall
            }
        }
        struct BackendJSON: Encodable {
            let name: String
            let events: [EventJSON]
            let metrics: [MetricJSON]?
            let falsePositivesPerMinute: Double?
            enum CodingKeys: String, CodingKey {
                case name, events, metrics
                case falsePositivesPerMinute = "false_positives_per_minute"
            }
        }
        struct ReportJSON: Encodable {
            let input: String
            let samples: Int
            let durationSeconds: Double
            let backends: [BackendJSON]
            enum CodingKeys: String, CodingKey {
                case input, samples, backends
                case durationSeconds = "duration_seconds"
            }
        }

        let report = ReportJSON(
            input: input, samples: sampleCount, durationSeconds: duration,
            backends: backends.map { backend in
                let evaluation = segments.map {
                    ReplayEvaluator.evaluate(
                        events: backend.events, segments: $0,
                        tolerance: tolerance, duration: duration)
                }
                return BackendJSON(
                    name: backend.name,
                    events: backend.events.map {
                        EventJSON(time: $0.time, label: $0.label.rawValue)
                    },
                    metrics: evaluation.map { report in
                        report.metrics.map {
                            MetricJSON(
                                label: $0.label.rawValue,
                                truePositives: $0.truePositives,
                                falseNegatives: $0.falseNegatives,
                                falsePositives: $0.falsePositives,
                                precision: $0.precision,
                                recall: $0.recall)
                        }
                    },
                    falsePositivesPerMinute: evaluation?.falsePositivesPerMinute)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIExecutionError("Could not encode the replay report.")
        }
        outputLine(text)
    }

    private func displayRatio(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "n/a"
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text
            : text + String(repeating: " ", count: width - text.count)
    }

    private func lpad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text
            : String(repeating: " ", count: width - text.count) + text
    }

    private func runCalibration(_ command: CalibrationCommand) async throws {
        switch command {
        case .run(let options): try await runCalibrationSession(options)
        case .show(let options): try showCalibration(options)
        case .reset(let options): try resetCalibration(options)
        }
    }

    private func runCalibrationSession(_ options: CalibrationRunOptions) async throws {
        guard let motionCapture else { throw TapQMotionCaptureError.unavailable }

        var resting: [HeadMotionSample] = []
        var nod: [HeadMotionSample] = []
        var shake: [HeadMotionSample] = []
        var tap: [HeadMotionSample] = []
        let timeline = CalibrationTimeline(options: options)

        errorLine("\(calibrationName(options.target)) calibration will use one continuous \(display(timeline.totalDuration))-second motion session and advance through each phase automatically.")
        errorLine("Quit TapQ and other apps using headphone motion before starting; competing CoreMotion sessions can attenuate or interrupt samples.")
        if !options.nonInteractive {
            io.writeError("Keep the terminal visible and press Return when ready. ")
            guard io.readInput() != nil else {
                throw CLIExecutionError("Input closed before calibration started. Use --non-interactive when running without a terminal.")
            }
        }

        let announcements = calibrationAnnouncements(for: timeline)
        defer { announcements.cancel() }
        let startedAt = monotonicNow()
        try await motionCapture.capture(for: timeline.totalDuration) { [monotonicNow] sample in
            switch timeline.phase(at: monotonicNow() - startedAt) {
            case .resting: resting.append(sample)
            case .nod: nod.append(sample)
            case .shake: shake.append(sample)
            case .tap: tap.append(sample)
            case nil: break
            }
        }

        let samples = GestureCalibrationSamples(
            restingPitch: resting.map(\.pitch),
            restingYaw: resting.map(\.yaw),
            nodPitch: nod.map(\.pitch),
            shakeYaw: shake.map(\.yaw),
            restingAccel: resting.map(\.accelerationMagnitude),
            tapAccel: tap.map(\.accelerationMagnitude)
        )
        let store = calibrationStore(
            gesturePath: options.gestureProfilePath,
            tapPath: options.tapProfilePath
        )
        var failures: [String] = []

        if options.target != .tap {
            let base = (try? store.loadGesture().config) ?? HeadGestureConfig()
            let config = GestureCalibrator.suggestedConfig(from: samples, base: base)
            outputLine("Gesture threshold: \(display(config.amplitudeThreshold)) rad")
            if GestureCalibrator.isUsable(samples) {
                let profile = TapQGestureCalibrationProfile(
                    config: config,
                    quality: GestureCalibrationQuality(
                        restingSampleCount: resting.count,
                        nodSampleCount: nod.count,
                        shakeSampleCount: shake.count
                    )
                )
                try store.save(profile)
                outputLine("Gesture calibration saved to \(store.gestureProfileURL.path)")
            } else {
                failures.append("Gesture calibration was too weak or too close to resting motion. Try again with `tapq calibration run gesture` and make clean, distinct nods and shakes.")
            }
        }

        if options.target != .gesture {
            let assessment = TapCalibrator.assessment(of: samples)
            outputLine("Tap signal peak: \(display(assessment.tapPeak)) g (resting peak \(display(assessment.restingPeak)) g; required \(display(assessment.requiredPeak)) g)")
            if assessment.isUsable {
                let base = (try? store.loadTap().config) ?? TapConfig()
                let config = TapCalibrator.suggestedTapConfig(from: samples, base: base)
                outputLine("Tap threshold: \(display(config.amplitudeThreshold)) g")
                let profile = TapQTapCalibrationProfile(
                    config: config,
                    quality: TapCalibrationQuality(
                        restingSampleCount: resting.count,
                        tapSampleCount: tap.count,
                        restingAccelerationPeak: assessment.restingPeak,
                        tapAccelerationPeak: assessment.tapPeak
                    )
                )
                try store.save(profile)
                outputLine("Tap calibration saved to \(store.tapProfileURL.path)")
            } else {
                failures.append("Tap calibration did not observe an acceleration spike sufficiently separated from resting motion. Keep your head still and give the outside body of an earbud quick fingertip taps—do not squeeze or press the stem. Quit other headphone-motion apps first. Any valid gesture profile was kept; retry only tap with `tapq calibration run tap`.")
            }
        }

        if !failures.isEmpty {
            throw CLIExecutionError(failures.joined(separator: " "))
        }
    }

    private func calibrationAnnouncements(for timeline: CalibrationTimeline) -> Task<Void, Never> {
        Task { @MainActor in
            for stage in timeline.stages {
                guard !Task.isCancelled else { return }
                let verb = stage.phase == nil ? "Waiting" : "Capturing"
                errorLine("\(stage.title): \(stage.instruction) \(verb) for \(display(stage.duration)) seconds…")
                do {
                    try await Task.sleep(nanoseconds: UInt64(stage.duration * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func showCalibration(_ options: CalibrationShowOptions) throws {
        let store = calibrationStore(
            gesturePath: options.gestureProfilePath,
            tapPath: options.tapProfilePath
        )
        let gesture = options.target == .tap || !store.exists(.gesture)
            ? nil
            : try store.loadGesture()
        let tap = options.target == .gesture || !store.exists(.tap)
            ? nil
            : try store.loadTap()
        guard gesture != nil || tap != nil else {
            let paths = options.target.profileKinds.map { store.url(for: $0).path }
                .joined(separator: ", ")
            throw CLIExecutionError("No \(calibrationName(options.target).lowercased()) calibration profile exists at \(paths).")
        }

        if options.json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            switch options.target {
            case .gesture: data = try encoder.encode(gesture)
            case .tap: data = try encoder.encode(tap)
            case .all:
                data = try encoder.encode(CalibrationProfileCollection(
                    gesture: gesture,
                    tap: tap
                ))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIExecutionError("Could not encode the calibration profiles.")
            }
            outputLine(text)
            return
        }

        if let gesture {
            outputLine("Gesture calibration: \(store.gestureProfileURL.path)")
            outputLine("Calibrated: \(ISO8601DateFormatter().string(from: gesture.calibratedAt))")
            outputLine("Gesture threshold: \(display(gesture.config.amplitudeThreshold)) rad")
            outputLine("Samples: rest \(gesture.quality.restingSampleCount), nod \(gesture.quality.nodSampleCount), shake \(gesture.quality.shakeSampleCount)")
        }
        if gesture != nil, tap != nil { outputLine("") }
        if let tap {
            outputLine("Tap calibration: \(store.tapProfileURL.path)")
            outputLine("Calibrated: \(ISO8601DateFormatter().string(from: tap.calibratedAt))")
            outputLine("Tap threshold: \(display(tap.config.amplitudeThreshold)) g")
            outputLine("Observed peak: \(display(tap.quality.tapAccelerationPeak)) g (resting \(display(tap.quality.restingAccelerationPeak)) g)")
            outputLine("Samples: rest \(tap.quality.restingSampleCount), tap \(tap.quality.tapSampleCount)")
        }
    }

    private func resetCalibration(_ options: CalibrationResetOptions) throws {
        let store = calibrationStore(
            gesturePath: options.gestureProfilePath,
            tapPath: options.tapProfilePath
        )
        let existingKinds = options.target.profileKinds.filter(store.exists)
        guard !existingKinds.isEmpty else {
            outputLine("No \(calibrationName(options.target).lowercased()) calibration profile found.")
            return
        }
        if !options.confirmed {
            let paths = existingKinds.map { store.url(for: $0).path }.joined(separator: ", ")
            io.writeError("Remove calibration profile(s) at \(paths)? [y/N] ")
            let response = io.readInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard response == "y" || response == "yes" else {
                outputLine("Calibration profiles kept.")
                return
            }
        }
        for kind in existingKinds {
            _ = try store.reset(kind)
            outputLine("\(kind.rawValue.capitalized) calibration profile removed from \(store.url(for: kind).path).")
        }
    }

    private func runIntegration(_ options: IntegrationOptions) throws {
        switch options {
        case .claude(let options):
            try runClaudeIntegration(options)
        case .codex(let options):
            try runCodexIntegration(options)
        }
    }

    private func runClaudeIntegration(_ options: ClaudeIntegrationOptions) throws {
        let settingsURL = options.settingsPath.map(resolvedURL(for:))
            ?? homeDirectory.appendingPathComponent(".claude/settings.json")
        let hookURL = options.hookPath.map(resolvedURL(for:))
            ?? executableURL.deletingLastPathComponent().appendingPathComponent("tapq-hook")
        let installer = HookInstaller(
            settingsURL: settingsURL,
            hookCommand: hookURL.path,
            policy: options.permissionPolicy
        )

        switch options.action {
        case .install:
            guard FileManager.default.isExecutableFile(atPath: hookURL.path) else {
                throw CLIExecutionError("Hook executable not found or not executable at \(hookURL.path). Install it beside tapq or pass --hook PATH.")
            }
            try installer.install()
            outputLine("Claude Code integration installed in \(settingsURL.path).")
            outputLine("Hook: \(hookURL.path)")
            outputLine("Permission policy: \(options.permissionPolicy.rawValue)")
            warnIfNativeBypassesTapQ(policy: options.permissionPolicy, settingsURL: settingsURL)
            outputLine("Start the hands-free runtime with `tapq serve`.")
        case .status:
            switch installer.installationStatus() {
            case .strict:
                outputLine("Claude Code integration: installed")
                outputLine("Settings: \(settingsURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Permission policy: strict")
            case .native:
                outputLine("Claude Code integration: installed")
                outputLine("Settings: \(settingsURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Permission policy: native")
                warnIfNativeBypassesTapQ(policy: .native, settingsURL: settingsURL)
            case .partial:
                outputLine("Claude Code integration: incomplete")
                outputLine("Settings: \(settingsURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Re-run `tapq integration claude install --permission-policy strict` or choose native to repair it.")
            case .notInstalled:
                outputLine("Claude Code integration: not installed")
            }
        case .uninstall:
            try installer.uninstall()
            outputLine("Claude Code integration removed from \(settingsURL.path).")
        }
    }

    private func runCodexIntegration(_ options: CodexIntegrationOptions) throws {
        let hooksURL = options.hooksPath.map(resolvedURL(for:)) ?? defaultCodexHooksURL
        let hookURL = options.hookPath.map(resolvedURL(for:))
            ?? executableURL.deletingLastPathComponent().appendingPathComponent("tapq-codex-hook")
        let installer = CodexHookInstaller(
            hooksURL: hooksURL,
            hookCommand: hookURL.path
        )

        switch options.action {
        case .install:
            guard FileManager.default.isExecutableFile(atPath: hookURL.path) else {
                throw CLIExecutionError(
                    "Hook executable not found or not executable at \(hookURL.path). "
                    + "Install it beside tapq or pass --hook PATH."
                )
            }
            let report = try installer.install()
            outputLine("Codex integration configured in \(hooksURL.path).")
            outputLine("Hook: \(hookURL.path)")
            outputLine("Permission policy: native Codex prompts")
            if let trustMessage = report.trustAction.message {
                outputLine(trustMessage)
            }
            outputLine("Start the hands-free runtime with `tapq serve`.")
        case .status:
            switch installer.installationStatus() {
            case .installed:
                outputLine("Codex integration: configured")
                outputLine("Hooks: \(hooksURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Trust: verify in Codex with `/hooks`")
            case .partial:
                outputLine("Codex integration: incomplete")
                outputLine("Hooks: \(hooksURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Re-run `tapq integration codex install` to repair it, then trust it with `/hooks`.")
            case .notInstalled:
                outputLine("Codex integration: not installed")
            }
        case .uninstall:
            try installer.uninstall()
            outputLine("Codex integration removed from \(hooksURL.path).")
            outputLine("Open `/hooks` in Codex to confirm the hook is no longer listed.")
        }
    }

    private var defaultCodexHooksURL: URL {
        if let path = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return resolvedURL(for: path).appendingPathComponent("hooks.json")
        }
        return homeDirectory.appendingPathComponent(".codex/hooks.json")
    }

    private func warnIfNativeBypassesTapQ(
        policy: ClaudePermissionPolicy,
        settingsURL: URL
    ) {
        guard policy == .native,
              configuredClaudePermissionMode(at: settingsURL) == "bypasspermissions" else {
            return
        }
        errorLine(
            "warning: Claude Code defaults to bypassPermissions; native policy will receive "
            + "only dialogs Claude still chooses to show. Use strict policy for TapQ approval "
            + "of ordinary tool calls."
        )
    }

    private func configuredClaudePermissionMode(at settingsURL: URL) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return nil
        }
        return root["permissions"]?["defaultMode"]?.stringValue?.lowercased()
    }

    private func calibrationStore(
        gesturePath: String?,
        tapPath: String?
    ) -> CalibrationStore {
        let defaults = CalibrationStore.defaultStore(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return CalibrationStore(
            gestureProfileURL: gesturePath.map(resolvedURL(for:))
                ?? defaults.gestureProfileURL,
            tapProfileURL: tapPath.map(resolvedURL(for:))
                ?? defaults.tapProfileURL
        )
    }

    private func calibrationName(_ target: CalibrationTarget) -> String {
        switch target {
        case .all: "Gesture and tap"
        case .gesture: "Gesture"
        case .tap: "Tap"
        }
    }

    private func resolvedURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return currentDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private func outputLine(_ text: String) {
        io.writeOutput(text + "\n")
    }

    private func errorLine(_ text: String) {
        io.writeError(text + "\n")
    }

    private func display(_ value: Double) -> String {
        String(format: "%.3g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func help(for topic: CLIHelpTopic) -> String {
        switch topic {
        case .root: return rootHelp
        case .serve: return serveHelp
        case .capture: return captureHelp
        case .replay: return replayHelp
        case .calibration: return calibrationHelp
        case .integration: return integrationHelp
        }
    }

    private static let rootHelp = """
    TapQ command-line interface

    USAGE
      tapq <command> [options]

    COMMANDS
      calibration   Run, inspect, or reset AirPods calibration
      calibrate     Shortcut for `tapq calibration run`
      capture       Capture raw headphone motion as JSONL or CSV
      replay        Replay a motion capture through detection backends offline
      serve         Run the local agent-agnostic TapQ broker
      integration   Manage agent integrations
      version       Print the TapQ CLI version

    Run `tapq help <command>` for command-specific usage.
    """

    private static let serveHelp = """
    Run TapQ's headless local broker and hands-free interaction runtime.

    USAGE
      tapq serve [options]

    OPTIONS
      --broker-dir PATH        Override the runtime discovery/socket directory
      --gesture-profile PATH   Override the gesture calibration profile
      --tap-profile PATH       Override the tap calibration profile
      --timeout SECONDS        Per-listen input timeout (default: 240; values are capped at 240)
      --no-voice               Disable microphone speech recognition
      --speech-voice VOICE     Voice for spoken output: a language tag (en-US, zh-CN) or
                               a system voice identifier (default: en-US, also settable
                               with TAPQ_SPEECH_VOICE). Unset, macOS picks the voice from
                               the system language regardless of what TapQ says, which
                               garbles the readout on a non-English Mac. This selects the
                               voice only — TapQ's own prompts are English either way.
      --no-announcements       Disable non-blocking agent status announcements
      --steering               Ask supported adapters to prefer structured questions
      --question-classifier P  Use auto, apple, anthropic, openai, or local (default: auto)
      --encoder-model PATH     Load a TapQ-1 encoder model (.mlpackage or .mlmodelc)
      --encoder-mode MODE      shadow (default) records encoder detections as
                               diagnostics only; primary lets the encoder drive events.
                               If the model fails to load, serving continues on the
                               deterministic heuristics.
      --reasoner PROVIDER      Stage-2 risk reasoner: off (default) or apple, Apple's
                               on-device model
      --reasoner-mode MODE     shadow (default) observes and logs decisions only;
                               primary lets them strengthen confirmation requirements.
                               A reasoner can only ask for more confirmation — never
                               approve, deny, or resolve a request. Requires --reasoner;
                               if the model is unavailable, serving continues without
                               risk escalation.

    The broker is agent-neutral. Install each agent's adapter separately with
    `tapq integration claude install` or `tapq integration codex install`.
    """

    private static let captureHelp = """
    Capture raw headphone motion. Hardware acquisition currently requires macOS and compatible AirPods.

    USAGE
      tapq capture [--duration SECONDS] [--format jsonl|csv] [--output PATH|-] [--force]

    OPTIONS
      --duration SECONDS   Capture duration (default: 10)
      --format FORMAT      jsonl (default) or csv
      --output, -o PATH    Output file, or - for stdout (default: -)
      --force, -f          Replace an existing output file
    """

    private static let replayHelp = """
    Replay a recorded motion capture through TapQ's detection backends, entirely
    offline. With a label file, reports per-gesture precision/recall and false
    positives per minute — the yardstick for tuning and for comparing the heuristic
    baseline against a TapQ-1 encoder model.

    USAGE
      tapq replay --input PATH [options]

    OPTIONS
      --input, -i PATH         Capture file from `tapq capture` (jsonl or csv)
      --labels PATH            JSONL label segments: {"start": s, "end": s, "label": l}
                               using the capture's own timestamps. Labels mark the full
                               command (a `nod` segment spans the complete double nod,
                               `shake` the complete double shake): nod, shake, tilt_left,
                               tilt_right, tap, swipe_up, swipe_down
      --format jsonl|csv       Override capture format auto-detection
      --tolerance SECONDS      Grace period after a segment's end in which its event may
                               still fire (default: 1.0)
      --encoder-model PATH     Also replay through a TapQ-1 encoder model (macOS only)
      --gesture-profile PATH   Use a calibrated gesture profile instead of defaults
      --tap-profile PATH       Use a calibrated tap profile instead of defaults
      --json                   Emit the report as JSON

    Swipe detection is enabled during replay even though it ships disabled live, so
    experimental channels can be evaluated from the same recordings.
    """

    private static let calibrationHelp = """
    Calibrate gesture and tap thresholds as independent profiles without retaining raw motion samples.

    USAGE
      tapq calibration run [all|gesture|tap] [options]
      tapq calibrate [all|gesture|tap] [options]
      tapq calibration show [all|gesture|tap] [--json] [profile options]
      tapq calibration reset [all|gesture|tap] [--yes] [profile options]

    RUN OPTIONS
      --rest-seconds N     Resting phase duration (default: 3)
      --nod-seconds N      Nod phase duration (default: 4)
      --shake-seconds N    Shake phase duration (default: 4)
      --tap-seconds N      Tap phase duration (default: 4)
      --non-interactive    Start without waiting for the initial Return prompt

    PROFILE OPTIONS
      --profile PATH           Override the selected gesture or tap profile path
      --gesture-profile PATH   Override the gesture profile path
      --tap-profile PATH       Override the tap profile path

    A full run saves each usable profile immediately. If one phase fails, rerun only that
    target; for example, `tapq calibration run tap` does not repeat nod and shake.
    """

    private static let integrationHelp = """
    Manage TapQ's Claude Code and Codex hook integrations.

    USAGE
      tapq integration claude install [--permission-policy strict|native] [--settings PATH] [--hook PATH]
      tapq integration claude status [--settings PATH] [--hook PATH]
      tapq integration claude uninstall [--settings PATH] [--hook PATH]
      tapq integration codex install [--hooks PATH] [--hook PATH]
      tapq integration codex status [--hooks PATH] [--hook PATH]
      tapq integration codex uninstall [--hooks PATH] [--hook PATH]

    By default, the settings file is ~/.claude/settings.json and the hook executable is
    the `tapq-hook` binary installed beside `tapq`. The hook connects to a
    running `tapq serve` process and otherwise fails through to Claude Code's normal flow.

    `strict` is the default permission policy and preserves TapQ's PreToolUse approval
    behavior. `native` handles only PermissionRequest dialogs Claude would normally show,
    leaving recognized read-only Bash commands uninterrupted. Re-run install with the other
    policy to switch without changing unrelated Claude settings or hooks.

    Codex uses native PermissionRequest and Stop lifecycle hooks from ~/.codex/hooks.json
    (or $CODEX_HOME/hooks.json). After installation, open `/hooks` in Codex and trust the
    exact TapQ hook definition. Codex skips new or changed non-managed hooks until trusted.
    """
}

private struct CalibrationProfileCollection: Encodable {
    let gesture: TapQGestureCalibrationProfile?
    let tap: TapQTapCalibrationProfile?
}

private struct CLIExecutionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
