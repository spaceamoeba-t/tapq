import Foundation
import TapQClaudeAdapter
import TapQCodexAdapter
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol

public enum TapQVersion {
    public static let current = "0.4.0-beta.1"
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
    /// Microphone arm of the capture study, used only by `capture --mic-envelope`. nil on
    /// hosts without an audio adapter, which the flag then reports as unavailable rather
    /// than capturing motion with a silently missing label track.
    private let envelopeCapture: (any TapQAudioEnvelopeCapturing)?
    private let runtimeService: (any TapQRuntimeServing)?
    /// Loads a TapQ-1 model into a window scorer for `tapq replay --encoder-model`.
    /// nil on platforms without a Core ML host (the flag then reports unavailability).
    private let motionScorerLoader: ((URL) async throws -> any MotionWindowScoring)?
    /// Builds the stage-2 reasoner for `tapq serve --reasoner`. nil on platforms without
    /// a model backend, which the runtime reports as an unavailable reasoner and serves
    /// through — the same shape as `motionScorerLoader`, handed to the runtime host.
    private let reasonerLoader: TapQReasonerLoading?
    /// Builds the stage-2 reasoner `tapq bench reasoner` measures. Separate from
    /// `reasonerLoader` because the two answer to unavailability in opposite ways: serve
    /// degrades to no reasoner, bench fails. Keeping them apart also lets a test inject a
    /// scripted backend for one command without changing the other.
    private let benchReasonerLoader: TapQReasonerLoading?
    private let environment: [String: String]
    private let homeDirectory: URL
    private let executableURL: URL
    private let currentDirectory: URL
    private let monotonicNow: () -> TimeInterval
    private let codexCLICommandRunner: ([String]) -> CodexCLICommandResult
    private let codexCLIExecutablePath: String?
    private let codexCLIExecutableWasResolved: Bool

