import Foundation

/// One of an agent's conversations in a folder, as the agent's own store records it: a Claude
/// Code session or a Codex thread, started by TapQ or on screen (maintainer, 2026-10-12).
public struct SessionSummary: Sendable, Equatable {
    /// What a resume takes: Claude Code's session id, Codex's thread id.
    public let id: String
    /// The agent's own name for it: a title the user gave it, the agent's summary, or the first
    /// thing the user said in it.
    public let title: String
    public let updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// One of an agent's conversations in a folder that a process has open now (2026-10-12): the
/// Claude app, a terminal, a background session, or TapQ's own, which the kernel, knowing its
/// own session, leaves out.
public struct OpenSession: Sendable, Equatable {
    public let id: String
    /// As `SessionSummary.title`.
    public let title: String
    /// The agent says it is at work in it; otherwise it is idle.
    public let working: Bool

    public init(id: String, title: String, working: Bool) {
        self.id = id
        self.title = title
        self.working = working
    }
}

/// An agent's conversations in one folder, newest first. Reading them starts no session and
/// changes nothing; a throw is told as a listing that failed, never fatal.
public protocol SessionCatalog: Sendable {
    func sessions(in workspace: URL) async throws -> [SessionSummary]
    /// Those of the folder's conversations a process has open now, as the agent itself reports
    /// them (2026-10-12). A throw means it cannot tell, and TapQ goes on as if none were.
    func openSessions(in workspace: URL) async throws -> [OpenSession]
}

extension SessionCatalog {
    /// An agent that cannot tell (Codex has no such report) has none open.
    public func openSessions(in workspace: URL) async throws -> [OpenSession] { [] }
}
