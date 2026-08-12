import XCTest
@testable import TapQOpenCodeAdapter
import TapQPOSIXSupport

private enum IntentionalOpenCodeWriteFailure: Error {
    case replacement
}

private final class OpenCodeReplacementFailingWriter: SecureAtomicFileWriting {
    private let underlying = POSIXSecureAtomicFileWriter()

    func write(
        _ data: Data,
        to destination: URL,
        mode: UInt16,
        disposition: SecureAtomicWriteDisposition
    ) throws {
        switch disposition {
        case .createNew:
            try underlying.write(data, to: destination, mode: mode, disposition: disposition)
        case .replaceExisting:
            throw IntentionalOpenCodeWriteFailure.replacement
        }
    }
}

final class OpenCodePluginInstallerTests: XCTestCase {
    private var directory: URL!
    private var pluginURL: URL!
    private let command = "/Users/example/Library/Application Support/TapQ/tapq-opencode-hook"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tapq-opencode-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        pluginURL = directory.appendingPathComponent("tapq.js")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func installer(
        pluginURL: URL? = nil,
        command: String? = nil
    ) -> OpenCodePluginInstaller {
        OpenCodePluginInstaller(
            pluginURL: pluginURL ?? self.pluginURL,
            hookCommand: command ?? self.command
        )
    }

    private func read() throws -> String {
        String(decoding: try Data(contentsOf: pluginURL), as: UTF8.self)
    }

    private func permissions(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value & 0o777
    }

