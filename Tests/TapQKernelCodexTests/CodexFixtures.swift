import Foundation

/// Server lines for `codex app-server` 0.161.0.
///
/// NOT recorded: Codex is not installed on the maintainer's Mac. Each line is hand-written
/// to the shapes of the generated TypeScript bindings at `rust-v0.161.0`
/// (`codex-rs/app-server-protocol/schema/typescript/`, file named per fixture), with optional
/// members left out. The lead replaces them with `codex app-server generate-json-schema`
/// output and recorded lines once Codex is installed.
enum CodexFixtures {
    static let threadID = "019a1f2e-7c3d-7000-8000-00000000a001"
    static let turnID = "019a1f2e-7c3d-7000-8000-00000000b001"

    // MARK: - Responses (the members after `"id":n,`)

    /// `InitializeResponse.ts`; the `userAgent` format is `default_client.rs:152-177` (research §1.2).
    static func initialize(version: String = "0.161.0") -> String {
        #""result":{"userAgent":"codex_app_server/\#(version) (Mac OS 15.2.0; arm64) unknown","codexHome":"/Users/user/.codex","platformFamily":"unix","platformOs":"macos"}"#
    }

    /// `v2/GetAccountResponse.ts`, `v2/Account.ts`.
    static let accountChatGPT = #""result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}"#
    static let accountNone = #""result":{"account":null,"requiresOpenaiAuth":true}"#

    /// `v2/ThreadStartResponse.ts` (and `ThreadResumeResponse.ts`, a superset); `thread` is
    /// cut to the members TapQ reads. `sandbox` is a `SandboxPolicy` object.
    static func thread(id: String = threadID, approvalPolicy: String = "on-request") -> String {
        #""result":{"thread":{"id":"\#(id)","sessionId":"\#(id)","preview":"","ephemeral":false,"cliVersion":"0.161.0","turns":[]},"model":"gpt-5.5-codex","modelProvider":"openai","serviceTier":null,"disabledPluginIds":[],"cwd":"/work/project","instructionSources":[],"approvalPolicy":"\#(approvalPolicy)","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"reasoningEffort":null}"#
    }

    /// `v2/TurnStartResponse` → `{turn: Turn}` (`v2/Turn.ts`).
    static func turnStartResult(id: Int, turn: String = turnID) -> String {
        #"{"id":\#(id),"result":{"turn":{"id":"\#(turn)","items":[],"itemsView":"full","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}"#
    }

    // MARK: - Notifications

    static func turnStarted(_ turn: String = turnID) -> String {
        #"{"method":"turn/started","params":{"threadId":"\#(threadID)","turn":{"id":"\#(turn)","items":[],"itemsView":"full","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}"#
    }

    /// `v2/TurnCompletedNotification.ts`, `v2/TurnError.ts`.
    static func turnCompleted(_ status: String, error: String = "null", turn: String = turnID) -> String {
        #"{"method":"turn/completed","params":{"threadId":"\#(threadID)","turn":{"id":"\#(turn)","items":[],"itemsView":"summary","status":"\#(status)","error":\#(error),"startedAt":null,"completedAt":null,"durationMs":null}}}"#
    }

    static let usageLimitError = #"{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded","additionalDetails":null,"misalignment":null}"#

    /// `v2/ItemStartedNotification.ts`, `v2/ThreadItem.ts` (`commandExecution`).
    static let commandStarted = #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"item-cmd","pluginId":null,"scriptPath":null,"command":"npm test","cwd":"/work/project","processId":null,"source":"agent","status":"inProgress","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null},"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","startedAtMs":1791500000000}}"#

    /// `v2/ThreadItem.ts` (`fileChange`), `v2/FileUpdateChange.ts`.
    static let fileChangeStarted = #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"item-patch","changes":[{"path":"Sources/App.swift","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-a\n+b\n"},{"path":"README.md","kind":{"type":"add"},"diff":"+hello\n"}],"status":"inProgress"},"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","startedAtMs":1791500000000}}"#

    /// `v2/ItemCompletedNotification.ts`, `v2/ThreadItem.ts` (`agentMessage`).
    /// `phase` is `"commentary"`, `"final_answer"` or `null` (`v2/MessagePhase.ts`).
    static func agentMessageCompleted(_ text: String, id: String = "item-msg",
                                      phase: String = #""final_answer""#) -> String {
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"\#(id)","text":"\#(text)","phase":\#(phase),"memoryCitation":null,"delivery":null,"questions":null},"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","completedAtMs":1791500000000}}"#
    }

