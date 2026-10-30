import Foundation
import TapQKernel
import TapQPOSIXSupport

/// Claude Code's sessions in one folder, read from its own store as the Agent SDK's
/// `listSessions({dir})` reads them (`@anthropic-ai/claude-agent-sdk` 0.2.59; Claude Code 2.1.283
/// writes the same files): `<config>/projects/<folder>/<session id>.jsonl`, where `<folder>` is
/// the folder's real path with every UTF-16 unit that is not an ASCII letter or digit made a
/// dash. Read only. The format is Claude Code's own, not an API: the supported version range
/// (D5) is what holds it steady. Unlike the SDK, the folder's git worktrees are not included:
/// TapQ resumes in this folder only.
///
/// Which of them a process has open now is Claude Code's own answer to `claude agents --json`
/// (2026-10-12), its listing for scripts: one entry per running session, interactive and
/// background, the Claude app's and TapQ's own included, with its `sessionId` and a `status` of
/// `busy` or `idle`. Its `--cwd` is not used: its help says it keeps background sessions only.
public struct ClaudeSessionCatalog: SessionCatalog {
    public typealias Spawn = @Sendable (_ executable: String, _ arguments: [String],
                                        _ environment: [String: String], _ workingDirectory: URL) throws -> any LineChannel

    /// The production `spawn`.
    public static let spawnChildProcess: Spawn = { executable, arguments, environment, directory in
        try ChildProcess(executable: executable, arguments: arguments, environment: environment,
                         workingDirectory: directory)
    }

    static let agentsArguments = ["agents", "--json"]
    /// The versions `claude agents --json` was checked on: 2.1.283 and 2.1.293 (2026-10-12).
    /// An older one may not know the command, and is not asked.
    static let agentsVersions = VersionRange(floor: "2.1.283", cap: ClaudeVersions.supported.cap)

    /// Bytes read from each end of a session file.
    static let window = 65_536
    /// Longer folder names are cut here and given a hash suffix, which the SDK matches by prefix.
    static let maxDirectoryName = 200
    static let promptLimit = 200

    private let environment: [String: String]
    private let homeDirectory: URL
    private let executablePath: String?
    private let version: String?
    private let spawn: Spawn

    /// `environment`: the one Claude Code gets, for `CLAUDE_CONFIG_DIR`, and the one `claude
    /// agents` runs in. Without `executablePath`, or at a `version` it was not checked on, no
    /// session is reported open.
    public init(environment: [String: String],
                executablePath: String? = nil,
                version: String? = nil,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                spawn: @escaping Spawn = ClaudeSessionCatalog.spawnChildProcess) {
        self.environment = environment
        self.executablePath = executablePath
        self.version = version
        self.homeDirectory = homeDirectory
        self.spawn = spawn
    }

