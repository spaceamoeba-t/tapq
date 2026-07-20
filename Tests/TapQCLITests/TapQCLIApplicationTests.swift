import Foundation
import XCTest
@testable import TapQCLI
import TapQDetectionBaseline
import TapQWireProtocol

final class TapQCLIApplicationTests: XCTestCase {
    private final class Buffer {
        var output = ""
        var error = ""
        var inputs: [String?] = []

        var io: TapQCLIIO {
            TapQCLIIO(
                writeOutput: { self.output += $0 },
                writeError: { self.error += $0 },
                readInput: { self.inputs.isEmpty ? nil : self.inputs.removeFirst() }
            )
        }
    }

    private final class TestClock {
        var now: TimeInterval = 0
    }

    @MainActor
    private final class FakeRuntime: TapQRuntimeServing {
        private(set) var configurations: [TapQRuntimeConfiguration] = []

        func serve(
            configuration: TapQRuntimeConfiguration,
            onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
        ) async throws {
            configurations.append(configuration)
            onReady(.init(
                socketPath: "/tmp/tapq.sock",
                discoveryPath: "/tmp/broker.json",
                gestureProfileLoaded: true,
                tapProfileLoaded: true,
                motionAvailable: true,
                voiceAvailable: false
            ))
        }
    }

    private struct TimedSample {
        let time: TimeInterval
        let sample: HeadMotionSample
    }

    @MainActor
    private final class FakeCapture: TapQMotionCapturing {
        var sessions: [[TimedSample]]
        let clock: TestClock?
        private(set) var durations: [TimeInterval] = []

        init(sessions: [[TimedSample]], clock: TestClock? = nil) {
            self.sessions = sessions
            self.clock = clock
        }

