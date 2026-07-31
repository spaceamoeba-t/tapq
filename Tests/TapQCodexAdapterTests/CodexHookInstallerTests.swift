import XCTest
@testable import TapQCodexAdapter
import TapQPOSIXSupport
import TapQWireProtocol
import TapQContracts

private enum IntentionalCodexWriteFailure: Error {
    case replacement
}

private final class CodexReplacementFailingWriter: SecureAtomicFileWriting {
    private let underlying = POSIXSecureAtomicFileWriter()

    func write(
        _ data: Data,
        to destination: URL,
        mode: UInt16,
        disposition: SecureAtomicWriteDisposition
    ) throws {
        switch disposition {
        case .createNew:
            try underlying.write(
                data,
                to: destination,
                mode: mode,
                disposition: disposition
            )
        case .replaceExisting:
            throw IntentionalCodexWriteFailure.replacement
        }
    }
}

final class CodexHookInstallerTests: XCTestCase {
    private var directory: URL!
    private var hooksURL: URL!
    private let command = "/Users/example/Library/Application Support/TapQ/tapq-codex-hook"
    private var quotedCommand: String { CodexHookInstaller.shellQuoted(command) }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        hooksURL = directory.appendingPathComponent("hooks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func installer(
        hooksURL: URL? = nil,
        command: String? = nil
    ) -> CodexHookInstaller {
        CodexHookInstaller(
            hooksURL: hooksURL ?? self.hooksURL,
            hookCommand: command ?? self.command
        )
    }

