import XCTest
@testable import TapQOpenCodeAdapter
import TapQWireProtocol

final class OpenCodeToolSummaryTests: XCTestCase {
    private func render(
        _ permission: String,
        metadata: [String: JSONValue] = [:]
    ) -> (summary: String, detail: String) {
        OpenCodeToolSummary.render(permission: permission, metadata: metadata)
    }

    // MARK: - bash

    func testBashSpeaksTheCommand() {
        let rendered = render("bash", metadata: ["command": .string("npm test")])
        XCTAssertEqual(rendered.summary, "run npm test")
        XCTAssertEqual(rendered.detail, "Run the command: npm test")
    }

    func testBashWithoutACommandStaysGeneric() {
        let rendered = render("bash")
        XCTAssertEqual(rendered.summary, "run a command")
        XCTAssertEqual(rendered.detail, "Run a command")
    }

    func testBashSummaryIsShortenedWhileTheDetailKeepsMoreContext() {
        let command = "for f in one two three four five six seven; do echo $f; done"
        let rendered = render("bash", metadata: ["command": .string(command)])

        XCTAssertEqual(rendered.summary, "run for f in one two three…")
        XCTAssertEqual(rendered.detail, "Run the command: \(command)")
    }

    func testBashCollapsesNewlinesSoSpeechStaysOnOneLine() {
        let rendered = render("bash", metadata: ["command": .string("cd build\nmake all")])
        XCTAssertEqual(rendered.summary, "run cd build; make all")
        XCTAssertEqual(rendered.detail, "Run the command: cd build; make all")
    }

    // MARK: - edit

    func testEditSpeaksTheFileNameAndDetailsTheFullPath() {
        let rendered = render(
            "edit",
            metadata: ["filePath": .string("/work/project/src/main.swift")]
        )
        XCTAssertEqual(rendered.summary, "edit main.swift")
        XCTAssertEqual(rendered.detail, "Edit the file: /work/project/src/main.swift")
    }

    func testEditAcceptsThePathAliasAndFallsBackWithoutOne() {
        let aliased = render("edit", metadata: ["path": .string("/work/README.md")])
        XCTAssertEqual(aliased.summary, "edit README.md")
        XCTAssertEqual(aliased.detail, "Edit the file: /work/README.md")

        let bare = render("edit")
        XCTAssertEqual(bare.summary, "edit a file")
        XCTAssertEqual(bare.detail, "Edit a file")
    }

    // MARK: - webfetch

    func testWebfetchSpeaksOnlyTheHost() {
        let rendered = render(
            "webfetch",
            metadata: ["url": .string("https://example.com/docs?token=secret-value")]
        )

        XCTAssertEqual(rendered.summary, "fetch a page from example.com")
        XCTAssertEqual(rendered.detail, "Fetch a page from example.com")
        XCTAssertFalse(rendered.summary.contains("secret-value"))
        XCTAssertFalse(rendered.detail.contains("secret-value"))
        XCTAssertFalse(rendered.detail.contains("/docs"))
    }

    func testWebfetchWithoutAUsableURLStaysGeneric() {
        XCTAssertEqual(render("webfetch").summary, "fetch a web page")
        XCTAssertEqual(
            render("webfetch", metadata: ["url": .string("   ")]).detail,
            "Fetch a web page"
        )
    }

    // MARK: - Unrecognized kinds

    func testUnknownKindIsSpokenFromItsNameAlone() {
        let rendered = render(
            "external_directory",
            metadata: ["path": .string("/private/tapq-value-must-not-be-spoken")]
        )

        XCTAssertEqual(rendered.summary, "approve a external directory operation")
        XCTAssertEqual(rendered.detail, "Approve a external directory operation")
        XCTAssertFalse(rendered.detail.contains("must-not-be-spoken"))
    }

    func testUnknownKindNeverSerializesMetadata() {
        let rendered = render(
            "websearch",
            metadata: [
                "query": .string("tapq-value-must-not-be-spoken"),
                "nested": .object(["inner": .string("also-secret")]),
            ]
        )

        XCTAssertEqual(rendered.summary, "approve a websearch operation")
        XCTAssertEqual(rendered.detail, "Approve a websearch operation")
        XCTAssertFalse(rendered.detail.contains("must-not-be-spoken"))
        XCTAssertFalse(rendered.detail.contains("also-secret"))
    }

    func testNonStringMetadataIsNeverFlattenedIntoRecognizedKinds() {
        let rendered = render(
            "bash",
            metadata: ["command": .object(["unexpected": .string("shape")])]
        )

        XCTAssertEqual(rendered.summary, "run a command")
        XCTAssertFalse(rendered.detail.contains("unexpected"))
    }

    func testEmptyOrPunctuationOnlyKindStaysNeutral() {
        for permission in ["", "   ", "___"] {
            let rendered = render(permission)
            XCTAssertEqual(rendered.summary, "approve a requested operation", permission)
            XCTAssertEqual(rendered.detail, "Approve a requested operation", permission)
        }
    }

    func testLongKindNamesAreBounded() {
        let rendered = render(String(repeating: "kind_", count: 100))

        XCTAssertLessThanOrEqual(rendered.summary.count, 64)
        XCTAssertLessThanOrEqual(rendered.detail.count, 240)
        XCTAssertTrue(rendered.summary.hasSuffix("…"))
        XCTAssertTrue(rendered.detail.hasSuffix("…"))
    }
}