    public func sessions(in workspace: URL) async throws -> [SessionSummary] {
        guard let directory = projectDirectory(for: workspace),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { session(named: $0, in: directory) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Open now

    /// The folder's conversations a running Claude Code is in: those `claude agents --json`
    /// lists whose session is one of this folder's in the store, so a session that keeps no
    /// transcript (the Claude app runs helpers with `--no-session-persistence`) or belongs to
    /// another folder is not one. The process is ended when the caller's bound cancels.
    public func openSessions(in workspace: URL) async throws -> [OpenSession] {
        guard let executablePath, let version, Self.agentsVersions.contains(version) else { return [] }
        let channel = try spawn(executablePath, Self.agentsArguments, environment, workspace)
        channel.closeInput()
        let (output, errors, status) = await withTaskCancellationHandler {
            await Self.collect(channel)
        } onCancel: {
            Task { await channel.terminate(grace: .zero, killAfter: .seconds(1)) }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw ClaudeAgentsError.exited(status, errors) }
        let running = try Self.parseAgents(output)
        guard !running.isEmpty, let directory = projectDirectory(for: workspace) else { return [] }
        return running.compactMap { entry in
            session(named: "\(entry.id).jsonl", in: directory).map {
                OpenSession(id: entry.id, title: $0.title, working: entry.working)
            }
        }
    }

    /// Everything the command printed, and how it ended.
    static func collect(_ channel: any LineChannel) async -> (output: String, errors: String, status: Int32) {
        var output: [String] = []
        var errors: [String] = []
        for await signal in channel.signals {
            switch signal {
            case .stdout(let line): output.append(line)
            case .stderr(let line): errors.append(line)
            case .exited(let status):
                return (output.joined(separator: "\n"), errors.suffix(3).joined(separator: " "), status)
            }
        }
        return (output.joined(separator: "\n"), errors.suffix(3).joined(separator: " "), -1)
    }

    /// Each running session's id and whether Claude Code says it is `busy`. An entry without a
    /// session id is skipped; anything but an array is a listing TapQ cannot read.
    static func parseAgents(_ text: String) throws -> [(id: String, working: Bool)] {
        guard let entries = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            throw ClaudeAgentsError.unreadable(String(text.prefix(200)))
        }
        return entries.compactMap { entry in
            guard let fields = entry as? [String: Any],
                  let id = fields["sessionId"] as? String, !id.isEmpty else { return nil }
            return (id, fields["status"] as? String == "busy")
        }
    }

    // MARK: - Where

    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    var configDirectory: URL {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override.precomposedStringWithCanonicalMapping, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    func projectDirectory(for workspace: URL) -> URL? {
        let projects = configDirectory.appendingPathComponent("projects", isDirectory: true)
        let name = Self.directoryName(for: Self.realPath(workspace.path))
        guard name.count > Self.maxDirectoryName else {
            let exact = projects.appendingPathComponent(name, isDirectory: true)
            return FileManager.default.fileExists(atPath: exact.path) ? exact : nil
        }
        // The SDK's hash suffix differs between runtimes, so it matches the cut name and a dash.
        let prefix = String(name.prefix(Self.maxDirectoryName)) + "-"
        let match = (try? FileManager.default.contentsOfDirectory(atPath: projects.path))?
            .first { $0.hasPrefix(prefix) }
        return match.map { projects.appendingPathComponent($0, isDirectory: true) }
    }

    /// Every UTF-16 unit that is not an ASCII letter or digit becomes a dash, as JavaScript's
    /// `replace(/[^a-zA-Z0-9]/g, "-")` does: a character outside the BMP is two dashes.
    static func directoryName(for path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(UInt8(unit)))
            default: return "-"
            }
        })
    }

    /// `realpath(3)`, as Node's `fs.realpath` (so `/tmp` is `/private/tmp` on macOS), in NFC.
    static func realPath(_ path: String) -> String {
        (resolvedRealPath(path) ?? path).precomposedStringWithCanonicalMapping
    }

    // MARK: - One session

    func session(named name: String, in directory: URL) -> SessionSummary? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        guard UUID(uuidString: id) != nil,
              let (head, tail, modified) = Self.ends(of: directory.appendingPathComponent(name)) else { return nil }
        let firstLine = head.prefix { $0 != 0x0A }
        // A subagent's transcript, or a team member's, is not a conversation of the user's.
        if Self.contains(firstLine, #""isSidechain":true"#) || Self.contains(firstLine, #""isSidechain": true"#) {
            return nil
        }
        if Self.firstValue(of: "teamName", in: head)?.isEmpty == false { return nil }
        let title = Self.lastValue(of: "customTitle", in: tail).nonEmpty
            ?? Self.lastValue(of: "summary", in: tail).nonEmpty
            ?? Self.firstPrompt(in: head).nonEmpty
            ?? "(session)"
        return SessionSummary(id: id, title: title, updatedAt: modified)
    }

    /// The first and last `window` bytes as UTF-16 (the tail is the head for a short file), and
    /// the modification time; nil for an empty or unreadable file.
    static func ends(of file: URL) -> (head: [UInt16], tail: [UInt16], modified: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date,
              let headData = try? handle.read(upToCount: window), !headData.isEmpty else { return nil }
        let head = Array(String(decoding: headData, as: UTF8.self).utf16)
        guard size > window else { return (head, head, modified) }
        guard (try? handle.seek(toOffset: UInt64(size - window))) != nil,
              let tailData = try? handle.read(upToCount: window) else { return nil }
        return (head, Array(String(decoding: tailData, as: UTF8.self).utf16), modified)
    }

    // MARK: - The SDK's text scans

    /// The SDK's `_9`: the value of the first `"key":"…"` (then `"key": "…"`) in raw text.
    static func firstValue(of key: String, in text: [UInt16]) -> String? {
        for pattern in patterns(key) {
            if let start = index(of: pattern, in: text, from: 0) {
                return value(in: text, from: start + pattern.count).value
            }
        }
        return nil
    }

    /// The SDK's `k9`: every match of each spelling in turn, the last one found winning.
    static func lastValue(of key: String, in text: [UInt16]) -> String? {
        var found: String?
        for pattern in patterns(key) {
            var from = 0
            while let start = index(of: pattern, in: text, from: from) {
                let (value, end) = value(in: text, from: start + pattern.count)
                if let value { found = value }
                from = end + 1
            }
        }
        return found
    }

    private static func patterns(_ key: String) -> [[UInt16]] {
        [Array("\"\(key)\":\"".utf16), Array("\"\(key)\": \"".utf16)]
    }

    /// The string from `start` to the next unescaped quote, unescaped as JSON (raw when that
    /// fails); nil when the text ends first. `end` is where the scan stopped.
    private static func value(in text: [UInt16], from start: Int) -> (value: String?, end: Int) {
        var cursor = start
        while cursor < text.count {
            if text[cursor] == 0x5C { cursor += 2; continue }
            if text[cursor] == 0x22 {
                let raw = String(decoding: text[start..<cursor], as: UTF16.self)
                return (unescape(raw), cursor)
            }
            cursor += 1
        }
        return (nil, cursor)
    }

    private static func unescape(_ raw: String) -> String {
        guard raw.contains("\\"),
              let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8),
                                                             options: .fragmentsAllowed) as? String else { return raw }
        return decoded
    }

    private static func index(of pattern: [UInt16], in text: [UInt16], from: Int) -> Int? {
        guard !pattern.isEmpty, text.count >= pattern.count, from <= text.count - pattern.count else { return nil }
        var start = from
        while start <= text.count - pattern.count {
            if text[start] == pattern[0], text[start..<(start + pattern.count)].elementsEqual(pattern) { return start }
            start += 1
        }
        return nil
    }

    private static func contains<C: Collection>(_ text: C, _ needle: String) -> Bool where C.Element == UInt16 {
        index(of: Array(needle.utf16), in: Array(text), from: 0) != nil
    }

    /// The SDK's `cq`: user lines that are not the user's own words.
    private static let notTyped = try! NSRegularExpression(
        pattern: #"^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*</ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*</ide_selection>\s*$)"#)
    /// The SDK's `pq`: a slash command, the title only when nothing else was said.
    private static let command = try! NSRegularExpression(pattern: #"<command-name>(.*?)</command-name>"#)

    /// The SDK's `v5`: the first thing the user typed, on one line, cut at 200 characters.
    static func firstPrompt(in head: [UInt16]) -> String {
        var fallback = ""
        let text = String(decoding: head, as: UTF16.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains(#""type":"user""#) || line.contains(#""type": "user""#),
                  !line.contains(#""tool_result""#),
                  !line.contains(#""isMeta":true"#), !line.contains(#""isMeta": true"#),
                  !line.contains(#""isCompactSummary":true"#), !line.contains(#""isCompactSummary": true"#),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "user",
                  let message = entry["message"] as? [String: Any] else { continue }
            var texts: [String] = []
            if let content = message["content"] as? String {
                texts.append(content)
            } else if let blocks = message["content"] as? [[String: Any]] {
                texts += blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            for raw in texts {
                var said = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !said.isEmpty else { continue }
                let range = NSRange(said.startIndex..., in: said)
                if let match = command.firstMatch(in: said, range: range) {
                    if fallback.isEmpty, let name = Range(match.range(at: 1), in: said) { fallback = String(said[name]) }
                    continue
                }
                if notTyped.firstMatch(in: said, range: range) != nil { continue }
                if said.count > promptLimit {
                    said = String(said.prefix(promptLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
                }
                return said
            }
        }
        return fallback
    }
}

/// `claude agents --json` did not answer with its listing.
public enum ClaudeAgentsError: Error, Equatable, CustomStringConvertible {
    case exited(Int32, String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .exited(let status, let errors):
            return "claude agents exited \(status)\(errors.isEmpty ? "" : ": \(errors)")"
        case .unreadable(let text): return "claude agents printed no listing: \(text)"
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
