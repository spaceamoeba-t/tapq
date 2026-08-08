import XCTest
import TapQContracts
@testable import TapQCursorAdapter
import TapQPOSIXSupport
import TapQWireProtocol

private enum IntentionalCursorWriteFailure: Error {
    case replacement
}

private final class CursorReplacementFailingWriter: SecureAtomicFileWriting {
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
            throw IntentionalCursorWriteFailure.replacement
        }
    }
}

final class CursorHookInstallerTests: XCTestCase {
    private var directory: URL!
    private var hooksURL: URL!
    private let command = "/Users/example/Library/Application Support/TapQ/tapq-cursor-hook"
    private var quotedCommand: String { CursorHookInstaller.shellQuoted(command) }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-cursor-hooks-\(UUID().uuidString)", isDirectory: true)
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
    ) -> CursorHookInstaller {
        CursorHookInstaller(
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

    private func tapQEntries(
        event: String,
        in hooks: [String: JSONValue]
    ) -> [JSONValue] {
        (hooks[event]?.arrayValue ?? []).filter {
            $0["command"]?.stringValue == quotedCommand
        }
    }

    func testDefaultURLAndExecutableName() {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        XCTAssertEqual(
            CursorHookInstaller.cursorHooksURL(homeDirectory: home),
            home.appendingPathComponent(".cursor/hooks.json")
        )

        let defaulted = CursorHookInstaller(hooksURL: hooksURL)
        XCTAssertEqual(defaulted.hookCommand, "tapq-cursor-hook")
    }

    func testInstallCreatesShellWriteDeleteAndStopEntries() throws {
        let report = try installer().install()
        let root = try read()
        XCTAssertEqual(root["version"]?.intValue, 1)
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)

        let shellEntries = try XCTUnwrap(hooks["beforeShellExecution"]?.arrayValue)
        XCTAssertEqual(shellEntries.count, 1)
        let shell = shellEntries[0]
        XCTAssertNil(shell["matcher"])
        XCTAssertEqual(shell["type"]?.stringValue, "command")
        XCTAssertEqual(shell["command"]?.stringValue, quotedCommand)
        if case .number(let timeout)? = shell["timeout"] {
            XCTAssertEqual(timeout, InteractionBudget.hookTimeout)
        } else {
            XCTFail("beforeShellExecution timeout is missing")
        }

        let preToolUse = try XCTUnwrap(hooks["preToolUse"]?.arrayValue)
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertEqual(
            Set(preToolUse.compactMap { $0["matcher"]?.stringValue }),
            ["Write", "Delete"]
        )
        for entry in preToolUse {
            XCTAssertEqual(entry["type"]?.stringValue, "command")
            XCTAssertEqual(entry["command"]?.stringValue, quotedCommand)
            if case .number(let timeout)? = entry["timeout"] {
                XCTAssertEqual(timeout, InteractionBudget.hookTimeout)
            } else {
                XCTFail("preToolUse timeout is missing")
            }
        }

        let stopEntries = try XCTUnwrap(hooks["stop"]?.arrayValue)
        XCTAssertEqual(stopEntries.count, 1)
        XCTAssertNil(stopEntries[0]["matcher"])
        XCTAssertEqual(stopEntries[0]["command"]?.stringValue, quotedCommand)
        if case .number(let timeout)? = stopEntries[0]["timeout"] {
            XCTAssertEqual(timeout, 8)
        } else {
            XCTFail("stop timeout is missing")
        }

        // Events Cursor exposes but TapQ deliberately leaves alone.
        for unmanaged in [
            "beforeMCPExecution", "beforeReadFile", "beforeSubmitPrompt",
            "afterFileEdit", "sessionStart", "beforeTabFileRead",
        ] {
            XCTAssertNil(hooks[unmanaged], "\(unmanaged) must stay out of the slice")
        }

        XCTAssertEqual(report.status, .installed)
        XCTAssertTrue(report.didChange)
        XCTAssertTrue(installer().isInstalled())
        XCTAssertEqual(installer().installationStatus(), .installed)
        XCTAssertEqual(try permissions(at: hooksURL), 0o600)
    }

    func testInstallCreatesMissingDirectoryWithOwnerOnlyPermissions() throws {
        let nested = directory
            .appendingPathComponent("missing-cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")

        try installer(hooksURL: nested).install()

        XCTAssertEqual(try permissions(at: nested.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: nested), 0o600)
    }

    func testInstallPreservesUnrelatedJSONEventsAndEntries() throws {
        let existing = """
        {
          "version":1,
          "description":"user hook configuration",
          "metadata":{"owner":"user"},
          "hooks":{
            "sessionStart":[{"command":"./hooks/session-init.sh"}],
            "beforeShellExecution":[{"command":"./hooks/audit.sh","matcher":"^git push"}],
            "preToolUse":[{"command":"/usr/bin/custom-pre-tool","matcher":"Read"}],
            "stop":[{"command":"/usr/bin/user-stop","timeout":10}],
            "afterFileEdit":[{"command":"./hooks/format.sh"}]
          }
        }
        """
        try Data(existing.utf8).write(to: hooksURL)

        try installer().install()

        let root = try read()
        XCTAssertEqual(root["description"]?.stringValue, "user hook configuration")
        XCTAssertEqual(root["metadata"]?["owner"]?.stringValue, "user")
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertEqual(
            hooks["sessionStart"]?.arrayValue?.first?["command"]?.stringValue,
            "./hooks/session-init.sh"
        )
        XCTAssertEqual(
            hooks["afterFileEdit"]?.arrayValue?.first?["command"]?.stringValue,
            "./hooks/format.sh"
        )
        for (event, preserved) in [
            ("beforeShellExecution", "./hooks/audit.sh"),
            ("preToolUse", "/usr/bin/custom-pre-tool"),
            ("stop", "/usr/bin/user-stop"),
        ] {
            let commands = (hooks[event]?.arrayValue ?? [])
                .compactMap { $0["command"]?.stringValue }
            XCTAssertTrue(commands.contains(preserved), "\(event) lost unrelated data")
            XCTAssertTrue(commands.contains(quotedCommand), "\(event) missing TapQ entry")
        }
    }

    func testInstallKeepsAnExistingSchemaVersionUntouched() throws {
        try Data(#"{"version":2,"hooks":{}}"#.utf8).write(to: hooksURL)

        try installer().install()

        XCTAssertEqual(try read()["version"]?.intValue, 2)
    }

    func testRepeatedInstallDoesNotRewriteOrDuplicateHooks() throws {
        let first = try installer().install()
        let firstBytes = try Data(contentsOf: hooksURL)
        let second = try installer().install()

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(try Data(contentsOf: hooksURL), firstBytes)
        XCTAssertTrue(try backupURLs().isEmpty)

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQEntries(event: "beforeShellExecution", in: hooks).count, 1)
        XCTAssertEqual(tapQEntries(event: "preToolUse", in: hooks).count, 2)
        XCTAssertEqual(tapQEntries(event: "stop", in: hooks).count, 1)
    }

    func testStatusDetectsIncompleteStaleAndMalformedLayouts() throws {
        XCTAssertEqual(installer().installationStatus(), .notInstalled)
        XCTAssertEqual(installer().statusReport().status, .notInstalled)

        let incomplete = """
        {"version":1,"hooks":{"beforeShellExecution":[
          {"type":"command","command":"\(quotedCommand)","timeout":260}
        ]}}
        """
        try Data(incomplete.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)

        let previous = CursorHookInstaller.shellQuoted(
            "/Applications/TapQRuntime.app/Contents/MacOS/tapq-cursor-hook"
        )
        let stale = """
        {"version":1,"hooks":{
          "beforeShellExecution":[{"type":"command","command":"\(previous)","timeout":260}],
          "stop":[{"type":"command","command":"\(previous)","timeout":8}]
        }}
        """
        try Data(stale.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)

        try Data(#"{"hooks":"invalid"}"#.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)
    }

    func testInstallRepairsAnIncompleteLayoutWithoutDuplicating() throws {
        let partial = """
        {"version":1,"hooks":{
          "beforeShellExecution":[
            {"type":"command","command":"\(quotedCommand)","timeout":\(InteractionBudget.hookTimeout)}
          ],
          "preToolUse":[
            {"type":"command","command":"\(quotedCommand)","timeout":\(InteractionBudget.hookTimeout),"matcher":"Write"}
          ]
        }}
        """
        try Data(partial.utf8).write(to: hooksURL)
        XCTAssertEqual(installer().installationStatus(), .partial)

        let report = try installer().install()

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQEntries(event: "beforeShellExecution", in: hooks).count, 1)
        XCTAssertEqual(tapQEntries(event: "preToolUse", in: hooks).count, 2)
        XCTAssertEqual(tapQEntries(event: "stop", in: hooks).count, 1)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.status, .installed)
        XCTAssertEqual(installer().installationStatus(), .installed)
    }

    func testInstallMigratesRecognizedPreviousPathWithoutDuplicates() throws {
        let previous = CursorHookInstaller.shellQuoted(
            "/Applications/TapQRuntime.app/Contents/MacOS/tapq-cursor-hook"
        )
        let existing = """
        {"version":1,"hooks":{
          "beforeShellExecution":[{"type":"command","command":"\(previous)","timeout":260}],
          "stop":[
            {"type":"command","command":"\(previous)","timeout":8},
            {"type":"command","command":"/usr/bin/user-stop","timeout":5}
          ]
        }}
        """
        try Data(existing.utf8).write(to: hooksURL)

        try installer().install()

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQEntries(event: "beforeShellExecution", in: hooks).count, 1)
        XCTAssertEqual(tapQEntries(event: "preToolUse", in: hooks).count, 2)
        XCTAssertEqual(tapQEntries(event: "stop", in: hooks).count, 1)
        let allCommands = hooks.values.flatMap { event in
            (event.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertFalse(allCommands.contains(previous))
        XCTAssertTrue(allCommands.contains("/usr/bin/user-stop"))
        XCTAssertEqual(installer().installationStatus(), .installed)
    }

    func testUnfamiliarCustomHookPathsArePreservedAsUnrelated() throws {
        let custom = "'/opt/team/tapq-cursor-hook'"
        let existing = """
        {"version":1,"hooks":{"stop":[
          {"type":"command","command":"\(custom)","timeout":8}
        ]}}
        """
        try Data(existing.utf8).write(to: hooksURL)

        try installer().install()

        let hooks = try XCTUnwrap(try read()["hooks"]?.objectValue)
        let stopCommands = (hooks["stop"]?.arrayValue ?? [])
            .compactMap { $0["command"]?.stringValue }
        XCTAssertTrue(stopCommands.contains(custom))
        XCTAssertTrue(stopCommands.contains(quotedCommand))
    }

    func testUninstallRemovesOnlyTapQEntries() throws {
        let existing = """
        {
          "version":1,
          "description":"keep me",
          "hooks":{
            "beforeShellExecution":[
              {"type":"command","command":"\(quotedCommand)","timeout":260},
              {"type":"command","command":"/usr/bin/user-audit","timeout":5}
            ],
            "preToolUse":[
              {"type":"command","command":"\(quotedCommand)","timeout":260,"matcher":"Write"},
              {"type":"command","command":"\(quotedCommand)","timeout":260,"matcher":"Delete"}
            ],
            "stop":[{"type":"command","command":"\(quotedCommand)","timeout":8}],
            "afterFileEdit":[{"command":"/usr/bin/format"}]
          }
        }
        """
        try Data(existing.utf8).write(to: hooksURL)

        let report = try installer().uninstall()

        let root = try read()
        XCTAssertEqual(root["description"]?.stringValue, "keep me")
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertNil(hooks["stop"])
        XCTAssertNil(hooks["preToolUse"])
        XCTAssertEqual(
            hooks["beforeShellExecution"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/user-audit"
        )
        XCTAssertEqual(
            hooks["afterFileEdit"]?.arrayValue?.first?["command"]?.stringValue,
            "/usr/bin/format"
        )
        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertTrue(report.didChange)
        XCTAssertFalse(installer().isInstalled())
    }

    func testUninstallWithoutManagedHooksIsByteForByteNoOp() throws {
        let original = Data(#"{"version":1,"hooks":{}}"#.utf8)
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
            XCTAssertEqual(error as? CursorHookInstallerError, .hooksMustBeObject)
        }
        XCTAssertEqual(try Data(contentsOf: hooksURL), badRoot)
        XCTAssertTrue(try backupURLs().isEmpty)

        let badEvent = Data(#"{"hooks":{"beforeShellExecution":{}}}"#.utf8)
        try badEvent.write(to: hooksURL)
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(
                error as? CursorHookInstallerError,
                .eventMustBeArray("beforeShellExecution")
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
        let failing = CursorHookInstaller(
            hooksURL: hooksURL,
            hookCommand: command,
            fileWriter: CursorReplacementFailingWriter()
        )

        XCTAssertThrowsError(try failing.install())

        XCTAssertEqual(try Data(contentsOf: hooksURL), original)
        XCTAssertEqual(try permissions(at: hooksURL), 0o640)
        let backup = try XCTUnwrap(backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
    }

    /// Cursor accepts a command line, not a bare path, so an install path containing a
    /// space or a quote has to survive the round trip.
    func testShellQuotesEmbeddedSingleQuote() {
        XCTAssertEqual(
            CursorHookInstaller.shellQuoted("/tmp/TapQ's hook"),
            "'/tmp/TapQ'\\''s hook'"
        )
    }
}