        func capture(
            for duration: TimeInterval,
            onSample: @escaping @MainActor (HeadMotionSample) -> Void
        ) async throws {
            durations.append(duration)
            let samples = sessions.isEmpty ? [] : sessions.removeFirst()
            for item in samples {
                clock?.now = item.time
                onSample(item.sample)
            }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-cli-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testVersionAndJSONVersion() async {
        let buffer = Buffer()
        let app = application(io: buffer.io)

        let versionStatus = await app.run(arguments: ["version"])
        XCTAssertEqual(versionStatus, 0)
        XCTAssertTrue(buffer.output.contains("tapq \(TapQVersion.current)"))

        buffer.output = ""
        let jsonStatus = await app.run(arguments: ["--version", "--json"])
        XCTAssertEqual(jsonStatus, 0)
        XCTAssertTrue(buffer.output.contains("\"wire_protocol\":\(WireProtocol.version)"))
    }

    @MainActor
    func testCaptureWritesCSVFile() async throws {
        let buffer = Buffer()
        let capture = FakeCapture(sessions: [[
            TimedSample(time: 0, sample: sample(1)),
            TimedSample(time: 0, sample: sample(2)),
        ]])
        let app = application(io: buffer.io, capture: capture)
        let output = directory.appendingPathComponent("capture.csv")

        let status = await app.run(arguments: [
            "capture", "--duration", "1", "--format", "csv", "--output", output.path,
        ])
        XCTAssertEqual(status, 0)

        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(MotionSampleFormatter.csvHeader + "\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        XCTAssertTrue(buffer.error.contains("Captured 2 samples"))
    }

    @MainActor
    func testUnavailableCaptureReturnsUnavailableExitCode() async {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let status = await app.run(arguments: ["capture"])
        XCTAssertEqual(status, 69)
        XCTAssertTrue(buffer.error.contains("Linux does not yet include"))
    }

    @MainActor
    func testServeBuildsConfigurationAndReportsReadyEndpoint() async {
        let buffer = Buffer()
        let runtime = FakeRuntime()
        let app = application(io: buffer.io, runtime: runtime)

        let status = await app.run(arguments: [
            "serve", "--broker-dir", "runtime", "--gesture-profile", "gesture.json",
            "--tap-profile", "tap.json", "--timeout", "25", "--no-voice",
            "--no-announcements", "--steering",
        ])

        XCTAssertEqual(status, 0)
        XCTAssertEqual(runtime.configurations.count, 1)
        let configuration = runtime.configurations[0]
        XCTAssertEqual(configuration.brokerDirectory?.path, directory.appendingPathComponent("runtime").path)
        XCTAssertEqual(configuration.gestureProfileURL.path, directory.appendingPathComponent("gesture.json").path)
        XCTAssertEqual(configuration.tapProfileURL.path, directory.appendingPathComponent("tap.json").path)
        XCTAssertEqual(configuration.interactionTimeout, 25)
        XCTAssertFalse(configuration.voiceEnabled)
        XCTAssertFalse(configuration.announcementsEnabled)
        XCTAssertTrue(configuration.steeringEnabled)
        XCTAssertTrue(buffer.output.contains("TapQ runtime is ready"))
        XCTAssertTrue(buffer.output.contains("AirPods motion: available"))
    }

    @MainActor
    func testServeWithoutRuntimeReportsUnavailable() async {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let status = await app.run(arguments: ["serve"])
        XCTAssertEqual(status, 69)
        XCTAssertTrue(buffer.error.contains("live TapQ runtime is unavailable"))
    }

    @MainActor
    func testCalibrationWritesSeparateProfilesAndCanShowAndResetThem() async throws {
        let buffer = Buffer()
        let clock = TestClock()
        let capture = FakeCapture(sessions: [calibrationSamples()], clock: clock)
        let app = application(io: buffer.io, capture: capture, monotonicNow: { clock.now })
        let gestureURL = directory.appendingPathComponent("gesture.json")
        let tapURL = directory.appendingPathComponent("tap.json")
        let common = [
            "--gesture-profile", gestureURL.path,
            "--tap-profile", tapURL.path,
        ]

        let runStatus = await app.run(arguments: [
            "calibrate", "--non-interactive",
            "--rest-seconds", "0.1", "--nod-seconds", "0.1",
            "--shake-seconds", "0.1", "--tap-seconds", "0.1",
        ] + common)
        XCTAssertEqual(runStatus, 0)

        let store = CalibrationStore(
            gestureProfileURL: gestureURL,
            tapProfileURL: tapURL
        )
        let gesture = try store.loadGesture()
        let tap = try store.loadTap()
        XCTAssertGreaterThan(gesture.quality.nodSampleCount, 0)
        XCTAssertGreaterThan(tap.quality.tapAccelerationPeak, 0.3)
        XCTAssertEqual(capture.durations.count, 1)
        XCTAssertEqual(capture.durations.first ?? 0, 4.4, accuracy: 0.000_001)
        let persistedGesture = try String(contentsOf: gestureURL, encoding: .utf8)
        let persistedTap = try String(contentsOf: tapURL, encoding: .utf8)
        XCTAssertFalse(persistedGesture.contains("\"restingPitch\""))
        XCTAssertFalse(persistedTap.contains("\"tapAccel\""))

        buffer.output = ""
        let showStatus = await app.run(arguments: ["calibration", "show"] + common)
        XCTAssertEqual(showStatus, 0)
        XCTAssertTrue(buffer.output.contains("Gesture threshold"))
        XCTAssertTrue(buffer.output.contains("Observed peak"))

        let resetStatus = await app.run(arguments: ["calibration", "reset", "--yes"] + common)
        XCTAssertEqual(resetStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gestureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tapURL.path))
    }

    @MainActor
    func testWeakTapKeepsGestureProfileAndTapOnlyRetrySkipsNodAndShake() async throws {
        let gestureURL = directory.appendingPathComponent("gesture.json")
        let tapURL = directory.appendingPathComponent("tap.json")
        let common = [
            "--gesture-profile", gestureURL.path,
            "--tap-profile", tapURL.path,
        ]

        let firstBuffer = Buffer()
        let firstClock = TestClock()
        let firstCapture = FakeCapture(
            sessions: [calibrationSamples(tapValues: [0.02, 0.04, 0.03])],
            clock: firstClock
        )
        let firstApp = application(
            io: firstBuffer.io,
            capture: firstCapture,
            monotonicNow: { firstClock.now }
        )
        let firstStatus = await firstApp.run(arguments: [
            "calibration", "run", "all", "--non-interactive",
            "--rest-seconds", "0.1", "--nod-seconds", "0.1",
            "--shake-seconds", "0.1", "--tap-seconds", "0.1",
        ] + common)

        XCTAssertEqual(firstStatus, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gestureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tapURL.path))
        XCTAssertTrue(firstBuffer.output.contains("Tap signal peak: 0.04 g"))
        XCTAssertTrue(firstBuffer.error.contains("run tap"))

        let retryBuffer = Buffer()
        let retryClock = TestClock()
        let retryCapture = FakeCapture(
            sessions: [tapOnlySamples()],
            clock: retryClock
        )
        let retryApp = application(
            io: retryBuffer.io,
            capture: retryCapture,
            monotonicNow: { retryClock.now }
        )
        let retryStatus = await retryApp.run(arguments: [
            "calibration", "run", "tap", "--non-interactive",
            "--rest-seconds", "0.1", "--tap-seconds", "0.1",
            "--profile", tapURL.path,
        ])

        XCTAssertEqual(retryStatus, 0)
        XCTAssertEqual(retryCapture.durations, [2.2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: gestureURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tapURL.path))
        let savedTap = try CalibrationStore(
            gestureProfileURL: gestureURL,
            tapProfileURL: tapURL
        ).loadTap()
        XCTAssertEqual(savedTap.config.amplitudeThreshold, 0.05, accuracy: 1e-9)
    }

