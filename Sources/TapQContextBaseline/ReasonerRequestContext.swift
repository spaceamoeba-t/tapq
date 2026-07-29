import Foundation
import TapQContracts

/// Maps a broker approval onto the flat context a stage-2 reasoner reads.
///
/// `ReasonerContext` is deliberately decoupled from `ApprovalRequest` — a corpus builds
/// contexts with no broker in sight — so this is the one place the two meet. It lives
/// beside the contract rather than in the runtime because the mapping is pure data and
/// the convention it fixes (`commandText`, below) is what the bench corpus was recorded
/// against; a runtime-local copy would drift from the corpus without failing anything.
public extension ReasonerContext {
    /// Builds the reasoner's view of one pending approval.
    ///
    /// Presentation strings come across unchanged: `summary` is the line already spoken
    /// to the user, and `detail` is the longer text behind "details". A blank `detail`
    /// becomes `nil` rather than an empty string, because the prompt renderer omits
    /// absent fields and an empty `detail:` line would read as a detail that exists and
    /// says nothing.
    ///
    /// `agentName` is `AgentIdentity.displayName`, matching the corpus: bundled adapters
    /// appear as `Claude Code` and `Codex`, and a legacy client that predates agent
    /// identity appears as `The agent`.
    ///
    /// `cwd` is passed through as the request carried it, including `nil` — the shims
    /// send null when the agent's hook payload omits it.
    init(approvalRequest request: ApprovalRequest) {
        self.init(
            toolName: request.toolName,
            commandText: ReasonerContext.commandText(
                toolName: request.toolName,
                toolInput: request.toolInput
            ),
            cwd: request.cwd,
            agentName: request.agent.displayName,
            summary: request.summary,
            detail: ReasonerContext.nonblank(request.detail)
        )
    }

    /// The tool's command line or primary argument, by the convention the corpus fixes.
    ///
    /// The keys are the ones the bundled shims actually populate (`ToolSummary` and
    /// `CodexToolSummary` read the same fields to build their spoken summaries), so a
    /// mapping that disagreed with this table would be describing a different request
    /// than the one the user heard:
    ///
    /// * `Bash` — the full command line under `command`.
    /// * `apply_patch` — the patch text, which Codex also sends under `command`.
    /// * `Write`, `Edit`, `MultiEdit` — `file_path`, that tool's primary argument.
    /// * `NotebookEdit` — `notebook_path`, falling back to `file_path`.
    /// * Anything else — `nil`. A tool whose input is not a command has no command text,
    ///   and inventing one from an arbitrary field would put a value in front of the
    ///   model that no adapter ever meant as the action.
    ///
    /// Absent input, a missing key, a non-string value, and a blank string all collapse
    /// to `nil` for the same reason: the context must not claim a command it does not
    /// have. `summary` still describes the action in every one of those cases.
    static func commandText(
        toolName: String,
        toolInput: [String: JSONValue]?
    ) -> String? {
        guard let toolInput else { return nil }
        let keys: [String]
        switch toolName {
        case "Bash", "apply_patch": keys = ["command"]
        case "Write", "Edit", "MultiEdit": keys = ["file_path"]
        case "NotebookEdit": keys = ["notebook_path", "file_path"]
        default: return nil
        }
        for key in keys {
            if let value = nonblank(toolInput[key]?.stringValue) { return value }
        }
        return nil
    }

    /// Blank-to-`nil` normalization. Whitespace-only text is absence with extra
    /// characters, and the prompt renderer already treats the two the same way.
    private static func nonblank(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
