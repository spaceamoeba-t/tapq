import Foundation

/// The permission mode an agent reports on its hook payloads.
///
/// Claude Code sends exactly one of these five strings, and the Codex hook contract
/// mirrors them. Any other value — an unrecognized mode, or an agent such as Cursor or
/// OpenCode that sends none at all — parses to nil and earns no automatic behavior, so a
/// mode TapQ has never seen is treated as the cautious `default`.
///
/// Matching is exact: these are protocol tokens, not prose, and a near-miss spelling is a
/// contract change worth noticing rather than guessing at.
public enum AgentPermissionMode: String, Sendable, Equatable, CaseIterable {
    /// Ask before every matched tool call.
    case `default`
    /// Accept file edits without asking; everything else still prompts.
    case acceptEdits
    /// Plan first, execute nothing.
    case plan
    /// Stop asking for this session.
    case dontAsk
    /// Stop asking, permission checks included.
    case bypassPermissions

    /// The tools `acceptEdits` answers on the user's behalf. Bash is deliberately absent:
    /// accepting edits is not accepting commands.
    public static let editTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Parses an unnormalized mode string, including the nil an adapter sends when its
    /// agent reports no mode.
    public init?(_ raw: String?) {
        guard let raw, let mode = AgentPermissionMode(rawValue: raw) else { return nil }
        self = mode
    }

    /// True when the agent would not have asked about this tool anyway, so TapQ has
    /// nothing to confirm hands-free.
    public func autoAllows(toolName: String) -> Bool {
        switch self {
        case .dontAsk, .bypassPermissions:
            return true
        case .acceptEdits:
            return Self.editTools.contains(toolName)
        case .default, .plan:
            return false
        }
    }

    /// True when the user has opted out of being asked at all, which makes a spoken
    /// stop question an interruption they did not want. `acceptEdits` is not such an
    /// opt-out: it silences file edits, not questions.
    public var skipsStopQuestions: Bool {
        switch self {
        case .dontAsk, .bypassPermissions:
            return true
        case .default, .acceptEdits, .plan:
            return false
        }
    }
}
