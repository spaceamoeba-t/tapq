import XCTest
@testable import TapQCLI

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
        ])
        XCTAssertEqual(command, .serve(ServeOptions(
            brokerDirectoryPath: "runtime",
            gestureProfilePath: "gesture.json",
            tapProfilePath: "tap.json",
            interactionTimeout: 20,
            voiceEnabled: false,
            announcementsEnabled: false,
            steeringEnabled: true
        )))
    }

    func testServeHelpHasDedicatedTopic() throws {
        XCTAssertEqual(try CLICommandParser.parse(["serve", "--help"]), .help(.serve))
        XCTAssertEqual(try CLICommandParser.parse(["help", "serve"]), .help(.serve))
    }

    func testCaptureAcceptsExplicitStdoutPath() throws {
        let command = try CLICommandParser.parse(["capture", "--output", "-"])
        XCTAssertEqual(command, .capture(CaptureOptions()))
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
        ]))
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
        XCTAssertEqual(command, .integration(IntegrationOptions(
            action: .install,
            settingsPath: "settings.json",
            hookPath: "tapq-hook",
            permissionPolicy: .native
        )))
    }

    func testClaudeIntegrationDefaultsToStrictPolicy() throws {
        let command = try CLICommandParser.parse([
            "integration", "claude", "install",
        ])
        XCTAssertEqual(command, .integration(IntegrationOptions(
            action: .install,
            permissionPolicy: .strict
        )))
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