    @MainActor
    func testClaudeIntegrationLifecycle() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-hook")
        let settings = directory.appendingPathComponent("claude/settings.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let options = ["--settings", settings.path, "--hook", hook.path]

        let installStatus = await app.run(arguments: ["integration", "claude", "install"] + options)
        XCTAssertEqual(installStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
        let settingsAttributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        XCTAssertEqual(
            (settingsAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o600
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: settings.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o700
        )
        XCTAssertTrue(buffer.output.contains("Permission policy: strict"))

        buffer.output = ""
        let installedStatus = await app.run(arguments: ["integration", "claude", "status"] + options)
        XCTAssertEqual(installedStatus, 0)
        XCTAssertTrue(buffer.output.contains("integration: installed"))

        let uninstallStatus = await app.run(arguments: ["integration", "claude", "uninstall"] + options)
        XCTAssertEqual(uninstallStatus, 0)
        let uninstalledSettingsAttributes = try FileManager.default.attributesOfItem(
            atPath: settings.path
        )
        XCTAssertEqual(
            (uninstalledSettingsAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o600
        )
        buffer.output = ""
        let removedStatus = await app.run(arguments: ["integration", "claude", "status"] + options)
        XCTAssertEqual(removedStatus, 0)
        XCTAssertTrue(buffer.output.contains("not installed"))
    }

    @MainActor
    func testClaudeIntegrationDefaultsToTapQHookBesideCLI() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-hook")
        let settings = directory.appendingPathComponent("claude/settings.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: hook.path,
            contents: Data("hook".utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )

        let status = await app.run(arguments: [
            "integration", "claude", "install", "--settings", settings.path,
        ])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Hook: \(hook.path)"))
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(text.contains("tapq-hook"))
        XCTAssertFalse(text.contains("wavo-hook"))
    }

    @MainActor
    func testCodexIntegrationLifecycle() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-codex-hook")
        let hooks = directory.appendingPathComponent("codex/hooks.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let options = ["--hooks", hooks.path, "--hook", hook.path]

        let installStatus = await app.run(arguments: ["integration", "codex", "install"] + options)
        XCTAssertEqual(installStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooks.path))
        XCTAssertTrue(buffer.output.contains("Codex integration configured"))
        XCTAssertTrue(buffer.output.contains("`/hooks`"))

        buffer.output = ""
        let configuredStatus = await app.run(arguments: ["integration", "codex", "status"] + options)
        XCTAssertEqual(configuredStatus, 0)
        XCTAssertTrue(buffer.output.contains("integration: configured"))
        XCTAssertTrue(buffer.output.contains("verify in Codex with `/hooks`"))

        buffer.output = ""
        let uninstallStatus = await app.run(arguments: ["integration", "codex", "uninstall"] + options)
        XCTAssertEqual(uninstallStatus, 0)
        XCTAssertTrue(buffer.output.contains("integration removed"))

        buffer.output = ""
        let removedStatus = await app.run(arguments: ["integration", "codex", "status"] + options)
        XCTAssertEqual(removedStatus, 0)
        XCTAssertTrue(buffer.output.contains("not installed"))
    }

    @MainActor
    func testCodexIntegrationDefaultsToHookBesideCLI() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-codex-hook")
        let hooks = directory.appendingPathComponent("codex/hooks.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let status = await app.run(arguments: [
            "integration", "codex", "install", "--hooks", hooks.path,
        ])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Hook: \(hook.path)"))
        let text = try String(contentsOf: hooks, encoding: .utf8)
        XCTAssertTrue(text.contains("tapq-codex-hook"))
    }

    @MainActor
    func testCodexIntegrationHonorsCodexHome() async throws {
        let buffer = Buffer()
        let codexHome = directory.appendingPathComponent("custom-codex-home")
        let app = application(
            io: buffer.io,
            environment: [
                "TAPQ_CONFIG_DIR": directory.path,
                "CODEX_HOME": codexHome.path,
            ]
        )
        let hook = directory.appendingPathComponent("tapq-codex-hook")
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let status = await app.run(arguments: ["integration", "codex", "install"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: codexHome.appendingPathComponent("hooks.json").path
        ))
    }

    @MainActor
    func testClaudeIntegrationCanSwitchToNativeAndWarnsForBypassMode() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-hook")
        let settings = directory.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"permissions":{"defaultMode":"bypassPermissions"}}"#.utf8)
            .write(to: settings)
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let options = ["--settings", settings.path, "--hook", hook.path]

