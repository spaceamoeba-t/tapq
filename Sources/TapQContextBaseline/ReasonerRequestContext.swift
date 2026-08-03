import Foundation
import TapQContracts

/// Maps the two things a user is made to answer — a broker approval and a question the
/// agent asked — onto the portable context a stage-2 reasoner reads.
///
/// `ReasonerContext` is deliberately decoupled from `ApprovalRequest` — a corpus builds
/// contexts with no broker in sight — so this is the one place the two meet. It lives
/// beside the contract rather than in the runtime because the mapping is pure data and
/// the conventions it fixes (`commandText` and `agentQuestionToolName`, below) are what
/// the bench corpus was recorded against; a runtime-local copy would drift from the
/// corpus without failing anything.
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
            toolInput: ReasonerContext.openSchemaToolInput(
                toolName: request.toolName,
                toolInput: request.toolInput
            ),
            cwd: request.cwd,
            agentName: request.agent.displayName,
            summary: request.summary,
            detail: ReasonerContext.nonblank(request.detail)
        )
    }

    /// The synthetic tool name every question request carries.
    ///
    /// `ReasonerContext.toolName` is non-optional — every context has to name what the
    /// user is being asked about — but a question the agent asked in its final reply ran
    /// no tool at all. Rather than weaken the field or invent a per-agent name, question
    /// requests are labeled with this one constant. It is a value the adapters can never
    /// produce (they name real tools: `Bash`, `Write`, `apply_patch`, ...), so `tool_name
    /// == "AgentQuestion"` is an exact, greppable discriminator for a question row in a
    /// prompt, in `bench/reasoner-scenarios-v1.ndjson`, and in the shadow-review log.
    ///
    /// Deliberately *not* `StopQuestion`, which is the internal tool name the stop
    /// coordinator puts on its `ApprovalRequest`: that name describes which runtime path
    /// raised the request, and the reasoner is told what it is judging, not which
    /// component asked.
    static let agentQuestionToolName = "AgentQuestion"

    /// Builds the reasoner's view of one question the agent asked in its final reply.
    ///
    /// The stop coordinator turns a yes/no question into an `ApprovalRequest` whose
    /// `summary` *is* the question, so `summary` and `questionText` deliberately carry
    /// the same string here: `summary` stays what it always was — the line already spoken
    /// to the user — and `questionText` is the field that says the line is a question
    /// rather than a description of an action. The mapping does not invent a second,
    /// different summary for a question, because there is no second thing the user heard.
    ///
    /// A question has no command line, so `commandText` is absent. `cwd` and `detail`
    /// come across as the request carries them, which for a coordinator-built question is
    /// `nil` and empty — a question row therefore puts strictly less in front of the
    /// model, and into the shadow log, than a `Bash` row does.
    ///
    /// `optionLabels` is a parameter rather than something read off the request because
    /// the request cannot carry it: the yes/no path has no labels, and the multi-option
    /// path resolves through `SelectionRequest`/`SelectionController`, which has no
    /// escalation plumbing yet — a `SelectionResult` is a choice, not an allow/deny, so
    /// there is nothing there for a `RequiredConfirmation` to raise. **Multi-option
    /// selections are therefore not assessed today.** When that path is wired, it passes
    /// its option labels here; until then every caller leaves this `nil`.
    init(questionRequest request: ApprovalRequest, optionLabels: [String]? = nil) {
        self.init(
            toolName: ReasonerContext.agentQuestionToolName,
            cwd: request.cwd,
            agentName: request.agent.displayName,
            summary: request.summary,
            detail: ReasonerContext.nonblank(request.detail),
            questionText: request.summary,
            optionLabels: ReasonerContext.nonblankLabels(optionLabels)
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

    /// Preserves arguments for tools whose schema TapQ does not own.
    ///
    /// Codex identifies connector calls with `mcp__<server>__<tool>`. Their arguments
    /// are defined by the MCP server and can encode the actual consequence in any field:
    /// a recipient, repository, record identifier, message body, delete flag, or an
    /// application-specific nested object. Reducing that object to a guessed "primary"
    /// string would give the reasoner a misleadingly incomplete action, so the exact
    /// object is carried instead. The prompt renderer applies the size bound at the
    /// model boundary; keeping the contract lossless here also makes that truncation
    /// explicit rather than silently dropping fields during mapping.
    ///
    /// Other tools continue to use the pinned `commandText` convention above. This keeps
    /// the established corpus stable and avoids sending file bodies merely because a
    /// closed-schema editor tool happened to include them alongside its primary path.
    static func openSchemaToolInput(
        toolName: String,
        toolInput: [String: JSONValue]?
    ) -> [String: JSONValue]? {
        let prefix = "mcp__"
        guard toolName.hasPrefix(prefix) else { return nil }
        let remainder = toolName.dropFirst(prefix.count)
        guard let separator = remainder.range(of: "__"),
              !remainder[..<separator.lowerBound].isEmpty,
              !remainder[separator.upperBound...].isEmpty else { return nil }
        return toolInput
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

    /// The same rule applied to a list: blank labels are dropped, and a list with nothing
    /// left in it is absence rather than an empty list. A question that offered no
    /// choices and a question whose choices were all blank are the same fact, and the
    /// renderer omits both.
    private static func nonblankLabels(_ labels: [String]?) -> [String]? {
        guard let labels else { return nil }
        let kept = labels.compactMap(nonblank)
        return kept.isEmpty ? nil : kept
    }
}