    private func read() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: hooksURL)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func permissions(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value & 0o777
    }

    private func backupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: hooksURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("tapq-backup") }
    }

    private func tapQHandlers(
        event: String,
        in hooks: [String: JSONValue]
    ) -> [JSONValue] {
        (hooks[event]?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).filter {
                $0["command"]?.stringValue == quotedCommand
            }
        }
    }

    func testDefaultURLAndExecutableName() {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        XCTAssertEqual(
            CodexHookInstaller.codexHooksURL(homeDirectory: home),
            home.appendingPathComponent(".codex/hooks.json")
        )

        let defaulted = CodexHookInstaller(hooksURL: hooksURL)
        XCTAssertEqual(defaulted.hookCommand, "tapq-codex-hook")
        XCTAssertEqual(CodexHookInstaller.trustCommand, "/hooks")
    }

    func testInstallCreatesStableQuestionPermissionAndStopHooks() throws {
        let report = try installer().install()
        let root = try read()
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)

        let preToolUse = try XCTUnwrap(hooks["PreToolUse"]?.arrayValue?.first)
        XCTAssertEqual(preToolUse["matcher"]?.stringValue, "^request_user_input$")
        let questionHook = try XCTUnwrap(preToolUse["hooks"]?.arrayValue?.first)
        XCTAssertEqual(questionHook["type"]?.stringValue, "command")
        XCTAssertEqual(questionHook["command"]?.stringValue, quotedCommand)
        if case .number(let timeout)? = questionHook["timeout"] {
            XCTAssertEqual(timeout, InteractionBudget.hookTimeout)
        } else {
            XCTFail("PreToolUse timeout is missing")
        }

        let permission = try XCTUnwrap(hooks["PermissionRequest"]?.arrayValue?.first)
        XCTAssertEqual(permission["matcher"]?.stringValue, "^(Bash|apply_patch)$")
        let permissionHook = try XCTUnwrap(permission["hooks"]?.arrayValue?.first)
        XCTAssertEqual(permissionHook["type"]?.stringValue, "command")
        XCTAssertEqual(permissionHook["command"]?.stringValue, quotedCommand)
        if case .number(let timeout)? = permissionHook["timeout"] {
            XCTAssertEqual(timeout, InteractionBudget.hookTimeout)
        } else {
            XCTFail("PermissionRequest timeout is missing")
        }

        let stop = try XCTUnwrap(hooks["Stop"]?.arrayValue?.first)
        XCTAssertNil(stop["matcher"])
        let stopHook = try XCTUnwrap(stop["hooks"]?.arrayValue?.first)
        XCTAssertEqual(stopHook["command"]?.stringValue, quotedCommand)
        if case .number(let timeout)? = stopHook["timeout"] {
            XCTAssertEqual(timeout, InteractionBudget.hookTimeout)
        } else {
            XCTFail("Stop timeout is missing")
        }

        XCTAssertEqual(report.status, .installed)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.trustAction, .reviewRequired)
        XCTAssertEqual(report.trustAction.command, "/hooks")
        XCTAssertTrue(report.trustAction.message?.contains("skips new or changed") == true)
        XCTAssertTrue(installer().isInstalled())
        XCTAssertEqual(installer().installationStatus(), .installed)
        XCTAssertEqual(try permissions(at: hooksURL), 0o600)
    }

    func testInstallCreatesMissingDirectoryWithOwnerOnlyPermissions() throws {
        let nested = directory
            .appendingPathComponent("missing-codex", isDirectory: true)
            .appendingPathComponent("hooks.json")

        try installer(hooksURL: nested).install()

        XCTAssertEqual(try permissions(at: nested.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: nested), 0o600)
    }

    func testInstallPreservesUnrelatedJSONEventsGroupsAndHandlers() throws {
        let existing = """
        {
          "description":"user lifecycle configuration",
          "metadata":{"owner":"user"},
          "hooks":{
            "SessionStart":[{"matcher":"startup","hooks":[
              {"type":"command","command":"/usr/bin/session-notes","timeout":8}
            ]}],
            "PermissionRequest":[{"matcher":"mcp__custom__.*","hooks":[
              {"type":"command","command":"/usr/bin/custom-approval","timeout":20}
            ]}],
            "PreToolUse":[{"matcher":"custom_tool","hooks":[
              {"type":"command","command":"/usr/bin/custom-pre-tool","timeout":20}
            ]}],
            "Stop":[{"hooks":[
              {"type":"command","command":"/usr/bin/user-stop","timeout":10}
            ]}]
          }
        }
        """
        try Data(existing.utf8).write(to: hooksURL)

        try installer().install()

        let root = try read()
        XCTAssertEqual(root["description"]?.stringValue, "user lifecycle configuration")
        XCTAssertEqual(root["metadata"]?["owner"]?.stringValue, "user")
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertEqual(
            hooks["SessionStart"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/session-notes"
        )
        let permissionCommands = (hooks["PermissionRequest"]?.arrayValue ?? []).flatMap {
            ($0["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(permissionCommands.contains("/usr/bin/custom-approval"))
        XCTAssertTrue(permissionCommands.contains(quotedCommand))
        let preToolCommands = (hooks["PreToolUse"]?.arrayValue ?? []).flatMap {
            ($0["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(preToolCommands.contains("/usr/bin/custom-pre-tool"))
        XCTAssertTrue(preToolCommands.contains(quotedCommand))
        let stopCommands = (hooks["Stop"]?.arrayValue ?? []).flatMap {
            ($0["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(stopCommands.contains("/usr/bin/user-stop"))
        XCTAssertTrue(stopCommands.contains(quotedCommand))
    }

    func testRepeatedInstallDoesNotRewriteOrDuplicateHooks() throws {
        let first = try installer().install()
        let firstBytes = try Data(contentsOf: hooksURL)
        let second = try installer().install()

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.trustAction, .verifyInCodex)
        XCTAssertEqual(try Data(contentsOf: hooksURL), firstBytes)
        XCTAssertTrue(try backupURLs().isEmpty)

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQHandlers(event: "PreToolUse", in: hooks).count, 1)
        XCTAssertEqual(tapQHandlers(event: "PermissionRequest", in: hooks).count, 1)
        XCTAssertEqual(tapQHandlers(event: "Stop", in: hooks).count, 1)
    }

    func testStatusDetectsIncompleteStaleAndMalformedLayouts() throws {
        XCTAssertEqual(installer().installationStatus(), .notInstalled)
        XCTAssertEqual(installer().statusReport().trustAction, .none)

        let incomplete = """
        {"hooks":{"PermissionRequest":[{"matcher":"^(Bash|apply_patch)$","hooks":[
          {"type":"command","command":"\(quotedCommand)","timeout":120}
        ]}]}}
        """
        try Data(incomplete.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)
        XCTAssertEqual(installer().statusReport().trustAction, .verifyInCodex)

        let previous = CodexHookInstaller.shellQuoted(
            "/Applications/TapQRuntime.app/Contents/MacOS/tapq-codex-hook"
        )
        let stale = """
        {"hooks":{
          "PermissionRequest":[{"matcher":"^(Bash|apply_patch)$","hooks":[
            {"type":"command","command":"\(previous)","timeout":120}
          ]}],
          "Stop":[{"hooks":[
            {"type":"command","command":"\(previous)","timeout":120}
          ]}]
        }}
        """
        try Data(stale.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)

        try Data(#"{"hooks":"invalid"}"#.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)
    }

    func testInstallMigratesRecognizedPreviousPathWithoutDuplicates() throws {
        let previous = CodexHookInstaller.shellQuoted(
            "/Applications/TapQRuntime.app/Contents/MacOS/tapq-codex-hook"
        )
        let existing = """
        {"hooks":{
          "PermissionRequest":[{"matcher":"Bash","hooks":[
            {"type":"command","command":"\(previous)","timeout":120}
          ]}],
          "Stop":[{"hooks":[
            {"type":"command","command":"\(previous)","timeout":120},
            {"type":"command","command":"/usr/bin/user-stop","timeout":5}
          ]}]
        }}
        """
        try Data(existing.utf8).write(to: hooksURL)

        try installer().install()

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQHandlers(event: "PreToolUse", in: hooks).count, 1)
        XCTAssertEqual(tapQHandlers(event: "PermissionRequest", in: hooks).count, 1)
        XCTAssertEqual(tapQHandlers(event: "Stop", in: hooks).count, 1)
        let allCommands = hooks.values.flatMap { event in
            (event.arrayValue ?? []).flatMap { group in
                (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
        }
        XCTAssertFalse(allCommands.contains(previous))
        XCTAssertTrue(allCommands.contains("/usr/bin/user-stop"))
        XCTAssertEqual(installer().installationStatus(), .installed)
    }

    func testUninstallRemovesOnlyTapQHandlersIncludingSharedGroups() throws {
        let existing = """
        {
          "description":"keep me",
          "hooks":{
            "PermissionRequest":[{
              "matcher":"^(Bash|apply_patch)$",
              "hooks":[
                {"type":"command","command":"\(quotedCommand)","timeout":120},
                {"type":"command","command":"/usr/bin/user-audit","timeout":5}
              ]
            }],
            "PreToolUse":[{
              "matcher":"^request_user_input$",
              "hooks":[
                {"type":"command","command":"\(quotedCommand)","timeout":120},
                {"type":"command","command":"/usr/bin/user-question-audit","timeout":5}
              ]
            }],
            "Stop":[{"hooks":[
              {"type":"command","command":"\(quotedCommand)","timeout":120}
            ]}],
            "PostToolUse":[{"matcher":"Bash","hooks":[
              {"type":"command","command":"/usr/bin/post","timeout":5}
            ]}]
          }
        }
        """
        try Data(existing.utf8).write(to: hooksURL)

        let report = try installer().uninstall()

        let root = try read()
        XCTAssertEqual(root["description"]?.stringValue, "keep me")
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertNil(hooks["Stop"])
        XCTAssertEqual(
            hooks["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/user-question-audit"
        )
        XCTAssertEqual(
            hooks["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/user-audit"
        )
        XCTAssertEqual(
            hooks["PostToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/post"
        )
        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.trustAction, .none)
        XCTAssertFalse(installer().isInstalled())
    }

    func testUninstallWithoutManagedHooksIsByteForByteNoOp() throws {
        let original = Data(#"{"description":"user","hooks":{}}"#.utf8)
        try original.write(to: hooksURL)

        let report = try installer().uninstall()

        XCTAssertFalse(report.didChange)
        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: hooksURL), original)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    func testMutationsCreateRestrictiveExactBackups() throws {
        let original = Data(#"{"description":"before"}"#.utf8)
        try original.write(to: hooksURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: hooksURL.path
        )

        try installer().install()

        let backup = try XCTUnwrap(backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
        XCTAssertEqual(try permissions(at: hooksURL), 0o600)
    }

    func testInvalidManagedShapesThrowWithoutChangingOriginal() throws {
        let badRoot = Data(#"{"description":"keep","hooks":"invalid"}"#.utf8)
        try badRoot.write(to: hooksURL)

        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? CodexHookInstallerError, .hooksMustBeObject)
        }
        XCTAssertEqual(try Data(contentsOf: hooksURL), badRoot)
        XCTAssertTrue(try backupURLs().isEmpty)

        let badEvent = Data(#"{"hooks":{"PermissionRequest":{}}}"#.utf8)
        try badEvent.write(to: hooksURL)
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(
                error as? CodexHookInstallerError,
                .eventMustBeArray("PermissionRequest")
            )
        }
        XCTAssertEqual(try Data(contentsOf: hooksURL), badEvent)
    }

    func testReplacementFailurePreservesOriginalAndPublishesBackup() throws {
        let original = Data(#"{"description":"original","custom":true}"#.utf8)
        try original.write(to: hooksURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o640))],
            ofItemAtPath: hooksURL.path
        )
        let failing = CodexHookInstaller(
            hooksURL: hooksURL,
            hookCommand: command,
            fileWriter: CodexReplacementFailingWriter()
        )

        XCTAssertThrowsError(try failing.install())

        XCTAssertEqual(try Data(contentsOf: hooksURL), original)
        XCTAssertEqual(try permissions(at: hooksURL), 0o640)
        let backup = try XCTUnwrap(backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
    }

    func testShellQuotesEmbeddedSingleQuote() {
        XCTAssertEqual(
            CodexHookInstaller.shellQuoted("/tmp/TapQ's hook"),
            "'/tmp/TapQ'\\''s hook'"
        )
    }
}
