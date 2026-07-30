import XCTest
@testable import TapQCLI

final class BenchCommandParsingTests: XCTestCase {
    func testBenchParsesAllOptions() throws {
        let command = try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "bench/reasoner-scenarios-v1.ndjson",
            "--reasoner", "apple", "--limit", "25", "--json",
        ])
        var expected = BenchOptions()
        expected.scenariosPath = "bench/reasoner-scenarios-v1.ndjson"
        expected.reasonerProvider = .apple
        expected.limit = 25
        expected.json = true
        XCTAssertEqual(command, .bench(expected))
    }

    func testBenchDefaultsToTheAppleReasonerAndTheWholeCorpus() throws {
        guard case .bench(let options) = try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "corpus.jsonl",
        ]) else { return XCTFail("Expected a bench command.") }

        XCTAssertEqual(options.reasonerProvider, .apple)
        XCTAssertNil(options.limit)
        XCTAssertFalse(options.json)
    }

    func testBenchRequiresScenarios() {
        XCTAssertThrowsError(try CLICommandParser.parse(["bench", "reasoner"])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "bench reasoner requires --scenarios PATH."
            )
        }
        XCTAssertThrowsError(try CLICommandParser.parse(["bench", "reasoner", "--json"]))
        XCTAssertThrowsError(
            try CLICommandParser.parse(["bench", "reasoner", "--scenarios"]))
    }

    /// `off` is the safe default for serving, where no reasoner means no escalation. A
    /// bench run has nothing to measure without one, so it is rejected rather than
    /// silently accepted.
    func testBenchRejectsReasonerOff() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "corpus.jsonl", "--reasoner", "off",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "bench needs a reasoner; '--reasoner off' has nothing to measure."
            )
        }
    }

    func testBenchRejectsUnknownReasonerProvider() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "corpus.jsonl", "--reasoner", "openai",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--reasoner must be 'apple'."
            )
        }
    }

    func testBenchValidatesLimit() {
        for value in ["0", "abc", "2.5"] {
            XCTAssertThrowsError(try CLICommandParser.parse([
                "bench", "reasoner", "--scenarios", "corpus.jsonl", "--limit", value,
            ])) { error in
                XCTAssertEqual(
                    (error as? CLIUsageError)?.message,
                    "--limit must be a whole number greater than 0."
                )
            }
        }
        // A negative value never reaches the number check: the cursor refuses a value
        // that looks like another flag.
        XCTAssertThrowsError(try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "corpus.jsonl", "--limit", "-3",
        ]))
    }

    func testBenchRejectsUnknownSubjectAndOption() {
        XCTAssertThrowsError(try CLICommandParser.parse([
            "bench", "encoder", "--scenarios", "corpus.jsonl",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "Unknown bench subject 'encoder'. Available subjects: 'reasoner'."
            )
        }
        XCTAssertThrowsError(try CLICommandParser.parse([
            "bench", "reasoner", "--scenarios", "corpus.jsonl", "--bogus",
        ])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "Unknown bench option '--bogus'."
            )
        }
    }

    func testBenchHelp() throws {
        XCTAssertEqual(try CLICommandParser.parse(["bench"]), .help(.bench))
        XCTAssertEqual(try CLICommandParser.parse(["bench", "--help"]), .help(.bench))
        XCTAssertEqual(try CLICommandParser.parse(["bench", "-h"]), .help(.bench))
        XCTAssertEqual(
            try CLICommandParser.parse(["bench", "reasoner", "--help"]), .help(.bench))
        XCTAssertEqual(try CLICommandParser.parse(["help", "bench"]), .help(.bench))
    }
}