    /// `v2/ItemCompletedNotification.ts`: `commandStarted`'s item, ended (`CommandExecutionStatus`:
    /// `inProgress`, `completed`, `failed`, `declined`; `exitCode` a number or null).
    static func commandCompleted(status: String, exitCode: String) -> String {
        commandStarted
            .replacingOccurrences(of: #""method":"item/started""#, with: #""method":"item/completed""#)
            .replacingOccurrences(of: #""status":"inProgress""#, with: #""status":"\#(status)""#)
            .replacingOccurrences(of: #""exitCode":null"#, with: #""exitCode":\#(exitCode)"#)
    }

    /// `fileChangeStarted`'s item, ended (`PatchApplyStatus`).
    static func fileChangeCompleted(status: String) -> String {
        fileChangeStarted
            .replacingOccurrences(of: #""method":"item/started""#, with: #""method":"item/completed""#)
            .replacingOccurrences(of: #""status":"inProgress""#, with: #""status":"\#(status)""#)
    }

    /// `commandStarted` with these `commandActions` (`v2/CommandAction.ts`).
    static func commandStarted(actions: String) -> String {
        commandStarted.replacingOccurrences(of: #""commandActions":[]"#, with: #""commandActions":\#(actions)"#)
    }

    /// `v2/ServerRequestResolvedNotification.ts`; `RequestId` is `string | number`.
    static func resolved(_ requestID: String) -> String {
        #"{"method":"serverRequest/resolved","params":{"threadId":"\#(threadID)","requestId":\#(requestID)}}"#
    }

    // MARK: - Server requests

    /// `v2/CommandExecutionRequestApprovalParams.ts`.
    static func commandApproval(id: Int) -> String {
        #"{"id":\#(id),"method":"item/commandExecution/requestApproval","params":{"kind":"command","threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-cmd","startedAtMs":1791500000000,"environmentId":null,"reason":"needs network to install","command":"npm install","cwd":"/work/project"}}"#
    }

    static let networkApproval = #"{"id":"net-1","method":"item/commandExecution/requestApproval","params":{"kind":"command","threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-cmd","startedAtMs":1791500000000,"environmentId":null,"networkApprovalContext":{"host":"registry.npmjs.org","protocol":"https"},"command":null,"cwd":null}}"#

    /// `v2/FileChangeRequestApprovalParams.ts`: no diff; it lives on the started item.
    static func fileChangeApproval(id: Int, item: String = "item-patch") -> String {
        #"{"id":\#(id),"method":"item/fileChange/requestApproval","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"\#(item)","startedAtMs":1791500000000,"reason":null}}"#
    }

    /// `v2/PermissionsRequestApprovalParams.ts`, `v2/RequestPermissionProfile.ts`.
    static func permissionsApproval(id: Int) -> String {
        #"{"id":\#(id),"method":"item/permissions/requestApproval","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-perm","environmentId":null,"startedAtMs":1791500000000,"cwd":"/work/project","reason":"fetch the schema","permissions":{"network":{"enabled":true},"fileSystem":null}}}"#
    }

    /// `v2/ToolRequestUserInputParams.ts`, `…Question.ts`, `…Option.ts`.
    static let userInput = #"{"id":40,"method":"item/tool/requestUserInput","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-ask","questions":[{"id":"db","header":"Database","question":"Which database?","isOther":true,"isSecret":false,"options":[{"label":"Postgres","description":"server"},{"label":"SQLite","description":"file"}]},{"id":"name","header":"Name","question":"What should the table be called?","isOther":false,"isSecret":false,"options":null}],"isBlocking":true,"autoResolutionMs":null}}"#

    static let mixedSecretInput = #"{"id":41,"method":"item/tool/requestUserInput","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-ask","questions":[{"id":"token","header":"Token","question":"Paste the API token","isOther":true,"isSecret":true,"options":null},{"id":"env","header":"Env","question":"Which environment?","isOther":false,"isSecret":false,"options":[{"label":"staging","description":""},{"label":"prod","description":""}]}],"isBlocking":true,"autoResolutionMs":null}}"#

    static let allSecretInput = #"{"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","itemId":"item-ask","questions":[{"id":"token","header":"Token","question":"Paste the API token","isOther":true,"isSecret":true,"options":null}],"isBlocking":true,"autoResolutionMs":null}}"#

    /// `v2/McpServerElicitationRequestParams.ts` (form mode).
    static let elicitation = #"{"id":50,"method":"mcpServer/elicitation/request","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":null,"serverName":"github","mode":"form","_meta":null,"message":"Sign in","requestedSchema":{"type":"object","properties":{}}}}"#

    /// `ServerRequest.ts`: a request TapQ does not handle (dynamic tools are never registered).
    static let dynamicToolCall = #"{"id":60,"method":"item/tool/call","params":{"threadId":"019a1f2e-7c3d-7000-8000-00000000a001","turnId":"019a1f2e-7c3d-7000-8000-00000000b001","callId":"c1","tool":"x","arguments":{}}}"#
}
