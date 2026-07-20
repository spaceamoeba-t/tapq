import Foundation
import TapQClaudeAdapter
import TapQCodexAdapter
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol

public enum TapQVersion {
    public static let current = "0.1.0"
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
    private let environment: [String: String]
    private let homeDirectory: URL
    private let executableURL: URL
    private let currentDirectory: URL
    private let monotonicNow: () -> TimeInterval

    public init(
        io: TapQCLIIO = .live,
        motionCapture: (any TapQMotionCapturing)? = nil,
        runtimeService: (any TapQRuntimeServing)? = nil,
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
            announcementsEnabled: options.announcementsEnabled,
            steeringEnabled: options.steeringEnabled
        )
        try await runtimeService.serve(configuration: configuration) { [io] endpoint in
            io.writeOutput("TapQ runtime is ready. Press Control-C to stop.\n")
            io.writeOutput("Broker socket: \(endpoint.socketPath)\n")
            io.writeOutput("Discovery: \(endpoint.discoveryPath)\n")
            io.writeOutput("Gesture profile: \(endpoint.gestureProfileLoaded ? "loaded" : "default")\n")
            io.writeOutput("Tap profile: \(endpoint.tapProfileLoaded ? "loaded" : "default")\n")
            io.writeOutput("AirPods motion: \(endpoint.motionAvailable ? "available" : "unavailable")\n")
            io.writeOutput("Voice input: \(endpoint.voiceAvailable ? "available" : "unavailable")\n")
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
      --no-announcements       Disable non-blocking agent status announcements
      --steering               Ask supported adapters to prefer structured questions

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