    public init(
        io: TapQCLIIO = .live,
        motionCapture: (any TapQMotionCapturing)? = nil,
        envelopeCapture: (any TapQAudioEnvelopeCapturing)? = nil,
        runtimeService: (any TapQRuntimeServing)? = nil,
        motionScorerLoader: ((URL) async throws -> any MotionWindowScoring)? = nil,
        reasonerLoader: TapQReasonerLoading? = nil,
        benchReasonerLoader: TapQReasonerLoading? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        codexCLICommandRunner: (([String]) -> CodexCLICommandResult)? = nil,
        codexCLIResolvedExecutableURL: URL? = nil
    ) {
        self.io = io
        self.motionCapture = motionCapture
        self.envelopeCapture = envelopeCapture
        self.runtimeService = runtimeService
        self.motionScorerLoader = motionScorerLoader
        self.reasonerLoader = reasonerLoader
        self.benchReasonerLoader = benchReasonerLoader
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL
        self.currentDirectory = currentDirectory
        self.monotonicNow = monotonicNow
        if let codexCLICommandRunner {
            self.codexCLICommandRunner = codexCLICommandRunner
            self.codexCLIExecutablePath = codexCLIResolvedExecutableURL?.path
            self.codexCLIExecutableWasResolved = true
        } else if let runner = CodexCLIProcessRunner.resolve(
                environment: environment,
                currentDirectory: currentDirectory
        ) {
            self.codexCLICommandRunner = runner.run(arguments:)
            self.codexCLIExecutablePath = runner.executableURL.path
            self.codexCLIExecutableWasResolved = true
        } else {
            self.codexCLICommandRunner = { _ in .unavailable }
            self.codexCLIExecutablePath = nil
            self.codexCLIExecutableWasResolved = false
        }
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
        } catch let error as TapQEnvelopeCaptureError {
            errorLine("error: \(error.localizedDescription)")
            // A truncated track is a failed run but not an unavailable service: the
            // recording exists and the operator has to decide whether to keep it.
            if case .invalidated = error { return 1 }
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
        case .bench(let options):
            try await runBench(options)
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
            voiceBackend: options.voiceBackend,
            encoderModelURL: options.encoderModelPath.map(resolvedURL(for:)),
            encoderMode: options.encoderModelPath == nil ? .off : options.encoderMode,
            reasonerProvider: options.reasonerProvider,
            reasonerMode: options.reasonerProvider == .off ? .off : options.reasonerMode,
            wearerGateEnabled: options.wearerGateEnabled
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
            if let voiceBackendStatus = endpoint.voiceBackendStatus {
                io.writeOutput("Voice backend: \(voiceBackendStatus)\n")
            }
            if let encoderStatus = endpoint.encoderStatus {
                io.writeOutput("TapQ-1 encoder: \(encoderStatus)\n")
            }
            if let reasonerStatus = endpoint.reasonerStatus {
                io.writeOutput("Stage-2 reasoner: \(reasonerStatus)\n")
            }
            if let wearerSpeechStatus = endpoint.wearerSpeechStatus {
                io.writeOutput("Wearer speech: \(wearerSpeechStatus)\n")
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

        // Fail-closed: a study recording whose label track never opened is worthless, and
        // that has to be discovered before the wearer performs the session, not after. So
        // the sidecar is opened and the microphone started ahead of the IMU stream, and
        // any failure aborts with nothing captured.
        let recorder = try options.micEnvelopePath.map { path -> EnvelopeSidecarRecorder in
            guard envelopeCapture != nil else { throw TapQEnvelopeCaptureError.unavailable }
            return try EnvelopeSidecarRecorder(
                url: resolvedURL(for: path), force: options.force)
        }
        defer { recorder?.close() }

        var envelopeFailure: TapQEnvelopeCaptureError?
        if let recorder, let envelopeCapture {
            try envelopeCapture.start(
                onTrack: { recorder.writeTrack($0) },
                onSample: { recorder.append($0) },
                onInvalidation: { failure in
                    // Recorded rather than thrown: the IMU capture in flight is still
                    // worth finishing and writing, and the exit code carries the failure.
                    envelopeFailure = envelopeFailure ?? failure
                }
            )
            errorLine("Co-recording a microphone envelope to \(recorder.url.path)…")
        }
        defer { if recorder != nil { envelopeCapture?.stop() } }

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
        if let recorder {
            envelopeCapture?.stop()
            errorLine("Captured \(recorder.sampleCount) microphone envelope blocks.")
        }
        if let envelopeFailure { throw envelopeFailure }
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
            tapPath: options.tapProfilePath,
            wearerSpeechPath: options.wearerSpeechProfilePath
        )
        let gestureConfig = store.exists(.gesture)
            ? (try? store.loadGesture().config) ?? HeadGestureConfig()
            : HeadGestureConfig()
        let tapConfig = store.exists(.tap)
            ? (try? store.loadTap().config) ?? TapConfig()
            : TapConfig()
        let wearerSpeechConfig = store.exists(.wearerSpeech)
            ? (try? store.loadWearerSpeech().config) ?? WearerSpeechConfig()
            : WearerSpeechConfig()

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
        let partition = try options.labelsPath.map {
            try ReplaySpeechLabelReader.partition(fromFileAt: resolvedURL(for: $0))
        }
        let segments = partition?.events
        let wearerSpeech = try wearerSpeechReport(
            samples: samples,
            config: wearerSpeechConfig,
            labeled: partition?.speech ?? [],
            envelopePath: options.micEnvelopePath,
            tolerance: options.tolerance,
            duration: duration
        )

        if options.json {
            try outputReplayJSON(
                input: inputURL.path, sampleCount: samples.count, duration: duration,
                backends: backends, segments: segments, tolerance: options.tolerance,
                wearerSpeech: wearerSpeech)
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

        if let wearerSpeech { outputWearerSpeechSection(wearerSpeech) }
    }

    /// Runs the wearer-speech detector over the capture and scores it, or returns nil when
    /// the replay has no speech ground truth — in which case the report keeps exactly the
    /// shape it had before wearer speech existed.
    ///
    /// Labels beat the envelope sidecar: a human marking spans is the better truth, and a
    /// study that supplies both is nearly always re-scoring a corrected label file against
    /// the recording it was derived from.
    private func wearerSpeechReport(
        samples: [HeadMotionSample],
        config: WearerSpeechConfig,
        labeled: [ReplaySpeechSegment],
        envelopePath: String?,
        tolerance: TimeInterval,
        duration: TimeInterval
    ) throws -> WearerSpeechReplayReport? {
        let truth: [ReplaySpeechSegment]
        let source: WearerSpeechTruthSource
        if !labeled.isEmpty {
            if envelopePath != nil {
                errorLine("Both wearer_speech labels and --mic-envelope were supplied; scoring against the labels.")
            }
            truth = labeled
            source = .labels
        } else if let envelopePath {
            let track = try EnvelopeTrackReader.track(
                fromFileAt: resolvedURL(for: envelopePath))
            truth = EnvelopeLabelDeriver.segments(from: track)
            source = .micEnvelope
        } else {
            return nil
        }

        let detected = WearerSpeechReplayRunner.intervals(samples: samples, config: config)
        return WearerSpeechReplayReport(
            truthSource: source,
            metrics: SpeechIntervalEvaluator.evaluate(
                detected: detected, truth: truth,
                frameTimes: samples.map(\.timestamp),
                tolerance: tolerance, duration: duration
            )
        )
    }

    private func outputWearerSpeechSection(_ report: WearerSpeechReplayReport) {
        let metrics = report.metrics
        outputLine("")
        outputLine("Wearer speech (truth: \(report.truthSource.rawValue)): "
            + "\(metrics.detectedSegments) detected, \(metrics.truthSegments) labeled")
        outputLine("  " + pad("frames", 8) + lpad("TP", 6) + lpad("FP", 6) + lpad("FN", 6)
            + "  " + pad("precision", 9) + "  " + pad("recall", 9) + "  f1")
        outputLine("  " + pad("", 8)
            + lpad("\(metrics.framesTruePositive)", 6)
            + lpad("\(metrics.framesFalsePositive)", 6)
            + lpad("\(metrics.framesFalseNegative)", 6)
            + "  " + pad(displayRatio(metrics.precision), 9)
            + "  " + pad(displayRatio(metrics.recall), 9)
            + "  " + displayRatio(metrics.f1))
        outputLine("  onset latency: \(displaySeconds(metrics.onsetLatencyMeanSeconds)) s "
            + "(mean over \(metrics.matchedSegments) matched)")
        if let perMinute = metrics.falseActivationsPerMinute {
            outputLine("  false activations: \(metrics.falseActivations) "
                + "(\(display(perMinute))/min)")
        } else {
            outputLine("  false activations: \(metrics.falseActivations)")
        }
    }

    private func outputReplayJSON(
        input: String, sampleCount: Int, duration: TimeInterval,
        backends: [(name: String, events: [ReplayEvent])],
        segments: [ReplayLabelSegment]?, tolerance: TimeInterval,
        wearerSpeech: WearerSpeechReplayReport?
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
        /// Absent — not null — when the replay had no speech ground truth, so a report
        /// without the new flags encodes exactly the keys it always did.
        struct WearerSpeechJSON: Encodable {
            let truthSource: String
            let framePrecision: Double?
            let frameRecall: Double?
            let f1: Double?
            let onsetLatencyMeanSeconds: Double?
            let falseActivations: Int
            let falseActivationsPerMinute: Double?
            let detectedIntervals: Int
            let truthIntervals: Int
            let matchedIntervals: Int
            enum CodingKeys: String, CodingKey {
                case f1
                case truthSource = "truth_source"
                case framePrecision = "frame_precision"
                case frameRecall = "frame_recall"
                case onsetLatencyMeanSeconds = "onset_latency_mean_seconds"
                case falseActivations = "false_activations"
                case falseActivationsPerMinute = "false_activations_per_minute"
                case detectedIntervals = "detected_intervals"
                case truthIntervals = "truth_intervals"
                case matchedIntervals = "matched_intervals"
            }
        }
        struct ReportJSON: Encodable {
            let input: String
            let samples: Int
            let durationSeconds: Double
            let backends: [BackendJSON]
            let wearerSpeech: WearerSpeechJSON?
            enum CodingKeys: String, CodingKey {
                case input, samples, backends
                case durationSeconds = "duration_seconds"
                case wearerSpeech = "wearer_speech"
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
            },
            wearerSpeech: wearerSpeech.map { report in
                WearerSpeechJSON(
                    truthSource: report.truthSource.rawValue,
                    framePrecision: report.metrics.precision,
                    frameRecall: report.metrics.recall,
                    f1: report.metrics.f1,
                    onsetLatencyMeanSeconds: report.metrics.onsetLatencyMeanSeconds,
                    falseActivations: report.metrics.falseActivations,
                    falseActivationsPerMinute: report.metrics.falseActivationsPerMinute,
                    detectedIntervals: report.metrics.detectedSegments,
                    truthIntervals: report.metrics.truthSegments,
                    matchedIntervals: report.metrics.matchedSegments)
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

    private func runBench(_ options: BenchOptions) async throws {
        let scenariosURL = resolvedURL(for: options.scenariosPath)
        let corpus = try BenchScenarioReader.scenarios(fromFileAt: scenariosURL)
        guard !corpus.isEmpty else {
            throw CLIExecutionError(
                "The scenario corpus at \(scenariosURL.path) contains no scenarios.")
        }
        let scenarios = options.limit.map { Array(corpus.prefix($0)) } ?? corpus
        let config = ReasonerConfig()
        let reasoner = try await benchReasoner(
            provider: options.reasonerProvider, config: config)

        errorLine("Benching \(scenarios.count) scenario\(scenarios.count == 1 ? "" : "s") "
            + "from \(scenariosURL.path) through the "
            + "\(options.reasonerProvider.rawValue) reasoner…")
        // Each scenario is reported as it finishes: a full corpus is minutes of on-device
        // inference, and minutes of silence are indistinguishable from a hang.
        let outcomes = await ReasonerBenchRunner.run(
            scenarios: scenarios, reasoner: reasoner, config: config
        ) { index, outcome in
            errorLine("  " + lpad("\(index + 1)", 4) + "/\(scenarios.count)  "
                + pad(outcome.scenario.id, 7)
                + pad(outcome.emittedTier?.rawValue ?? "abstained", 12)
                + lpad(displaySeconds(outcome.latencySeconds), 7) + " s")
        }

        let report = ReasonerBenchEvaluator.evaluate(outcomes)
        if options.json {
            try outputBenchJSON(
                report,
                corpus: scenariosURL.path,
                provider: options.reasonerProvider
            )
            return
        }
        outputBenchReport(
            report, corpus: scenariosURL.path, provider: options.reasonerProvider)
    }

    /// Builds the reasoner a bench run measures, or fails the command.
    ///
    /// Deliberately the opposite of `runServe`, which hands the loader to a runtime that
    /// degrades to no reasoner: a missing reasoner can only mean "no escalation", so
    /// serving through one is safe. A bench run has nothing to measure without a live
    /// model — 150 abstentions would print as a report and read as a result — so an
    /// unavailable backend is an error here, not a degradation.
    private func benchReasoner(
        provider: ReasonerProvider,
        config: ReasonerConfig
    ) async throws -> any ContextReasoning {
        guard let benchReasonerLoader else {
            throw benchReasonerUnavailable(.unsupportedPlatform, provider: provider)
        }
        do {
            // A no-op sink for now: the report gives the abstention *rate*, and the
            // per-reason breakdown (timeout, guardrail, unreadable output) is exactly what
            // a backend records here, so a later packet that wants it collects this sink
            // rather than changing the runner.
            return try await benchReasonerLoader(config, NoOpTapQDiagnosticSink())
        } catch let error as TapQReasonerUnavailableError {
            throw benchReasonerUnavailable(error, provider: provider)
        } catch {
            throw CLIExecutionError(
                "Could not build the \(provider.rawValue) reasoner: "
                + "\(error.localizedDescription)")
        }
    }

    private func benchReasonerUnavailable(
        _ error: TapQReasonerUnavailableError,
        provider: ReasonerProvider
    ) -> CLIExecutionError {
        CLIExecutionError(
            "The \(provider.rawValue) reasoner is unavailable "
            + "(\(error.localizedDescription)). bench measures a live model, so it stops "
            + "here rather than scoring a run of abstentions.")
    }

    private func outputBenchReport(
        _ report: BenchReport,
        corpus: String,
        provider: ReasonerProvider
    ) {
        outputLine("Benched \(report.scenarioCount) scenario"
            + "\(report.scenarioCount == 1 ? "" : "s") from \(corpus) "
            + "through the \(provider.rawValue) reasoner.")
        outputLine("Decisions \(report.decisionCount), "
            + "abstentions \(report.abstentionCount).")

        outputLine("")
        outputLine("CONFUSION (row = expected, column = emitted)")
        outputLine(pad("expected", 14) + lpad("routine", 9) + lpad("sensitive", 11)
            + lpad("destructive", 13) + lpad("abstain", 9) + lpad("total", 7))
        for row in report.confusion {
            outputLine(pad(row.expected.rawValue, 14)
                + lpad("\(row.routine)", 9)
                + lpad("\(row.sensitive)", 11)
                + lpad("\(row.destructive)", 13)
                + lpad("\(row.abstained)", 9)
                + lpad("\(row.total)", 7))
        }

        outputLine("")
        outputLine("PER TIER")
        outputLine(pad("tier", 14) + lpad("expected", 9) + lpad("emitted", 9)
            + lpad("hits", 6) + lpad("abstain", 9) + lpad("precision", 11)
            + lpad("recall", 8))
        for metric in report.tierMetrics {
            outputLine(pad(metric.tier.rawValue, 14)
                + lpad("\(metric.expected)", 9)
                + lpad("\(metric.emitted)", 9)
                + lpad("\(metric.hits)", 6)
                + lpad("\(metric.abstained)", 9)
                + lpad(displayRatio(metric.precision), 11)
                + lpad(displayRatio(metric.recall), 8))
        }
        outputLine("Routine recall credits abstentions; sensitive and destructive recall")
        outputLine("count them as misses (bench/README.md).")

        outputLine("")
        outputLine("HEADLINE")
        outputLine(benchHeadline("destructive recall", report.destructiveRecall,
            detail: benchFraction(report.metrics(for: .destructive))))
        outputLine(benchHeadline("sensitive recall", report.sensitiveRecall,
            detail: benchFraction(report.metrics(for: .sensitive))))
        outputLine(benchHeadline("benign false escalation", report.benignFalseEscalationRate,
            detail: "\(report.benignFalseEscalationCount)/\(report.routineExpectedCount) "
                + "expected-routine rows"))
        outputLine(pad("escalated above expected", 26)
            + lpad("\(report.escalationsAboveExpected)", 6)
            + "  rows, any expected tier")
        outputLine(pad("under escalation", 26)
            + lpad("\(report.underEscalationCount)", 6)
            + "  rows below the expected tier")
        outputLine(benchHeadline("code in set", report.codeInSetRate,
            detail: "\(report.codeInSetCount)/\(report.codeCheckedCount) non-routine decisions"))
        outputLine(benchHeadline("abstain rate", report.abstainRate,
            detail: "\(report.abstentionCount)/\(report.scenarioCount)"))
        outputLine(pad("latency p50 / p95", 26)
            + lpad(displaySeconds(report.latencyP50Seconds), 6) + " s / "
            + displaySeconds(report.latencyP95Seconds) + " s")

        outputLine("")
        outputLine("PER CATEGORY")
        outputLine(pad("category", 23) + lpad("n", 5) + lpad("hits", 6)
            + lpad("abstain", 9) + lpad("above", 7) + lpad("below", 7))
        for metric in report.categoryMetrics {
            outputLine(pad(metric.category.rawValue, 23)
                + lpad("\(metric.count)", 5)
                + lpad("\(metric.tierHits)", 6)
                + lpad("\(metric.abstained)", 9)
                + lpad("\(metric.overEscalated)", 7)
                + lpad("\(metric.underEscalated)", 7))
        }

        // Ids, not counts: this is the hook back into the corpus, and every one of these
        // rows is a labeled line someone can read and argue with.
        outputLine("")
        outputLine("WORST OFFENDERS")
        outputBenchOffenders("missed destructive", report.missedDestructive)
        outputBenchOffenders(
            "benign false escalation (expected-routine rows)", report.benignFalseEscalations)
        outputBenchOffenders("code miss", report.codeMisses)
    }

    private func outputBenchOffenders(_ title: String, _ offenders: [BenchOffender]) {
        guard !offenders.isEmpty else {
            outputLine("\(title): none")
            return
        }
        let shown = offenders.prefix(Self.benchOffenderLimit)
        let suffix = offenders.count > shown.count
            ? " (showing \(shown.count) of \(offenders.count))"
            : " (\(offenders.count))"
        outputLine(title + suffix)
        for offender in shown {
            let line = "  " + pad(offender.id, 7) + pad(offender.category.rawValue, 23)
                + pad(offender.emittedTier?.rawValue ?? "abstained", 12)
                + (offender.emittedCode?.rawValue ?? "")
            outputLine(line.replacingOccurrences(
                of: " +$", with: "", options: .regularExpression))
        }
    }

    private func benchHeadline(_ label: String, _ value: Double?, detail: String) -> String {
        pad(label, 26) + lpad(displayRatio(value), 6) + "  (\(detail))"
    }

    private func benchFraction(_ metric: BenchTierMetrics?) -> String {
        guard let metric else { return "no rows" }
        return "\(metric.hits)/\(metric.expected)"
    }

    private func outputBenchJSON(
        _ report: BenchReport,
        corpus: String,
        provider: ReasonerProvider
    ) throws {
        struct TierJSON: Encodable {
            let tier: String
            let expected: Int
            let emitted: Int
            let hits: Int
            let abstained: Int
            let precision: Double?
            let recall: Double?
        }
        struct ConfusionJSON: Encodable {
            let expected: String
            let routine: Int
            let sensitive: Int
            let destructive: Int
            let abstained: Int
        }
        struct CategoryJSON: Encodable {
            let category: String
            let count: Int
            let tierHits: Int
            let abstained: Int
            let overEscalated: Int
            let underEscalated: Int
            enum CodingKeys: String, CodingKey {
                case category, count, abstained
                case tierHits = "tier_hits"
                case overEscalated = "over_escalated"
                case underEscalated = "under_escalated"
            }
        }
        struct OffenderJSON: Encodable {
            let id: String
            let category: String
            let expectedTier: String
            let emittedTier: String?
            let emittedCode: String?
            enum CodingKeys: String, CodingKey {
                case id, category
                case expectedTier = "expected_tier"
                case emittedTier = "emitted_tier"
                case emittedCode = "emitted_code"
            }
        }
        struct ReportJSON: Encodable {
            let corpus: String
            let reasoner: String
            let scenarios: Int
            let decisions: Int
            let abstentions: Int
            let abstainRate: Double?
            let tiers: [TierJSON]
            let confusion: [ConfusionJSON]
            let categories: [CategoryJSON]
            let destructiveRecall: Double?
            let sensitiveRecall: Double?
            let routineExpected: Int
            let escalationsAboveExpected: Int
            let benignFalseEscalationCount: Int
            let benignFalseEscalationRate: Double?
            let underEscalationCount: Int
            let codeCheckedCount: Int
            let codeInSetCount: Int
            let codeInSetRate: Double?
            let latencyP50Seconds: Double?
            let latencyP95Seconds: Double?
            let missedDestructive: [OffenderJSON]
            let benignFalseEscalations: [OffenderJSON]
            let codeMisses: [OffenderJSON]
            enum CodingKeys: String, CodingKey {
                case corpus, reasoner, scenarios, decisions, abstentions
                case tiers, confusion, categories
                case abstainRate = "abstain_rate"
                case destructiveRecall = "destructive_recall"
                case sensitiveRecall = "sensitive_recall"
                case routineExpected = "routine_expected"
                case escalationsAboveExpected = "escalations_above_expected"
                case benignFalseEscalationCount = "benign_false_escalation_count"
                case benignFalseEscalationRate = "benign_false_escalation_rate"
                case underEscalationCount = "under_escalation_count"
                case codeCheckedCount = "code_checked_count"
                case codeInSetCount = "code_in_set_count"
                case codeInSetRate = "code_in_set_rate"
                case latencyP50Seconds = "latency_p50_seconds"
                case latencyP95Seconds = "latency_p95_seconds"
                case missedDestructive = "missed_destructive"
                case benignFalseEscalations = "benign_false_escalations"
                case codeMisses = "code_misses"
            }
        }

        func offenders(_ list: [BenchOffender]) -> [OffenderJSON] {
            list.map {
                OffenderJSON(
                    id: $0.id,
                    category: $0.category.rawValue,
                    expectedTier: $0.expectedTier.rawValue,
                    emittedTier: $0.emittedTier?.rawValue,
                    emittedCode: $0.emittedCode?.rawValue
                )
            }
        }

        let payload = ReportJSON(
            corpus: corpus,
            reasoner: provider.rawValue,
            scenarios: report.scenarioCount,
            decisions: report.decisionCount,
            abstentions: report.abstentionCount,
            abstainRate: report.abstainRate,
            tiers: report.tierMetrics.map {
                TierJSON(
                    tier: $0.tier.rawValue, expected: $0.expected, emitted: $0.emitted,
                    hits: $0.hits, abstained: $0.abstained,
                    precision: $0.precision, recall: $0.recall)
            },
            confusion: report.confusion.map {
                ConfusionJSON(
                    expected: $0.expected.rawValue, routine: $0.routine,
                    sensitive: $0.sensitive, destructive: $0.destructive,
                    abstained: $0.abstained)
            },
            categories: report.categoryMetrics.map {
                CategoryJSON(
                    category: $0.category.rawValue, count: $0.count,
                    tierHits: $0.tierHits, abstained: $0.abstained,
                    overEscalated: $0.overEscalated, underEscalated: $0.underEscalated)
            },
            destructiveRecall: report.destructiveRecall,
            sensitiveRecall: report.sensitiveRecall,
            routineExpected: report.routineExpectedCount,
            escalationsAboveExpected: report.escalationsAboveExpected,
            benignFalseEscalationCount: report.benignFalseEscalationCount,
            benignFalseEscalationRate: report.benignFalseEscalationRate,
            underEscalationCount: report.underEscalationCount,
            codeCheckedCount: report.codeCheckedCount,
            codeInSetCount: report.codeInSetCount,
            codeInSetRate: report.codeInSetRate,
            latencyP50Seconds: report.latencyP50Seconds,
            latencyP95Seconds: report.latencyP95Seconds,
            missedDestructive: offenders(report.missedDestructive),
            benignFalseEscalations: offenders(report.benignFalseEscalations),
            codeMisses: offenders(report.codeMisses)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIExecutionError("Could not encode the bench report.")
        }
        outputLine(text)
    }

    /// Latencies print in fixed milliseconds rather than `display`'s three significant
    /// digits: a sub-millisecond stub run would otherwise read as `5E-07`, and a bench
    /// report is read next to a 2-second timeout budget.
    private func displaySeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
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
        var speak: [HeadMotionSample] = []
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
            case .speak: speak.append(sample)
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
            tapPath: options.tapProfilePath,
            wearerSpeechPath: options.wearerSpeechProfilePath
        )
        var failures: [String] = []

        if options.target.includes(.gesture) {
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

        if options.target.includes(.tap) {
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

        if options.target.includes(.wearerSpeech) {
            let speechSamples = WearerSpeechCalibrationSamples(
                resting: resting, speaking: speak)
            let assessment = WearerSpeechCalibrator.assessment(of: speechSamples)
            outputLine("Wearer speech envelope: \(display(assessment.speakingEnvelopeLevel)) g sustained (resting peak \(display(assessment.restingEnvelopePeak)) g; required \(display(assessment.requiredLevel)) g)")
            if assessment.isUsable {
                let base = (try? store.loadWearerSpeech().config) ?? WearerSpeechConfig()
                let config = WearerSpeechCalibrator.suggestedConfig(
                    from: speechSamples, base: base)
                outputLine("Wearer speech thresholds: enter \(display(config.envelopeEnterThreshold)) g, exit \(display(config.envelopeExitThreshold)) g")
                let profile = TapQWearerSpeechCalibrationProfile(
                    config: config,
                    quality: WearerSpeechCalibrationQuality(
                        restingSampleCount: assessment.restingSampleCount,
                        speakingSampleCount: assessment.speakingSampleCount,
                        restingEnvelopePeak: assessment.restingEnvelopePeak,
                        speakingEnvelopeLevel: assessment.speakingEnvelopeLevel
                    )
                )
                try store.save(profile)
                outputLine("Wearer speech calibration saved to \(store.wearerSpeechProfileURL.path)")
            } else {
                failures.append(wearerSpeechFailure(assessment))
            }
        }

        if !failures.isEmpty {
            throw CLIExecutionError(failures.joined(separator: " "))
        }
    }

    /// Separates the two ways a speak phase fails, because the remedies are unrelated: too
    /// few samples means the motion stream did not deliver, while too little separation
    /// means it did and the speech was not distinguishable from rest.
    private func wearerSpeechFailure(
        _ assessment: WearerSpeechCalibrator.Assessment
    ) -> String {
        let retry = "Any valid gesture or tap profile was kept; retry only wearer speech with `tapq calibration run wearer-speech`."
        guard assessment.hasEnoughSamples else {
            return "Wearer speech calibration captured too few motion samples (rest \(assessment.restingSampleCount), speak \(assessment.speakingSampleCount); \(assessment.requiredSampleCount) needed in each). Check that the AirPods are connected and lengthen the phases with --rest-seconds and --speak-seconds. \(retry)"
        }
        return "Wearer speech calibration did not observe a vibration envelope sufficiently separated from resting motion. Read aloud continuously at a normal speaking volume, keep your head still, and quit other headphone-motion apps first. \(retry)"
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
            tapPath: options.tapProfilePath,
            wearerSpeechPath: options.wearerSpeechProfilePath
        )
        func selected(_ kind: CalibrationProfileKind) -> Bool {
            options.target.includes(kind) && store.exists(kind)
        }
        let gesture = selected(.gesture) ? try store.loadGesture() : nil
        let tap = selected(.tap) ? try store.loadTap() : nil
        let wearerSpeech = selected(.wearerSpeech) ? try store.loadWearerSpeech() : nil
        guard gesture != nil || tap != nil || wearerSpeech != nil else {
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
            case .wearerSpeech: data = try encoder.encode(wearerSpeech)
            case .all:
                data = try encoder.encode(CalibrationProfileCollection(
                    gesture: gesture,
                    tap: tap,
                    wearerSpeech: wearerSpeech
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
        if gesture != nil || tap != nil, wearerSpeech != nil { outputLine("") }
        if let wearerSpeech {
            outputLine("Wearer speech calibration: \(store.wearerSpeechProfileURL.path)")
            outputLine("Calibrated: \(ISO8601DateFormatter().string(from: wearerSpeech.calibratedAt))")
            outputLine("Wearer speech thresholds: enter \(display(wearerSpeech.config.envelopeEnterThreshold)) g, exit \(display(wearerSpeech.config.envelopeExitThreshold)) g")
            outputLine("Observed envelope: \(display(wearerSpeech.quality.speakingEnvelopeLevel)) g sustained (resting peak \(display(wearerSpeech.quality.restingEnvelopePeak)) g)")
            outputLine("Samples: rest \(wearerSpeech.quality.restingSampleCount), speak \(wearerSpeech.quality.speakingSampleCount)")
        }
    }

    private func resetCalibration(_ options: CalibrationResetOptions) throws {
        let store = calibrationStore(
            gesturePath: options.gestureProfilePath,
            tapPath: options.tapProfilePath,
            wearerSpeechPath: options.wearerSpeechProfilePath
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
            outputLine("\(kind.displayName) calibration profile removed from \(store.url(for: kind).path).")
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
            let installationStatus = installer.installationStatus()
            switch installationStatus {
            case .installed:
                outputLine("Codex integration: configured")
                outputLine("Hooks: \(hooksURL.path)")
                outputLine("Hook: \(hookURL.path)")
            case .partial:
                outputLine("Codex integration: incomplete")
                outputLine("Hooks: \(hooksURL.path)")
                outputLine("Hook: \(hookURL.path)")
                outputLine("Re-run `tapq integration codex install` to repair it.")
            case .notInstalled:
                outputLine("Codex integration: not installed")
            }
            reportCodexActivationStatus(hasHookDefinition: installationStatus != .notInstalled)
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

    private func reportCodexActivationStatus(hasHookDefinition: Bool) {
        let status = CodexCLIProbe.probe(
            executablePath: codexCLIExecutablePath,
            executableWasResolved: codexCLIExecutableWasResolved,
            using: codexCLICommandRunner
        )
        switch status.availability {
        case .detected:
            outputLine("Codex CLI: \(status.version ?? "detected; version unknown")")
        case .probeFailed:
            outputLine("Codex CLI: executable found, but diagnostics failed or timed out")
        case .notFound:
            outputLine("Codex CLI: not found on PATH")
        }
        if let executablePath = status.executablePath {
            outputLine("Codex CLI executable: \(terminalSafePath(executablePath))")
        }
        outputLine("Codex feature `hooks`: \(featureDescription(status.hooks))")
        outputLine(
            "Codex feature `default_mode_request_user_input`: "
            + featureDescription(status.defaultModeRequestUserInput)
        )
        if status.isBelowTestedLifecycleFloor == true, let version = status.version {
            outputLine(
                "Compatibility warning: Codex \(version) is below TapQ's tested "
                + "lifecycle-hook floor \(CodexCLIProbe.testedLifecycleFloor); update Codex "
                + "before relying on this integration."
            )
        }

        switch status.hooks {
        case .disabled:
            outputLine(
                "Hook activation: disabled in Codex; enable the `hooks` feature before "
                + "expecting TapQ interception."
            )
        case .unknown:
            outputLine("Hook activation: unknown; verify the `hooks` feature in Codex.")
        case .enabled:
            break
        }

        switch status.defaultModeRequestUserInput {
        case .enabled:
            outputLine(
                "Questions: `request_user_input` is available in Plan mode and enabled "
                + "for Default mode."
            )
        case .disabled:
            outputLine(
                "Questions: use Plan mode for `request_user_input`; Default mode requires "
                + "Codex feature `default_mode_request_user_input`, which is disabled."
            )
        case .unknown:
            outputLine(
                "Questions: use Plan mode for `request_user_input`; Default-mode availability "
                + "is unknown."
            )
        }
        if hasHookDefinition {
            outputLine(
                "Trust: owned by Codex; TapQ cannot inspect or grant it. "
                + "To verify in Codex with `/hooks`, review the current hook definitions."
            )
        } else {
            outputLine("Trust: owned by Codex; TapQ cannot inspect or grant it.")
        }
    }

    private func featureDescription(_ state: CodexFeatureState) -> String {
        switch state {
        case .enabled(let stage): "enabled (\(stage))"
        case .disabled(let stage): "disabled (\(stage))"
        case .unknown: "unknown"
        }
    }

    private func terminalSafePath(_ path: String) -> String {
        let scalarLimit = 256
        var result = ""
        var scalarCount = 0
        for scalar in path.unicodeScalars {
            guard scalarCount < scalarLimit else {
                result += "..."
                break
            }
            scalarCount += 1
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result
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
        tapPath: String?,
        wearerSpeechPath: String? = nil
    ) -> CalibrationStore {
        let defaults = CalibrationStore.defaultStore(
            environment: environment,
            homeDirectory: homeDirectory
        )
        return CalibrationStore(
            gestureProfileURL: gesturePath.map(resolvedURL(for:))
                ?? defaults.gestureProfileURL,
            tapProfileURL: tapPath.map(resolvedURL(for:))
                ?? defaults.tapProfileURL,
            wearerSpeechProfileURL: wearerSpeechPath.map(resolvedURL(for:))
                ?? defaults.wearerSpeechProfileURL
        )
    }

    private func calibrationName(_ target: CalibrationTarget) -> String {
        switch target {
        case .all: "Gesture, tap, and wearer speech"
        case .gesture: "Gesture"
        case .tap: "Tap"
        case .wearerSpeech: "Wearer speech"
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

    /// How many offender ids the text report prints per list. Enough to review in one
    /// sitting; the `--json` report carries every one of them.
    private static let benchOffenderLimit = 10

    private static func help(for topic: CLIHelpTopic) -> String {
        switch topic {
        case .root: return rootHelp
        case .serve: return serveHelp
        case .capture: return captureHelp
        case .replay: return replayHelp
        case .bench: return benchHelp
        case .calibration: return calibrationHelp
        case .integration: return integrationHelp
        }
    }

    private static let rootHelp = """
    TapQ command-line interface

    USAGE
      tapq <command> [options]

    COMMANDS
      bench         Score a stage-2 reasoner against a labeled scenario corpus
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
                               with TAPQ_SPEECH_VOICE). The en-US default prefers a
                               downloaded high-quality Samantha and only takes the
                               compact system pick when none is installed. Unset, macOS
                               picks the voice from the system language regardless of
                               what TapQ says, which garbles the readout on a
                               non-English Mac. This selects the voice only — TapQ's
                               own prompts are English either way.
      --no-announcements       Disable non-blocking agent status announcements
      --steering               Ask supported adapters to prefer structured questions
      --question-classifier P  Use auto, apple, anthropic, openai, or local (default: auto)
      --voice-backend B        Speech pipe for voice commands: apple (default), Apple's
                               on-device recognizer, or openai-realtime. The realtime
                               backend requires OPENAI_API_KEY in the environment and
                               serving refuses to start without it. It is always composed
                               with the Apple stack underneath: if the session cannot be
                               opened, or drops mid-window, voice continues on-device
                               without the wearer noticing. TapQ commits every turn
                               itself — no backend ever ends one.
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
      --wearer-gate            Filter voice commands through IMU-based wearer-speech
                               attribution (default: off). Requires AirPods motion.
                               Uses wearer-speech-calibration.json when present,
                               provisional thresholds otherwise. Always fail-open: a
                               degraded or absent signal reproduces today's shipped
                               behavior verbatim. With provisional thresholds, the gate
                               may pass bystander speech — the attribution window is
                               generous by design until the capture study lands.

    The broker is agent-neutral. Install each agent's adapter separately with
    `tapq integration claude install` or `tapq integration codex install`.
    """

    private static let captureHelp = """
    Capture raw headphone motion. Hardware acquisition currently requires macOS and compatible AirPods.

    USAGE
      tapq capture [--duration SECONDS] [--format jsonl|csv] [--output PATH|-] [--force]
                   [--mic-envelope PATH]

    OPTIONS
      --duration SECONDS   Capture duration (default: 10)
      --format FORMAT      jsonl (default) or csv
      --output, -o PATH    Output file, or - for stdout (default: -)
      --force, -f          Replace an existing output file (also applies to --mic-envelope)
      --mic-envelope PATH  Co-record a microphone loudness envelope to a JSONL sidecar,
                           time-aligned to the motion track's own clock. Study tooling for
                           labelling wearer speech; no audio is retained, only per-block
                           RMS and peak. If the microphone cannot start, the command fails
                           before capturing any motion.

    Select the Mac's built-in microphone as the system input before co-recording an
    envelope. Opening the AirPods microphone switches Bluetooth into its headset mode,
    which degrades the audio route mid-session and changes the very motion signal the
    study is trying to measure.
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
                               tilt_right, tap, swipe_up, swipe_down. A `wearer_speech`
                               segment marks a span the wearer was talking and is scored
                               separately, as an interval rather than an event
      --format jsonl|csv       Override capture format auto-detection
      --tolerance SECONDS      Grace period after a segment's end in which its event may
                               still fire, and the edge slack allowed around a
                               wearer-speech span (default: 1.0)
      --encoder-model PATH     Also replay through a TapQ-1 encoder model (macOS only)
      --gesture-profile PATH   Use a calibrated gesture profile instead of defaults
      --tap-profile PATH       Use a calibrated tap profile instead of defaults
      --wearer-speech-profile PATH
                               Use a calibrated wearer-speech profile instead of defaults
      --mic-envelope PATH      Envelope sidecar from `tapq capture --mic-envelope`, used
                               as wearer-speech ground truth. `wearer_speech` labels win
                               when both are supplied
      --json                   Emit the report as JSON

    Swipe detection is enabled during replay even though it ships disabled live, so
    experimental channels can be evaluated from the same recordings.

    The wearer-speech section appears only when ground truth exists — `wearer_speech`
    labels or an envelope sidecar. It reports frame-level precision/recall/F1 at the
    capture's own sample rate, mean onset latency, and false activations per minute.
    """

    private static let benchHelp = """
    Score a stage-2 risk reasoner against a labeled scenario corpus. Each scenario's
    context is assessed once, in file order, and graded by the rules in
    bench/README.md: exact tier match, rationale code in the labeled set, and
    abstention counted as a miss on sensitive and destructive rows.

    USAGE
      tapq bench reasoner --scenarios PATH [options]

    OPTIONS
      --scenarios PATH   Required; newline-delimited JSON corpus, one scenario per
                         line (bench/reasoner-scenarios-v1.ndjson)
      --reasoner apple   Backend to measure (default: apple). `off` is rejected —
                         a bench run without a reasoner measures nothing
      --limit N          Assess only the first N scenarios, for a quick smoke run
      --json             Emit the report as JSON, including every offender id

    Scenarios run sequentially so latency is the time one assessment takes rather
    than queueing delay, and so the model's cached prompt prefix behaves as it does
    live. Progress goes to stderr, keeping stdout pipe-safe.

    Unlike `tapq serve`, which serves on without a reasoner because a missing one
    can only mean "no escalation", bench fails when the model is unavailable: a run
    of abstentions would print as a report and read as a result.
    """

    private static let calibrationHelp = """
    Calibrate gesture, tap, and wearer-speech thresholds as independent profiles without
    retaining raw motion samples.

    USAGE
      tapq calibration run [all|gesture|tap|wearer-speech] [options]
      tapq calibrate [all|gesture|tap|wearer-speech] [options]
      tapq calibration show [all|gesture|tap|wearer-speech] [--json] [profile options]
      tapq calibration reset [all|gesture|tap|wearer-speech] [--yes] [profile options]

    The `all` target covers all three profiles: nod/shake, tap, and the wearer-speech
    vibration envelope.

    RUN OPTIONS
      --rest-seconds N     Resting phase duration (default: 3)
      --nod-seconds N      Nod phase duration (default: 4)
      --shake-seconds N    Shake phase duration (default: 4)
      --tap-seconds N      Tap phase duration (default: 4)
      --speak-seconds N    Read-aloud phase duration (default: 6)
      --non-interactive    Start without waiting for the initial Return prompt

    PROFILE OPTIONS
      --profile PATH                Override the selected single-target profile path
      --gesture-profile PATH        Override the gesture profile path
      --tap-profile PATH            Override the tap profile path
      --wearer-speech-profile PATH  Override the wearer-speech profile path

    A full run saves each usable profile immediately. If one phase fails, rerun only that
    target; for example, `tapq calibration run tap` does not repeat nod and shake.

    The wearer-speech phase asks you to read aloud with your head still. It measures the
    jaw- and skull-borne vibration the earbud IMU picks up while you talk, which is a
    different quantity from the microphone's audio and is only comparable to a resting
    baseline recorded in the same session.
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

    Codex installs four managed lifecycle definitions in ~/.codex/hooks.json (or
    $CODEX_HOME/hooks.json): PreToolUse intercepts structured `request_user_input`,
    PermissionRequest covers Bash, apply_patch, and canonical MCP tools, Stop handles
    completion/question fallback, and matcherless UserPromptSubmit supplies the opt-in
    root-turn steering hint. Native Codex behavior remains authoritative whenever TapQ
    fails through. After installation, open `/hooks` in Codex and trust the four current
    TapQ-managed definitions; Codex skips new or changed non-managed hooks until trusted.

    `tapq integration codex status` resolves the first executable `codex` on PATH and runs
    the read-only commands `codex --version` and `codex features list` with a minimal
    environment. It reports lifecycle-feature availability, Plan/default-mode question
    guidance, and the executable path; hook trust itself remains visible only in `/hooks`.
    """
}

private struct CalibrationProfileCollection: Encodable {
    let gesture: TapQGestureCalibrationProfile?
    let tap: TapQTapCalibrationProfile?
    let wearerSpeech: TapQWearerSpeechCalibrationProfile?

    enum CodingKeys: String, CodingKey {
        case gesture, tap
        // Matches `CalibrationProfileKind.wearerSpeech`'s raw value, so the same spelling
        // names the target, the file, and this key.
        case wearerSpeech = "wearer_speech"
    }
}

private struct CLIExecutionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
