import XCTest
@testable import TapQClaudeAdapter
import TapQWireProtocol
import TapQContracts

final class TranscriptReaderTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-transcript-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ lines: [String], file: String = "t.jsonl") throws -> String {
        let url = dir.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func assistant(_ texts: String...) -> String {
        let blocks = texts.map { #"{"type":"text","text":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"assistant","message":{"role":"assistant","content":[\#(blocks)]}}"#
    }

    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptReader.lastAssistantText(transcriptPath: dir.appendingPathComponent("nope.jsonl").path))
    }

    func testEmptyFileReturnsNil() throws {
        let path = try write([])
        XCTAssertNil(TranscriptReader.lastAssistantText(transcriptPath: path))
    }

    func testNoAssistantEntriesReturnsNil() throws {
        let path = try write([user("hello"), #"{"type":"system","note":"x"}"#])
        XCTAssertNil(TranscriptReader.lastAssistantText(transcriptPath: path))
    }

    func testReturnsLastAssistantText() throws {
        let path = try write([
            user("do the thing"),
            assistant("Working on it."),
            user("ok"),
            assistant("Which approach? 1) A 2) B"),
        ])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "Which approach? 1) A 2) B")
    }

    func testJoinsTrailingConsecutiveAssistantLines() throws {
        // A streamed response can span several assistant lines; they are one reply.
        let path = try write([
            user("go"),
            assistant("old message"),
            user("continue"),
            assistant("Part one."),
            assistant("Part two: which? 1) A 2) B"),
        ])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "Part one.\n\nPart two: which? 1) A 2) B")
    }

    func testDoesNotCrossNonAssistantBoundary() throws {
        let path = try write([
            assistant("Question from an OLD turn?"),
            user("tool result"),
            assistant("Final statement."),
        ])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "Final statement.")
    }

    func testJoinsMultipleTextBlocksWithinOneLine() throws {
        let path = try write([assistant("First block.", "Second block.")])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "First block.\n\nSecond block.")
    }

    func testToolUseOnlyTrailingEntryYieldsPrecedingTextInSameRun() throws {
        let toolUseOnly = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#
        let path = try write([
            user("go"),
            assistant("Should I run the tests?"),
            toolUseOnly,
        ])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "Should I run the tests?")
    }

    func testMalformedTrailingLinesAreSkipped() throws {
        let path = try write([
            assistant("The real reply?"),
            "not json at all",
            "{\"type\":",
        ])
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path),
                       "The real reply?")
    }

    func testHugeFileOnlyReadsTail() throws {
        // 3 MB of filler lines, then the reply — the 2 MB tail window must find it.
        var lines: [String] = []
        let filler = user(String(repeating: "x", count: 1024))
        for _ in 0..<3072 { lines.append(filler) }
        lines.append(assistant("Found me?"))
        let path = try write(lines)
        XCTAssertEqual(TranscriptReader.lastAssistantText(transcriptPath: path), "Found me?")
    }
}
