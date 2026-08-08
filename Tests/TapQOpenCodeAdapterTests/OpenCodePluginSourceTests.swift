import XCTest
@testable import TapQOpenCodeAdapter

/// The generated plugin is the only part of the adapter that runs outside Swift, so these
/// assert the pieces that must match OpenCode's documented plugin and permission contract.
final class OpenCodePluginSourceTests: XCTestCase {
    private let command = "/Users/example/Library/Application Support/TapQ/tapq-opencode-hook"

    private var rendered: String {
        OpenCodePluginSource.render(hookCommand: command)
    }

    func testRenderIsDeterministicAndMarkedAsManaged() {
        XCTAssertEqual(rendered, rendered)
        XCTAssertTrue(rendered.hasPrefix(OpenCodePluginSource.marker))
        XCTAssertTrue(OpenCodePluginSource.isManagedPlugin(rendered))
        XCTAssertTrue(
            OpenCodePluginSource.markerLine().contains("v\(OpenCodePluginSource.version)")
        )
        XCTAssertTrue(rendered.hasSuffix("\n"))
    }

    func testForeignContentIsNotRecognizedAsManaged() {
        XCTAssertFalse(OpenCodePluginSource.isManagedPlugin(""))
        XCTAssertFalse(
            OpenCodePluginSource.isManagedPlugin("export const Mine = async () => ({})\n")
        )
        // The marker must lead the file; a mention further down is not ownership.
        XCTAssertFalse(
            OpenCodePluginSource.isManagedPlugin("// mine\n\(OpenCodePluginSource.marker)\n")
        )
    }

    func testPluginExportsTheOpenCodeHookShape() {
        XCTAssertTrue(rendered.contains("export const TapQ = async (input) =>"))
        XCTAssertTrue(rendered.contains("event: async ({ event }) =>"))
        XCTAssertTrue(rendered.contains(#"import { spawn } from "node:child_process""#))
    }

    func testPluginSubscribesToTheSupportedEventsAndNoOthers() {
        XCTAssertTrue(rendered.contains(#"event.type === "permission.asked""#))
        XCTAssertTrue(rendered.contains(#"event.type === "session.idle""#))
        XCTAssertTrue(rendered.contains(#"event.type === "session.status""#))
        // The inert `permission.ask` hook must not be relied on.
        XCTAssertFalse(rendered.contains(#""permission.ask":"#))
    }

    func testPluginRepliesOnceOrRejectAndNeverAlways() {
        XCTAssertTrue(rendered.contains(#""once" : "reject""#))
        XCTAssertFalse(rendered.contains(#""always""#))
    }

    func testPluginUsesBothDocumentedReplyRoutes() {
        XCTAssertTrue(rendered.contains(#""/permission/" + encodeURIComponent(permissionID) + "/reply""#))
        XCTAssertTrue(rendered.contains("client.postSessionIdPermissionsPermissionId"))
    }

    func testPluginTimeoutOutlastsTheBrokerInteractionBudget() {
        XCTAssertTrue(rendered.contains("const PERMISSION_TIMEOUT_MS = 265000"))
        XCTAssertGreaterThan(265.0, OpenCodeHookShim.approvalTimeout)
    }

    func testPluginDeclaresTheCurrentRelayVersion() {
        XCTAssertTrue(
            rendered.contains("const RELAY_VERSION = \(OpenCodeHookShim.relayVersion)")
        )
    }

    func testHookPathIsEmbeddedAsAQuotedLiteral() {
        XCTAssertTrue(rendered.contains("const HOOK = \"\(command)\""))

        let awkward = OpenCodePluginSource.render(
            hookCommand: #"/tmp/TapQ's "hook"\path"#
        )
        XCTAssertTrue(
            awkward.contains(#"const HOOK = "/tmp/TapQ's \"hook\"\\path""#)
        )
    }

    func testStringLiteralEscapesEveryJavaScriptHazard() {
        XCTAssertEqual(OpenCodePluginSource.javaScriptStringLiteral("plain"), "\"plain\"")
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("a\\b"),
            #""a\\b""#
        )
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("a\"b"),
            #""a\"b""#
        )
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("a\nb\rc\td"),
            #""a\nb\rc\td""#
        )
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("a\u{0}b\u{7F}c"),
            #""a\u0000b\u007Fc""#
        )
        // U+2028/U+2029 terminate a JavaScript line but not a Swift one.
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("a\u{2028}b\u{2029}c"),
            #""a\u2028b\u2029c""#
        )
        XCTAssertEqual(
            OpenCodePluginSource.javaScriptStringLiteral("café"),
            "\"café\""
        )
    }

    func testGeneratedPluginContainsNoUnescapedLineTerminatorsInsideTheHookLiteral() throws {
        let awkward = OpenCodePluginSource.render(hookCommand: "/tmp/one\ntwo")
        let hookLine = try XCTUnwrap(
            awkward.split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.hasPrefix("const HOOK = ") }
        )
        XCTAssertEqual(hookLine, #"const HOOK = "/tmp/one\ntwo""#)
    }
}
