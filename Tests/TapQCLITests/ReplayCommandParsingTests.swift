import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

final class ReplayCommandParsingTests: XCTestCase {
    func testReplayParsesAllOptions() throws {
        let command = try CLICommandParser.parse([
            "replay", "--input", "capture.jsonl", "--labels", "labels.jsonl",
            "--format", "csv", "--tolerance", "2.5", "--json",
            "--encoder-model", "model.mlpackage",
            "--gesture-profile", "g.json", "--tap-profile", "t.json",
        ])
        var expected = ReplayOptions()
        expected.inputPath = "capture.jsonl"
        expected.labelsPath = "labels.jsonl"
        expected.format = .csv
        expected.tolerance = 2.5
        expected.json = true
        expected.encoderModelPath = "model.mlpackage"
        expected.gestureProfilePath = "g.json"
        expected.tapProfilePath = "t.json"
        XCTAssertEqual(command, .replay(expected))
    }

    func testReplayRequiresInput() {
        XCTAssertThrowsError(try CLICommandParser.parse(["replay"]))
        XCTAssertThrowsError(try CLICommandParser.parse(["replay", "--json"]))
    }

    func testReplayRejectsUnknownOption() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["replay", "--input", "x", "--bogus"]))
    }

    func testReplayHelp() throws {
        XCTAssertEqual(try CLICommandParser.parse(["replay", "--help"]), .help(.replay))
        XCTAssertEqual(try CLICommandParser.parse(["help", "replay"]), .help(.replay))
    }

    func testServeParsesEncoderOptions() throws {
        let command = try CLICommandParser.parse([
            "serve", "--encoder-model", "model.mlpackage", "--encoder-mode", "primary",
        ])
        var expected = ServeOptions()
        expected.encoderModelPath = "model.mlpackage"
        expected.encoderMode = .primary
        XCTAssertEqual(command, .serve(expected))
    }

    func testServeEncoderModeDefaultsToShadow() throws {
        let command = try CLICommandParser.parse([
            "serve", "--encoder-model", "model.mlpackage",
        ])
        var expected = ServeOptions()
        expected.encoderModelPath = "model.mlpackage"
        XCTAssertEqual(command, .serve(expected))
        XCTAssertEqual(expected.encoderMode, .shadow)
    }

    func testServeEncoderModeRequiresModel() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--encoder-mode", "primary"]))
    }

    func testServeRejectsEncoderModeOff() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--encoder-model", "m.mlpackage", "--encoder-mode", "off",
        ]))
    }

    func testServeParsesReasonerOptions() throws {
        let command = try CLICommandParser.parse([
            "serve", "--reasoner", "apple", "--reasoner-mode", "primary",
        ])
        var expected = ServeOptions()
        expected.reasonerProvider = .apple
        expected.reasonerMode = .primary
        XCTAssertEqual(command, .serve(expected))
    }

    func testServeReasonerDefaultsToOff() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"])
        else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.reasonerProvider, .off)
    }

    func testServeReasonerModeDefaultsToShadow() throws {
        let command = try CLICommandParser.parse(["serve", "--reasoner", "apple"])
        var expected = ServeOptions()
        expected.reasonerProvider = .apple
        XCTAssertEqual(command, .serve(expected))
        XCTAssertEqual(expected.reasonerMode, .shadow)
    }

    func testServeReasonerModeRequiresProvider() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--reasoner-mode", "primary"]))
    }

    /// `--reasoner off --reasoner-mode shadow` reads like it enables something and does
    /// not, so it is rejected rather than silently ignored.
    func testServeRejectsReasonerModeWithProviderOff() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--reasoner", "off", "--reasoner-mode", "shadow",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--reasoner-mode requires a --reasoner provider other than 'off'."
            )
        }
    }

    /// `off` is a mode the runtime uses internally, never one a user selects here:
    /// turning the reasoner off is `--reasoner off`.
    func testServeRejectsReasonerModeOff() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--reasoner", "apple", "--reasoner-mode", "off",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--reasoner-mode must be 'shadow' or 'primary'."
            )
        }
    }

    func testServeRejectsUnknownReasonerProvider() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "serve", "--reasoner", "openai",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--reasoner must be 'off' or 'apple'."
            )
        }
    }
}
