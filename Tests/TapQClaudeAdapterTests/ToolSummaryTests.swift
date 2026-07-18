import XCTest
@testable import TapQClaudeAdapter
import TapQWireProtocol
import TapQContracts

final class ToolSummaryTests: XCTestCase {
    func testBashShortCommand() {
        let (summary, detail) = ToolSummary.render(toolName: "Bash", input: ["command": .string("npm test")])
        XCTAssertEqual(summary, "run npm test")
        XCTAssertEqual(detail, "Run the command: npm test")
    }

    func testBashLongCommandIsShortenedForSpeech() {
        let command = "git log --oneline --graph --decorate --all --since yesterday --author me extra words here"
        let (summary, detail) = ToolSummary.render(toolName: "Bash", input: ["command": .string(command)])
        XCTAssertTrue(summary.hasPrefix("run "))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertTrue(detail.contains(command))
    }

    func testBashCollapsesNewlines() {
        let (summary, _) = ToolSummary.render(toolName: "Bash", input: ["command": .string("cd /tmp\nls")])
        XCTAssertFalse(summary.contains("\n"))
    }

    func testWriteUsesBasename() {
        let (summary, detail) = ToolSummary.render(
            toolName: "Write", input: ["file_path": .string("/Users/x/proj/Sources/Foo.swift")])
        XCTAssertEqual(summary, "create the file Foo.swift")
        XCTAssertTrue(detail.contains("/Users/x/proj/Sources/Foo.swift"))
    }

    func testEditUsesBasename() {
        let (summary, _) = ToolSummary.render(
            toolName: "Edit", input: ["file_path": .string("/a/b/Bar.swift")])
        XCTAssertEqual(summary, "edit the file Bar.swift")
    }

    func testUnknownToolFallsBack() {
        let (summary, detail) = ToolSummary.render(toolName: "WebFetch", input: ["url": .string("https://x")])
        XCTAssertEqual(summary, "use the WebFetch tool")
        XCTAssertTrue(detail.contains("url"))
    }
}
