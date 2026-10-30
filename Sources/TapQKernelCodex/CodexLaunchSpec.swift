import Foundation
import TapQKernel

/// One `codex app-server` child: argv, environment and working directory, and nothing else.
public struct CodexLaunchSpec: Sendable, Equatable {
    public static let executableName = "codex"
    /// stdio is the app-server's default transport (research §1.1).
    public static let arguments = ["app-server"]

    public let executablePath: String
    public let workspace: URL
    public let environment: [String: String]

    /// `environment` is the parent's; the spec keeps its sanitized copy.
    public init(executablePath: String, workspace: URL, environment: [String: String]) {
        self.executablePath = executablePath
        self.workspace = workspace
        self.environment = Self.sanitized(environment)
    }

    public var arguments: [String] { Self.arguments }

    /// T4: Codex hands its whole environment to every command it runs, so TapQ's own
    /// variables and `OPENAI_API_KEY` never reach it. The app-server authenticates from its
    /// own login store, never from the environment (research §1.9); everything else stays.
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !key.hasPrefix("TAPQ_") && key != "OPENAI_API_KEY" }
    }
}

/// D5 for Codex. The app-server is experimental (T7), so the range is the one version whose
/// source TapQ was built against.
public enum CodexVersions {
    public static let supported = VersionRange(floor: "0.161.0", cap: "0.161")

    /// `codex --version` prints "codex-cli 0.161.0". The version token is returned whole, so
    /// a prerelease ("0.162.0-alpha.20") reaches `VersionRange` as itself and is refused.
    public static func parse(versionOutput: String) -> String? {
        let firstLine = versionOutput.split(whereSeparator: \.isNewline).first ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, ["codex-cli", "codex"].contains(words[0]),
              words[1].first?.isNumber == true else { return nil }
        return String(words[1])
    }

    /// The in-band check: `initialize`'s `userAgent` is
    /// "<originator>/<version> (<os> <os-version>; <arch>) <terminal-ua>" (research §1.2).
    static func parse(userAgent: String) -> String? {
        guard let slash = userAgent.firstIndex(of: "/") else { return nil }
        let version = userAgent[userAgent.index(after: slash)...].prefix { !$0.isWhitespace }
        return version.first?.isNumber == true ? String(version) : nil
    }
}
