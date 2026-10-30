import Foundation
import TapQKernel
import TapQPOSIXSupport
import XCTest
@testable import TapQKernelClaude

/// The Agent SDK's `listSessions({dir})` rules, ported (`ClaudeSessionCatalog`): where the files
/// are, which count, and each one's title.
final class ClaudeSessionCatalogTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var workspace: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapq-claude-catalog-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("my.project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var catalog: ClaudeSessionCatalog { ClaudeSessionCatalog(environment: [:], homeDirectory: home) }

    /// The folder's directory in the store, as Claude Code names it.
    private func projectDirectory(config: URL? = nil) throws -> URL {
        let name = ClaudeSessionCatalog.directoryName(for: ClaudeSessionCatalog.realPath(workspace.path))
        let directory = (config ?? home.appendingPathComponent(".claude"))
            .appendingPathComponent("projects").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func write(_ lines: [String], as id: String = UUID().uuidString.lowercased(), in directory: URL,
                       modified: TimeInterval) throws -> String {
        let file = directory.appendingPathComponent("\(id).jsonl")
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                              ofItemAtPath: file.path)
        return id
    }

    private static func user(_ content: String, meta: Bool = false) -> String {
        #"{"type":"user","isMeta":\#(meta),"message":{"role":"user","content":\#(content)},"uuid":"u"}"#
    }

    // MARK: - Where

    func testTheFolderNameMakesEveryUTF16UnitThatIsNotALetterOrDigitADash() async throws {
        XCTAssertEqual(ClaudeSessionCatalog.directoryName(for: "/Users/me/my.project"), "-Users-me-my-project")
        XCTAssertEqual(ClaudeSessionCatalog.directoryName(for: "/Users/dev/tapq-beta/tally"),
                       "-Users-dev-tapq-beta-tally")
        XCTAssertEqual(ClaudeSessionCatalog.directoryName(for: "/a/é"), "-a--")
        XCTAssertEqual(ClaudeSessionCatalog.directoryName(for: "/😀"), "---", "a character outside the BMP is two units")
    }

    func testAFolderWithNoStoreListsNothing() async throws {
        let sessions = try await catalog.sessions(in: workspace)
        XCTAssertEqual(sessions, [])
    }

    func testCLAUDE_CONFIG_DIRIsTheStore() async throws {
        let config = root.appendingPathComponent("elsewhere", isDirectory: true)
        let id = try write([Self.user(#""fix the build""#)], in: try projectDirectory(config: config), modified: 1)
        let sessions = try await ClaudeSessionCatalog(environment: ["CLAUDE_CONFIG_DIR": config.path],
                                                      homeDirectory: home).sessions(in: workspace)
        XCTAssertEqual(sessions.map(\.id), [id])
    }

    func testALongFolderIsFoundByItsCutNameAndADash() async throws {
        workspace = root.appendingPathComponent(String(repeating: "deep/", count: 45), isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let name = ClaudeSessionCatalog.directoryName(for: ClaudeSessionCatalog.realPath(workspace.path))
        XCTAssertGreaterThan(name.count, 200)
        let directory = home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(String(name.prefix(200)) + "-1x2y3z")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = try write([Self.user(#""go deep""#)], in: directory, modified: 1)

        let sessions = try await catalog.sessions(in: workspace)
        XCTAssertEqual(sessions.map(\.id), [id])
    }

    // MARK: - Which, and their titles

    func testSessionsAreNewestFirstWithTheTitleTheSDKWouldGive() async throws {
        let directory = try projectDirectory()
        // The first prompt: meta lines and tool results are not the user's words.
        let prompted = try write([
            #"{"type":"system","subtype":"init","cwd":"/x"}"#,
            Self.user(#""<system-reminder>context</system-reminder>""#, meta: true),
            Self.user(#""build milestone one\nof the tally app""#),
            Self.user(#"[{"type":"tool_result","tool_use_id":"t","content":"ok"}]"#),
        ], in: directory, modified: 100)
        // A custom title in the tail beats everything.
        let titled = try write([
            Self.user(#"[{"type":"text","text":"fix the README"}]"#),
            #"{"type":"custom-title","customTitle":"README fixes","sessionId":"s"}"#,
        ], in: directory, modified: 300)
        // A summary in the tail beats the first prompt.
        let summarized = try write([
            Self.user(#""refactor the parser""#),
            #"{"type":"summary","summary":"Parser refactor into three passes","leafUuid":"l"}"#,
        ], in: directory, modified: 200)
        // A slash command is the title only when nothing was typed.
        let command = try write([
            Self.user(#""<command-name>/compact</command-name>\n<command-args></command-args>""#),
        ], in: directory, modified: 50)
        // "[Request interrupted by user]" is skipped for the words after it.
        let interrupted = try write([
            Self.user(#""[Request interrupted by user for tool use]""#),
            Self.user(#""now add tests""#),
        ], in: directory, modified: 40)
        let nothing = try write([#"{"type":"assistant","message":{"content":[]}}"#], in: directory, modified: 30)

        let sessions = try await catalog.sessions(in: workspace)
        XCTAssertEqual(sessions.map(\.id), [titled, summarized, prompted, command, interrupted, nothing])
        XCTAssertEqual(sessions.map(\.title), ["README fixes", "Parser refactor into three passes",
                                               "build milestone one of the tally app", "/compact",
                                               "now add tests", "(session)"])
        XCTAssertEqual(sessions.first?.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testSubagentAndTeamTranscriptsEmptyFilesAndOtherNamesAreLeftOut() async throws {
        let directory = try projectDirectory()
        let kept = try write([Self.user(#""the user's own""#)], in: directory, modified: 5)
        try write([#"{"type":"user","isSidechain":true,"message":{"content":"a subagent"}}"#], in: directory, modified: 4)
        try write([#"{"type":"user","teamName":"alpha","message":{"content":"a team member"}}"#], in: directory, modified: 3)
        try write([], in: directory, modified: 2)
        try write([Self.user(#""not a session id""#)], as: "notes", in: directory, modified: 1)
        try Data("x".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).txt"))

        let sessions = try await catalog.sessions(in: workspace)
        XCTAssertEqual(sessions.map(\.id), [kept])
    }

    func testALongFirstPromptIsCutAt200CharactersAsTheSDKCutsIt() async throws {
        let long = String(repeating: "word ", count: 60)
        try write([Self.user("\"\(long)\"")], in: try projectDirectory(), modified: 1)
        let title = try await catalog.sessions(in: workspace).first?.title
        XCTAssertEqual(title, String(long.prefix(200)).trimmingCharacters(in: .whitespaces) + "…")
    }

    /// Past 64 KiB only the two ends are read: a title written last is found in the tail.
    func testALongTranscriptTakesItsTitleFromTheTail() async throws {
        let padding = (0..<200).map { #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 500))\#($0)"}}"# }
        try write([Self.user(#""start here""#)] + padding + [#"{"type":"custom-title","customTitle":"Late name"}"#],
                  in: try projectDirectory(), modified: 1)
        let title = try await catalog.sessions(in: workspace).first?.title
        XCTAssertEqual(title, "Late name")
    }

    func testEscapedTitlesAreUnescaped() async throws {
        try write([#"{"type":"custom-title","customTitle":"Fix \"quotes\" and \\ slashes"}"#],
                  in: try projectDirectory(), modified: 1)
        let title = try await catalog.sessions(in: workspace).first?.title
        XCTAssertEqual(title, #"Fix "quotes" and \ slashes"#)
    }

    // MARK: - Open now (2026-10-12)

    /// `claude agents --json` as Claude Code 2.1.293 printed it on 2026-10-12, one line.
    private static func agents(_ entries: [(pid: Int, id: String, status: String)]) -> String {
        "[" + entries.map { entry in
            #"{"pid":\#(entry.pid),"cwd":"/Users/me/my.project","kind":"interactive","sessionId":"\#(entry.id)","name":"n","startedAt":1791840254460,"status":"\#(entry.status)"}"#
        }.joined(separator: ",") + "]"
    }

    /// A catalog whose `claude agents` prints `output` and exits with `status`; `calls` records
    /// each spawn's executable, arguments and working directory.
    private func catalog(printing output: [String], errors: [String] = [], status: Int32 = 0,
                         version: String? = "2.1.283", calls: SpawnLog = SpawnLog()) -> ClaudeSessionCatalog {
        ClaudeSessionCatalog(environment: ["CLAUDE_CONFIG_DIR": ""], executablePath: "/bin/claude",
                             version: version, homeDirectory: home) { executable, arguments, _, directory in
            calls.record([executable] + arguments + [directory.path])
            let channel = ScriptedChannel()
            output.forEach { channel.emit(.stdout($0)) }
            errors.forEach { channel.emit(.stderr($0)) }
            channel.emit(.exited(status))
            return channel
        }
    }

    func testTheFoldersConversationsClaudeCodeHasOpenAreReportedWithTheirTitles() async throws {
        let directory = try projectDirectory()
        let titled = try write([#"{"type":"custom-title","customTitle":"Music medley study"}"#], in: directory, modified: 2)
        let other = try write([Self.user(#""tune the mixer""#)], in: directory, modified: 1)
        let helper = UUID().uuidString.lowercased()
        let calls = SpawnLog()
        let catalog = catalog(printing: [Self.agents([(51226, titled, "busy"), (24765, helper, "idle"),
                                                      (77550, other, "idle")])], calls: calls)

        let open = try await catalog.openSessions(in: workspace)
        // The helper keeps no transcript in this folder, so it is not one of its conversations.
        XCTAssertEqual(open, [OpenSession(id: titled, title: "Music medley study", working: true),
                              OpenSession(id: other, title: "tune the mixer", working: false)])
        XCTAssertEqual(calls.entries, [["/bin/claude", "agents", "--json", workspace.path]])
    }

    func testAListingPrintedOverSeveralLinesIsRead() async throws {
        let id = try write([Self.user(#""hello""#)], in: try projectDirectory(), modified: 1)
        let lines = ["[", #"  {"sessionId": "\#(id)", "status": "idle"},"#, #"  {"pid": 7, "status": "busy"}"#, "]"]
        let open = try await catalog(printing: lines).openSessions(in: workspace)
        XCTAssertEqual(open, [OpenSession(id: id, title: "hello", working: false)],
                       "an entry without a session id is skipped")
    }

    func testNothingRunningAndAFolderWithNoStoreReportNothing() async throws {
        let none = try await catalog(printing: ["[]"]).openSessions(in: workspace)
        XCTAssertEqual(none, [])
        let elsewhere = try await catalog(printing: [Self.agents([(1, UUID().uuidString.lowercased(), "busy")])])
            .openSessions(in: workspace)
        XCTAssertEqual(elsewhere, [], "no store for this folder")
    }

    func testAVersionItWasNotCheckedOnAndNoExecutableAreNotAsked() async throws {
        let calls = SpawnLog()
        let older = try await catalog(printing: ["[]"], version: "2.1.270", calls: calls).openSessions(in: workspace)
        let unknown = try await catalog(printing: ["[]"], version: nil, calls: calls).openSessions(in: workspace)
        let none = try await ClaudeSessionCatalog(environment: [:], homeDirectory: home).openSessions(in: workspace)
        XCTAssertEqual(older + unknown + none, [])
        XCTAssertEqual(calls.entries, [])
        let newest = try await catalog(printing: ["[]"], version: "2.1.293", calls: calls).openSessions(in: workspace)
        XCTAssertEqual(newest, [])
        XCTAssertEqual(calls.entries.count, 1, "the cap was checked too")
    }

    func testAFailedOrUnreadableListingThrows() async throws {
        do {
            _ = try await catalog(printing: [], errors: ["error: unknown option '--json'"], status: 1).openSessions(in: workspace)
            XCTFail("a failed listing is not an empty one")
        } catch let error as ClaudeAgentsError {
            XCTAssertEqual(error, .exited(1, "error: unknown option '--json'"))
        }
        do {
            _ = try await catalog(printing: ["Agents: 2 running"]).openSessions(in: workspace)
            XCTFail("text that is not the listing is not an empty one")
        } catch let error as ClaudeAgentsError {
            XCTAssertEqual(error, .unreadable("Agents: 2 running"))
        }
    }
}

/// The spawns a catalog made.
final class SpawnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    var entries: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }

    func record(_ call: [String]) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }
}
