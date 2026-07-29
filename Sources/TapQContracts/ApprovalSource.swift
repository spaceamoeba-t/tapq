import Foundation

/// The agent hook event that caused an approval to reach the broker.
///
/// The raw values are the strings the shims put on the wire; they are part of the
/// shim↔broker contract and must not be renamed. The type lives here rather than in
/// `TapQWireProtocol` so `ApprovalRequest` can carry it in process — the wire module
/// depends on contracts, never the reverse — and `TapQWireProtocol` re-exports it under
/// the same name so its `Codable` encoding and every existing consumer are unchanged.
public enum ApprovalSource: String, Codable, Sendable, Equatable {
    case preToolUse = "pre_tool_use"
    case permissionRequest = "permission_request"
}
