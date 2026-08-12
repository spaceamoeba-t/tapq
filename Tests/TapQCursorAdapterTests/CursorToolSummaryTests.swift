import XCTest
@testable import TapQCursorAdapter
import TapQWireProtocol

final class CursorToolSummaryTests: XCTestCase {
    func testShellCommandGetsShortSpokenSummary() {
        let (summary, detail) = CursorToolSummary.render(
            toolName: "Shell",
            input: ["command": .string("swift test")]
        )

        XCTAssertEqual(summary, "run swift test")
        XCTAssertEqual(detail, "Run the command: swift test")
    }

    func testLongShellCommandIsBoundedAndNewlinesAreCollapsed() {
        let command = "for module in one two three four five six seven; do\nswift build\ndone"
        let (summary, detail) = CursorToolSummary.render(
            toolName: "Shell",
            input: ["command": .string(command)]
        )

        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.count, 64 + "run ".count + 1)
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertFalse(detail.contains("\n"))
        XCTAssertTrue(detail.contains("; "))
    }

    func testBlankShellCommandKeepsAGenericAction() {
        let (summary, detail) = CursorToolSummary.render(
            toolName: "Shell",
            input: ["command": .string("   ")]
        )

        XCTAssertEqual(summary, "run a command")
        XCTAssertEqual(detail, "Run a command")
    }

    func testWriteAndDeleteNameTheResolvedPath() {
        let write = CursorToolSummary.render(
            toolName: "Write",
            input: ["file_path": .string("/tmp/project/Sources/App.swift")]
        )
        XCTAssertEqual(write.summary, "write the file App.swift")
        XCTAssertEqual(write.detail, "Write the file at /tmp/project/Sources/App.swift")

        let delete = CursorToolSummary.render(
            toolName: "Delete",
            input: ["file_path": .string("/tmp/project/stale.txt")]
        )
        XCTAssertEqual(delete.summary, "delete the file stale.txt")
        XCTAssertEqual(delete.detail, "Delete the file at /tmp/project/stale.txt")
    }

    func testAlternatePathKeysAreAcceptedInDocumentedPriority() {
        let fallback = CursorToolSummary.render(
            toolName: "Write",
            input: ["target_file": .string("/tmp/project/legacy.swift")]
        )
        XCTAssertEqual(fallback.summary, "write the file legacy.swift")

        let preferred = CursorToolSummary.render(
            toolName: "Write",
            input: [
                "target_file": .string("/tmp/project/legacy.swift"),
                "path": .string("/tmp/project/second.swift"),
                "file_path": .string("/tmp/project/canonical.swift"),
            ]
        )
        XCTAssertEqual(preferred.summary, "write the file canonical.swift")
    }

    /// Cursor documents `tool_input` as an open object. A write payload can carry the whole
    /// new file body, so an unresolved path must degrade to a generic phrase rather than
    /// falling back to the argument object.
    func testUnresolvedPathNeverSpeaksTheArgumentObject() {
        let contents = "SECRET api key: tapq-secret-value"
        let (summary, detail) = CursorToolSummary.render(
            toolName: "Write",
            input: [
                "contents": .string(contents),
                "instructions": .string("Replace the credentials block."),
            ]
        )

        XCTAssertEqual(summary, "write a file")
        XCTAssertEqual(detail, "Write a file")
        for presentation in [summary, detail] {
            XCTAssertFalse(presentation.contains("tapq-secret-value"))
            XCTAssertFalse(presentation.contains("contents"))
        }
    }

    func testBlankPathValueIsTreatedAsUnresolved() {
        let (summary, _) = CursorToolSummary.render(
            toolName: "Delete",
            input: ["file_path": .string("  ")]
        )

        XCTAssertEqual(summary, "delete a file")
    }

    func testUnmanagedToolKeepsAValueFreeFallback() {
        let (summary, detail) = CursorToolSummary.render(
            toolName: "Read",
            input: ["file_path": .string("/tmp/project/private.env")]
        )

        XCTAssertEqual(summary, "use the Read tool")
        XCTAssertEqual(detail, "Use the Read tool")
        XCTAssertFalse(detail.contains("private.env"))

        let unnamed = CursorToolSummary.render(toolName: "", input: [:])
        XCTAssertEqual(unnamed.summary, "use the requested tool")
    }
}