        let installStatus = await app.run(arguments: [
            "integration", "claude", "install", "--permission-policy", "native",
        ] + options)

        XCTAssertEqual(installStatus, 0)
        XCTAssertTrue(buffer.output.contains("Permission policy: native"))
        XCTAssertTrue(buffer.error.contains("defaults to bypassPermissions"))

        buffer.output = ""
        buffer.error = ""
        let status = await app.run(arguments: ["integration", "claude", "status"] + options)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Permission policy: native"))
        XCTAssertTrue(buffer.error.contains("defaults to bypassPermissions"))
    }

    @MainActor
    func testClaudeIntegrationStatusReportsPartialLayout() async throws {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let hook = directory.appendingPathComponent("tapq-hook")
        let settings = directory.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: hook.path, contents: Data("hook".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let partial = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash","hooks":[{"type":"command","command":"\(hook.path)","timeout":120}]}
        ]}}
        """
        try Data(partial.utf8).write(to: settings)

        let status = await app.run(arguments: [
            "integration", "claude", "status",
            "--settings", settings.path,
            "--hook", hook.path,
        ])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("integration: incomplete"))
        XCTAssertTrue(buffer.output.contains("Re-run `tapq integration claude install"))
    }

    @MainActor
    func testUnknownCommandReturnsUsageExitCode() async {
        let buffer = Buffer()
        let app = application(io: buffer.io)
        let status = await app.run(arguments: ["gesture", "analyze"])
        XCTAssertEqual(status, 64)
        XCTAssertTrue(buffer.error.contains("Unknown command 'gesture'"))
    }

    @MainActor
    private func application(
        io: TapQCLIIO,
        capture: (any TapQMotionCapturing)? = nil,
        runtime: (any TapQRuntimeServing)? = nil,
        environment: [String: String]? = nil,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) -> TapQCLIApplication {
        TapQCLIApplication(
            io: io,
            motionCapture: capture,
            runtimeService: runtime,
            environment: environment ?? ["TAPQ_CONFIG_DIR": directory.path],
            homeDirectory: directory,
            executableURL: directory.appendingPathComponent("tapq"),
            currentDirectory: directory,
            monotonicNow: monotonicNow
        )
    }

    private func sample(_ timestamp: TimeInterval) -> HeadMotionSample {
        HeadMotionSample(
            timestamp: timestamp,
            pitch: 0.1,
            yaw: -0.1,
            accelerationMagnitude: 0.2,
            rotationMagnitude: 0.3
        )
    }

    private func calibrationSamples(
        tapValues: [Double] = [0.05, 0.8, 0.06]
    ) -> [TimedSample] {
        let resting = [
            HeadMotionSample(timestamp: 0, pitch: 0, yaw: 0,
                             accelerationMagnitude: 0.01, rotationMagnitude: 0),
            HeadMotionSample(timestamp: 1, pitch: 0.01, yaw: -0.01,
                             accelerationMagnitude: 0.02, rotationMagnitude: 0),
        ]
        let nod = [-0.3, 0.3, -0.3, 0.3].enumerated().map {
            HeadMotionSample(timestamp: Double($0.offset), pitch: $0.element, yaw: 0,
                             accelerationMagnitude: 0.1, rotationMagnitude: 1)
        }
        let shake = [-0.35, 0.35, -0.35, 0.35].enumerated().map {
            HeadMotionSample(timestamp: Double($0.offset), pitch: 0, yaw: $0.element,
                             accelerationMagnitude: 0.1, rotationMagnitude: 1)
        }
        let tap = tapValues.enumerated().map {
            HeadMotionSample(timestamp: Double($0.offset), pitch: 0, yaw: 0,
                             accelerationMagnitude: $0.element, rotationMagnitude: 0.05)
        }
        return resting.map { TimedSample(time: 1.01, sample: $0) }
            + nod.map { TimedSample(time: 2.11, sample: $0) }
            + shake.map { TimedSample(time: 3.21, sample: $0) }
            + tap.map { TimedSample(time: 4.31, sample: $0) }
    }

    private func tapOnlySamples() -> [TimedSample] {
        let resting = [0.012, 0.0164].enumerated().map {
            TimedSample(time: 1.01, sample: HeadMotionSample(
                timestamp: Double($0.offset),
                pitch: 0,
                yaw: 0,
                accelerationMagnitude: $0.element,
                rotationMagnitude: 0
            ))
        }
        let tap = [0.018, 0.0715, 0.02].enumerated().map {
            TimedSample(time: 2.11, sample: HeadMotionSample(
                timestamp: Double($0.offset),
                pitch: 0,
                yaw: 0,
                accelerationMagnitude: $0.element,
                rotationMagnitude: 0.05
            ))
        }
        return resting + tap
    }
}
