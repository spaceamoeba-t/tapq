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
}