    private func backupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: pluginURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("tapq-backup") }
    }

    // MARK: - Default locations

    private func defaultPluginURL(_ environment: [String: String]) -> URL {
        OpenCodePluginInstaller.openCodePluginURL(
            homeDirectory: directory.appendingPathComponent("home", isDirectory: true),
            environment: environment
        )
    }

    func testDefaultPluginURLFollowsOpenCodesConfigDirectoryResolution() {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let homeDefault = home.appendingPathComponent(".config/opencode/plugins/tapq.js")

        XCTAssertEqual(defaultPluginURL([:]), homeDefault)
        XCTAssertEqual(defaultPluginURL(["XDG_CONFIG_HOME": "   "]), homeDefault)
        // A relative value is not a usable base directory, so the home default wins.
        XCTAssertEqual(defaultPluginURL(["XDG_CONFIG_HOME": "relative"]), homeDefault)
        XCTAssertEqual(defaultPluginURL(["OPENCODE_CONFIG_DIR": "relative"]), homeDefault)

        XCTAssertEqual(
            defaultPluginURL(["XDG_CONFIG_HOME": "/custom/xdg"]),
            URL(fileURLWithPath: "/custom/xdg/opencode/plugins/tapq.js")
        )
        // OPENCODE_CONFIG_DIR names the configuration directory itself and outranks XDG.
        XCTAssertEqual(
            defaultPluginURL([
                "OPENCODE_CONFIG_DIR": "/custom/opencode",
                "XDG_CONFIG_HOME": "/custom/xdg",
            ]),
            URL(fileURLWithPath: "/custom/opencode/plugins/tapq.js")
        )

        let defaulted = OpenCodePluginInstaller(pluginURL: pluginURL)
        XCTAssertEqual(defaulted.hookCommand, "tapq-opencode-hook")
        XCTAssertEqual(OpenCodePluginInstaller.pluginFileName, "tapq.js")
        XCTAssertEqual(OpenCodePluginInstaller.pluginDirectoryName, "plugins")
    }

    // MARK: - Install

    func testInstallWritesManagedPluginCarryingTheHookPath() throws {
        let report = try installer().install()
        let contents = try read()

        XCTAssertTrue(contents.hasPrefix(OpenCodePluginSource.marker))
        XCTAssertTrue(contents.contains(OpenCodePluginSource.markerLine()))
        XCTAssertTrue(contents.contains("const HOOK = \"\(command)\""))
        XCTAssertTrue(contents.contains("permission.asked"))
        XCTAssertTrue(contents.contains("session.idle"))
        XCTAssertEqual(report.status, .installed)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.reloadAction, .restartRequired)
        XCTAssertTrue(report.reloadAction.message?.contains("Restart OpenCode") == true)
        XCTAssertTrue(installer().isInstalled())
        XCTAssertEqual(try permissions(at: pluginURL), 0o600)
    }

    func testInstallCreatesMissingDirectoryWithOwnerOnlyPermissions() throws {
        let nested = directory
            .appendingPathComponent("missing-config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("tapq.js")

        try installer(pluginURL: nested).install()

        XCTAssertEqual(try permissions(at: nested.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: nested), 0o600)
    }

    func testRepeatedInstallIsByteForByteIdempotentAndMakesNoBackup() throws {
        let first = try installer().install()
        let firstBytes = try Data(contentsOf: pluginURL)
        let second = try installer().install()

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.status, .installed)
        XCTAssertEqual(second.reloadAction, .none)
        XCTAssertNil(second.reloadAction.message)
        XCTAssertEqual(try Data(contentsOf: pluginURL), firstBytes)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    func testInstallRepairsAStalePluginPathAndRequiresRestart() throws {
        let stale = OpenCodePluginInstaller(
            pluginURL: pluginURL,
            hookCommand: "/Applications/TapQRuntime.app/Contents/MacOS/tapq-opencode-hook"
        )
        try stale.install()

        XCTAssertEqual(installer().installationStatus(), .partial)
        XCTAssertEqual(installer().statusReport().reloadAction, .restartRequired)

        let report = try installer().install()

        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.status, .installed)
        XCTAssertEqual(report.reloadAction, .restartRequired)
        XCTAssertEqual(installer().installationStatus(), .installed)
        XCTAssertTrue(try read().contains("const HOOK = \"\(command)\""))
        XCTAssertFalse(try read().contains("TapQRuntime.app"))
        XCTAssertEqual(try backupURLs().count, 1)
    }

    func testInstallRepairsAnEditedManagedPlugin() throws {
        try installer().install()
        let edited = OpenCodePluginSource.marker + "\n// hand-edited\n"
        try Data(edited.utf8).write(to: pluginURL)

        XCTAssertEqual(installer().installationStatus(), .partial)
        let report = try installer().install()

        XCTAssertTrue(report.didChange)
        XCTAssertEqual(installer().installationStatus(), .installed)
        let backup = try XCTUnwrap(try backupURLs().first)
        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self), edited)
    }

    func testInstallRefusesToOverwriteAPluginTapQDidNotWrite() throws {
        let foreign = Data("export const Mine = async () => ({})\n".utf8)
        try foreign.write(to: pluginURL)

        XCTAssertEqual(installer().installationStatus(), .foreign)
        XCTAssertEqual(installer().statusReport().reloadAction, .none)
        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(
                error as? OpenCodePluginInstallerError,
                .foreignPluginPresent(pluginURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: pluginURL), foreign)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    // MARK: - Status

    func testStatusReportsMissingPluginAsNotInstalled() {
        XCTAssertEqual(installer().installationStatus(), .notInstalled)
        XCTAssertEqual(installer().statusReport().status, .notInstalled)
        XCTAssertEqual(installer().statusReport().reloadAction, .none)
        XCTAssertFalse(installer().isInstalled())
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyTheManagedPluginAndBacksItUp() throws {
        let neighbour = pluginURL.deletingLastPathComponent()
            .appendingPathComponent("user-plugin.js")
        try installer().install()
        try Data("export const Mine = async () => ({})\n".utf8).write(to: neighbour)

        let report = try installer().uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(report.reloadAction, .restartRequired)
        let backup = try XCTUnwrap(try backupURLs().first)
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: backup), as: UTF8.self)
                .hasPrefix(OpenCodePluginSource.marker)
        )
    }

    func testUninstallLeavesAForeignPluginInPlace() throws {
        let foreign = Data("export const Mine = async () => ({})\n".utf8)
        try foreign.write(to: pluginURL)

        let report = try installer().uninstall()

        XCTAssertEqual(report.status, .foreign)
        XCTAssertFalse(report.didChange)
        XCTAssertEqual(try Data(contentsOf: pluginURL), foreign)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    func testUninstallWithoutAnInstalledPluginIsANoOp() throws {
        let report = try installer().uninstall()

        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertFalse(report.didChange)
        XCTAssertEqual(report.reloadAction, .none)
        XCTAssertTrue(try backupURLs().isEmpty)
    }

    // MARK: - Backup guarantees

    func testMutationsCreateRestrictiveExactBackups() throws {
        let original = Data((OpenCodePluginSource.marker + "\n// previous\n").utf8)
        try original.write(to: pluginURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: pluginURL.path
        )

        try installer().install()

        let backup = try XCTUnwrap(try backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
        XCTAssertEqual(try permissions(at: pluginURL), 0o600)
    }

    func testReplacementFailurePreservesOriginalAndPublishesBackup() throws {
        let original = Data((OpenCodePluginSource.marker + "\n// previous\n").utf8)
        try original.write(to: pluginURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o640))],
            ofItemAtPath: pluginURL.path
        )
        let failing = OpenCodePluginInstaller(
            pluginURL: pluginURL,
            hookCommand: command,
            fileWriter: OpenCodeReplacementFailingWriter()
        )

        XCTAssertThrowsError(try failing.install())

        XCTAssertEqual(try Data(contentsOf: pluginURL), original)
        XCTAssertEqual(try permissions(at: pluginURL), 0o640)
        let backup = try XCTUnwrap(try backupURLs().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try permissions(at: backup), 0o600)
    }
}
