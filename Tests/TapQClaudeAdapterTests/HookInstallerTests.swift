import XCTest
@testable import TapQClaudeAdapter
import TapQPOSIXSupport
import TapQWireProtocol
import TapQContracts

private enum IntentionalSecureWriteFailure: Error {
    case replacement
}

private final class ReplacementFailingWriter: SecureAtomicFileWriting {
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
            throw IntentionalSecureWriteFailure.replacement
        }
    }
}

final class HookInstallerTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private let command = "/Users/x/Library/Application Support/TapQ/tapq-hook"
    /// The form actually written into settings.json: the path, shell-quoted.
    private var quoted: String { HookInstaller.shellQuoted(command) }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func read() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: settings)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func installer(policy: ClaudePermissionPolicy = .strict) -> HookInstaller {
        HookInstaller(settingsURL: settings, hookCommand: command, policy: policy)
    }

    private func permissions(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value & 0o777
    }

    private func backupURLs(in directory: URL? = nil) throws -> [URL] {
        let directory = directory ?? dir!
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("tapq-backup") }
    }

    private func tapQCommandCount(
        event: String,
        in hooks: [String: JSONValue]
    ) -> Int {
        (hooks[event]?.arrayValue ?? []).reduce(into: 0) { count, group in
            count += (group["hooks"]?.arrayValue ?? []).filter {
                $0["command"]?.stringValue == quoted
            }.count
        }
    }

    func testInstallIntoMissingFileCreatesAllFourHooks() throws {
        try installer().install()
        let root = try read()
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)

        let pre = try XCTUnwrap(hooks["PreToolUse"]?.arrayValue?.first)
        XCTAssertEqual(pre["matcher"]?.stringValue, "Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion")
        let preHook = try XCTUnwrap(pre["hooks"]?.arrayValue?.first)
        XCTAssertEqual(preHook["command"]?.stringValue, quoted)
        XCTAssertEqual(preHook["type"]?.stringValue, "command")
        if case .number(let t)? = preHook["timeout"] { XCTAssertEqual(t, 120) } else { XCTFail("timeout") }

        let note = try XCTUnwrap(hooks["Notification"]?.arrayValue?.first)
        XCTAssertEqual(note["matcher"]?.stringValue, "idle_prompt|permission_prompt")

        let stop = try XCTUnwrap(hooks["Stop"]?.arrayValue?.first)
        XCTAssertNil(stop["matcher"])      // Stop has no matcher
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertEqual(installer().installationStatus(), .strict)
        XCTAssertTrue(installer().isInstalled())
        XCTAssertEqual(try permissions(at: settings), 0o600)
    }

    func testInstallCreatesMissingSettingsDirectoryWithOwnerOnlyPermissions() throws {
        let nestedSettings = dir
            .appendingPathComponent("missing-claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        try HookInstaller(settingsURL: nestedSettings, hookCommand: command).install()

        XCTAssertEqual(
            try permissions(at: nestedSettings.deletingLastPathComponent()),
            0o700
        )
        XCTAssertEqual(try permissions(at: nestedSettings), 0o600)
    }

    func testInstallDoesNotChangeExistingCustomDirectoryPermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o755))],
            ofItemAtPath: dir.path
        )

        try installer().install()

        XCTAssertEqual(try permissions(at: dir), 0o755)
        XCTAssertEqual(try permissions(at: settings), 0o600)
    }

    func testNativeInstallSplitsQuestionSelectionFromOrdinaryPermissionRequests() throws {
        try installer(policy: .native).install()
        let hooks = try XCTUnwrap(read()["hooks"]?.objectValue)

        let pre = try XCTUnwrap(hooks["PreToolUse"]?.arrayValue?.first)
        XCTAssertEqual(pre["matcher"]?.stringValue, "AskUserQuestion")
        XCTAssertEqual(tapQCommandCount(event: "PreToolUse", in: hooks), 1)

        let permission = try XCTUnwrap(hooks["PermissionRequest"]?.arrayValue?.first)
        XCTAssertEqual(permission["matcher"]?.stringValue, "Bash|Write|Edit|MultiEdit|NotebookEdit")
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 1)

        XCTAssertEqual(installer().installationStatus(), .native)
        XCTAssertFalse(installer().isInstalled(), "isInstalled is relative to the selected policy")
        XCTAssertTrue(installer(policy: .native).isInstalled())
    }

    func testExistingPrePolicyLayoutIsDetectedAsStrict() throws {
        let existing = """
        {"hooks":{
          "PreToolUse":[{"matcher":"Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion","hooks":[{"type":"command","command":"\(quoted)","timeout":120}]}],
          "Notification":[{"matcher":"idle_prompt|permission_prompt","hooks":[{"type":"command","command":"\(quoted)","timeout":10}]}],
          "Stop":[{"hooks":[{"type":"command","command":"\(quoted)","timeout":120}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"\(quoted)","timeout":5}]}]
        }}
        """
        try Data(existing.utf8).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .strict)
        XCTAssertTrue(installer().isInstalled())
    }

    func testIncompleteOrMixedPolicyLayoutIsDetectedAsPartial() throws {
        let incomplete = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion","hooks":[{"type":"command","command":"\(quoted)","timeout":120}]}
        ]}}
        """
        try Data(incomplete.utf8).write(to: settings)
        XCTAssertEqual(installer().installationStatus(), .partial)

        try installer().install()
        var root = try read()
        var hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        hooks["PermissionRequest"] = .array([.object([
            "matcher": .string("Bash|Write|Edit|MultiEdit|NotebookEdit"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(quoted),
                "timeout": .number(120),
            ])]),
        ])])
        root["hooks"] = .object(hooks)
        try JSONEncoder().encode(root).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .partial)
        XCTAssertFalse(installer().isInstalled())
    }

    func testBrokenHookTypeOrTimeoutIsDetectedAsPartial() throws {
        try installer().install()
        var root = try read()
        var hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        var preToolGroups = try XCTUnwrap(hooks["PreToolUse"]?.arrayValue)
        var group = try XCTUnwrap(preToolGroups.first?.objectValue)
        var commands = try XCTUnwrap(group["hooks"]?.arrayValue)
        var hook = try XCTUnwrap(commands.first?.objectValue)
        hook["timeout"] = .number(1)
        commands[0] = .object(hook)
        group["hooks"] = .array(commands)
        preToolGroups[0] = .object(group)
        hooks["PreToolUse"] = .array(preToolGroups)
        root["hooks"] = .object(hooks)
        try JSONEncoder().encode(root).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .partial)

        hook["timeout"] = .number(InteractionBudget.hookTimeout)
        hook["type"] = .string("http")
        commands[0] = .object(hook)
        group["hooks"] = .array(commands)
        preToolGroups[0] = .object(group)
        hooks["PreToolUse"] = .array(preToolGroups)
        root["hooks"] = .object(hooks)
        try JSONEncoder().encode(root).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .partial)

        hook["type"] = .string("command")
        hook["async"] = .bool(true)
        commands[0] = .object(hook)
        group["hooks"] = .array(commands)
        preToolGroups[0] = .object(group)
        hooks["PreToolUse"] = .array(preToolGroups)
        root["hooks"] = .object(hooks)
        try JSONEncoder().encode(root).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .partial)
    }

    func testInstallPreservesUserKeysAndHooks() throws {
        let existing = """
        {"model":"opus","hooks":{"PreToolUse":[
          {"matcher":"Read","hooks":[{"type":"command","command":"/usr/bin/other","timeout":5}]}
        ]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        let root = try read()
        XCTAssertEqual(root["model"]?.stringValue, "opus")

        let groups = try XCTUnwrap(root["hooks"]?.objectValue?["PreToolUse"]?.arrayValue)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0["matcher"]?.stringValue == "Read" })
        XCTAssertTrue(groups.contains { ($0["hooks"]?.arrayValue ?? []).contains { $0["command"]?.stringValue == quoted } })
    }

    func testInstallIsIdempotent() throws {
        try installer().install()
        try installer().install()
        let groups = try XCTUnwrap(read()["hooks"]?.objectValue?["PreToolUse"]?.arrayValue)
        let ours = groups.filter { ($0["hooks"]?.arrayValue ?? []).contains { $0["command"]?.stringValue == quoted } }
        XCTAssertEqual(ours.count, 1)
    }

    func testNativeInstallIsIdempotent() throws {
        try installer(policy: .native).install()
        try installer(policy: .native).install()

        let hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        XCTAssertEqual(tapQCommandCount(event: "PreToolUse", in: hooks), 1)
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 1)
        XCTAssertEqual(installer().installationStatus(), .native)
    }

    func testSwitchingPoliciesNeverRegistersOrdinaryToolsUnderBothEvents() throws {
        try installer().install()
        try installer(policy: .native).install()

        var hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        XCTAssertEqual(hooks["PreToolUse"]?.arrayValue?.last?["matcher"]?.stringValue, "AskUserQuestion")
        XCTAssertEqual(hooks["PermissionRequest"]?.arrayValue?.last?["matcher"]?.stringValue, "Bash|Write|Edit|MultiEdit|NotebookEdit")
        XCTAssertEqual(tapQCommandCount(event: "PreToolUse", in: hooks), 1)
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 1)
        XCTAssertEqual(installer().installationStatus(), .native)

        try installer().install()

        hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        XCTAssertEqual(hooks["PreToolUse"]?.arrayValue?.last?["matcher"]?.stringValue, "Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion")
        XCTAssertEqual(tapQCommandCount(event: "PreToolUse", in: hooks), 1)
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 0)
        XCTAssertEqual(installer().installationStatus(), .strict)
    }

    func testInstallReplacesLegacyUnquotedHook() throws {
        // A settings.json written by an older TapQ release: the shim path, unquoted.
        let legacy = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash|Write|Edit|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"\(command)","timeout":120}]}
        ]}}
        """
        try Data(legacy.utf8).write(to: settings)

        try installer().install()
        let groups = try XCTUnwrap(read()["hooks"]?.objectValue?["PreToolUse"]?.arrayValue)
        // Exactly one TapQ group, now quoted — the legacy entry was stripped, not duplicated.
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue, quoted)

        // And uninstall recognizes/removes a legacy entry too.
        try Data(legacy.utf8).write(to: settings)
        try installer().uninstall()
        XCTAssertFalse(installer().isInstalled())
        XCTAssertNil(try read()["hooks"])
    }

    func testInstallMigratesPreviousExecutablePathWithoutDuplicatingEvents() throws {
        let previous = "/Users/x/tapq-open/.build/arm64-apple-macosx/debug/wavo-hook"
        let previousQuoted = HookInstaller.shellQuoted(previous)
        let existing = """
        {"model":"opus","hooks":{
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "PermissionRequest":[{"matcher":"Bash|Write","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":10}]}],
          "Stop":[
            {"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]},
            {"hooks":[{"type":"command","command":"/usr/bin/other","timeout":5}]}
          ],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":5}]}]
        }}
        """
        try Data(existing.utf8).write(to: settings)

        XCTAssertFalse(installer().isInstalled(), "a stale path is not the current installation")
        XCTAssertEqual(installer().installationStatus(), .partial)
        try installer().install()

        let root = try read()
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertEqual(root["model"]?.stringValue, "opus")
        for spec in HookInstaller.specs {
            let groups = hooks[spec.event]?.arrayValue ?? []
            let commands = groups.flatMap { group in
                (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
            XCTAssertEqual(commands.filter { $0 == quoted }.count, 1, spec.event)
            XCTAssertFalse(commands.contains(previousQuoted), spec.event)
        }
        let stopCommands = (hooks["Stop"]?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(stopCommands.contains("/usr/bin/other"))
        XCTAssertTrue(installer().isInstalled())
        XCTAssertNil(hooks["PermissionRequest"], "strict migration must remove stale native-policy hooks")
    }

    func testStatusDetectsPreviousTapQHookPathAsPartial() throws {
        let previous = "/Users/x/tapq/.build/arm64-apple-macosx/debug/tapq-hook"
        let previousQuoted = HookInstaller.shellQuoted(previous)
        let existing = """
        {"hooks":{
          "PreToolUse":[{"matcher":"Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "Notification":[{"matcher":"idle_prompt|permission_prompt","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":10}]}],
          "Stop":[{"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":5}]}]
        }}
        """
        try Data(existing.utf8).write(to: settings)

        XCTAssertEqual(installer().installationStatus(), .partial)
        XCTAssertFalse(installer().isInstalled())
    }

    func testInstallMigratesPreviousTapQHookPathWithoutDuplicatingEvents() throws {
        let previous = "/Users/x/tapq/.build/arm64-apple-macosx/debug/tapq-hook"
        let previousQuoted = HookInstaller.shellQuoted(previous)
        let existing = """
        {"model":"opus","hooks":{
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "PermissionRequest":[{"matcher":"Bash|Write","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]}],
          "Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"\(previousQuoted)","timeout":10}]}],
          "Stop":[
            {"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":120}]},
            {"hooks":[{"type":"command","command":"/usr/bin/other","timeout":5}]}
          ],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"\(previousQuoted)","timeout":5}]}]
        }}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()

        let root = try read()
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)
        XCTAssertEqual(root["model"]?.stringValue, "opus")
        for spec in HookInstaller.specs {
            let commands = (hooks[spec.event]?.arrayValue ?? []).flatMap { group in
                (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
            }
            XCTAssertEqual(commands.filter { $0 == quoted }.count, 1, spec.event)
            XCTAssertFalse(commands.contains(previousQuoted), spec.event)
        }
        let stopCommands = (hooks["Stop"]?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(stopCommands.contains("/usr/bin/other"))
        XCTAssertNil(hooks["PermissionRequest"], "strict migration must remove stale native-policy hooks")
        XCTAssertTrue(installer().isInstalled())
    }

    func testUninstallRemovesPreviousTapQHookPathAndPreservesUserHook() throws {
        let previous = "/Applications/TapQRuntime.app/Contents/MacOS/tapq-hook"
        let previousQuoted = HookInstaller.shellQuoted(previous)
        let existing = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"\(previousQuoted)","timeout":120},
          {"type":"command","command":"/usr/bin/other","timeout":5}
        ]}]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().uninstall()

        let hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        let commands = (hooks["Stop"]?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertEqual(commands, ["/usr/bin/other"])
        XCTAssertEqual(installer().installationStatus(), .notInstalled)
    }

    func testMigrationDoesNotRemoveUnrelatedDirectTapQHookExecutable() throws {
        let unrelated = "/opt/custom/tapq-hook"
        let existing = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"\(unrelated)","timeout":5}
        ]}]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        try installer().uninstall()

        let groups = try XCTUnwrap(read()["hooks"]?.objectValue?["Stop"]?.arrayValue)
        let commands = groups.flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertEqual(commands, [unrelated])
    }

    func testPolicySwitchPreservesUserHookSharingManagedGroup() throws {
        let existing = """
        {"hooks":{"PreToolUse":[{
          "matcher":"Bash",
          "hooks":[
            {"type":"command","command":"\(quoted)","timeout":120},
            {"type":"command","command":"/usr/bin/user-audit","timeout":5}
          ]
        }]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer(policy: .native).install()

        let hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        let preToolGroups = hooks["PreToolUse"]?.arrayValue ?? []
        let userCommands = preToolGroups.flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(userCommands.contains("/usr/bin/user-audit"))
        XCTAssertEqual(tapQCommandCount(event: "PreToolUse", in: hooks), 1)
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 1)
    }

    func testMigrationDoesNotRemoveCompositeUserCommandMentioningLegacyHook() throws {
        let composite = "/bin/sh -c '/opt/custom/wavo-hook --audit'"
        let existing = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"\(composite)","timeout":5}
        ]}]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        let groups = try XCTUnwrap(read()["hooks"]?.objectValue?["Stop"]?.arrayValue)
        let commands = groups.flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertTrue(commands.contains(composite))
        XCTAssertEqual(commands.filter { $0 == quoted }.count, 1)
    }

    func testMigrationDoesNotRemoveUnrelatedDirectLegacyHookExecutable() throws {
        let unrelated = "/opt/custom/wavo-hook"
        let existing = """
        {"hooks":{"Stop":[{"hooks":[
          {"type":"command","command":"\(unrelated)","timeout":5}
        ]}]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        try installer().uninstall()

        let groups = try XCTUnwrap(read()["hooks"]?.objectValue?["Stop"]?.arrayValue)
        let commands = groups.flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
        XCTAssertEqual(commands, [unrelated])
    }

    func testUninstallRemovesOnlyTapQHooks() throws {
        let existing = """
        {"model":"opus","hooks":{"PreToolUse":[
          {"matcher":"Read","hooks":[{"type":"command","command":"/usr/bin/other","timeout":5}]}
        ]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        try installer().uninstall()

        let root = try read()
        XCTAssertEqual(root["model"]?.stringValue, "opus")
        XCTAssertFalse(installer().isInstalled())
        let groups = try XCTUnwrap(root["hooks"]?.objectValue?["PreToolUse"]?.arrayValue)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["matcher"]?.stringValue, "Read")
    }

    func testStrictInstallAndUninstallRemoveStaleNativeHooksButPreserveUserPermissionHooks() throws {
        let existing = """
        {"hooks":{"PermissionRequest":[
          {"matcher":"Bash","hooks":[{"type":"command","command":"\(quoted)","timeout":120}]},
          {"matcher":"mcp__custom__tool","hooks":[{"type":"command","command":"/usr/bin/other","timeout":5}]}
        ]}}
        """
        try Data(existing.utf8).write(to: settings)

        try installer().install()
        var hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        var permissionGroups = try XCTUnwrap(hooks["PermissionRequest"]?.arrayValue)
        XCTAssertEqual(permissionGroups.count, 1)
        XCTAssertEqual(permissionGroups.first?["matcher"]?.stringValue, "mcp__custom__tool")
        XCTAssertEqual(tapQCommandCount(event: "PermissionRequest", in: hooks), 0)

        try installer(policy: .native).install()
        try installer(policy: .native).uninstall()

        hooks = try XCTUnwrap(read()["hooks"]?.objectValue)
        permissionGroups = try XCTUnwrap(hooks["PermissionRequest"]?.arrayValue)
        XCTAssertEqual(permissionGroups.count, 1)
        XCTAssertEqual(permissionGroups.first?["matcher"]?.stringValue, "mcp__custom__tool")
        XCTAssertEqual(permissionGroups.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue, "/usr/bin/other")
        XCTAssertEqual(installer().installationStatus(), .notInstalled)
    }

    func testUninstallWithNoUserHooksDropsHooksKey() throws {
        try installer().install()
        try installer().uninstall()
        XCTAssertNil(try read()["hooks"])
    }

    func testWriteCreatesBackup() throws {
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: settings.path
        )

        try installer().install()

        let backups = try backupURLs()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try permissions(at: XCTUnwrap(backups.first)), 0o600)
        XCTAssertEqual(try permissions(at: settings), 0o600)
    }

    func testWritePreservesUsableStricterSettingsAndBackupModes() throws {
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o400))],
            ofItemAtPath: settings.path
        )

        try installer().install()

        let backup = try XCTUnwrap(backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o400)
        XCTAssertEqual(try permissions(at: settings), 0o400)
    }

    func testRepeatedWritesCreateDistinctBackups() throws {
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)

        try installer().install()
        try installer(policy: .native).install()

        let backups = try backupURLs()
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(Set(backups.map(\.lastPathComponent)).count, 2)
    }

    func testReplacementFailurePreservesOriginalBytesAndMode() throws {
        let original = Data(#"{"model":"opus","custom":true}"#.utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o640))],
            ofItemAtPath: settings.path
        )
        let failingInstaller = HookInstaller(
            settingsURL: settings,
            hookCommand: command,
            fileWriter: ReplacementFailingWriter()
        )

        XCTAssertThrowsError(try failingInstaller.install())

        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertEqual(try permissions(at: settings), 0o640)
        let backup = try XCTUnwrap(backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
    }

    func testAtomicWriterRemovesTemporaryFileWhenPublicationFails() throws {
        let occupiedDestination = dir.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(
            at: occupiedDestination,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try POSIXSecureAtomicFileWriter().write(
                Data("new settings".utf8),
                to: occupiedDestination,
                mode: 0o600,
                disposition: .replaceExisting
            )
        )

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("tapq-tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInstallsUserPromptSubmitSpecAndStopTimeout() throws {
        try installer().install()
        let root = try read()
        let hooks = try XCTUnwrap(root["hooks"]?.objectValue)

        let ups = try XCTUnwrap(hooks["UserPromptSubmit"]?.arrayValue?.first)
        XCTAssertNil(ups["matcher"])
        let upsHook = try XCTUnwrap(ups["hooks"]?.arrayValue?.first)
        if case .number(let t)? = upsHook["timeout"] { XCTAssertEqual(t, 5) } else { XCTFail("timeout") }

        let stop = try XCTUnwrap(hooks["Stop"]?.arrayValue?.first)
        let stopHook = try XCTUnwrap(stop["hooks"]?.arrayValue?.first)
        if case .number(let t)? = stopHook["timeout"] { XCTAssertEqual(t, 120) } else { XCTFail("timeout") }
    }
}
