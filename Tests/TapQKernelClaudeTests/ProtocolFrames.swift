import Foundation

/// Hand-written frames for what K0 never recorded, in the shapes the Agent SDK typings
/// (`sdk.d.ts` 0.3.293) and the Python SDK give. Unlike `Fixtures`, nothing here came off a
/// live CLI.
enum ProtocolFrames {
    // MARK: - user: tool results (2026-10-15, after `Fixtures.userToolResultSuccess`)

    /// A Bash call that exited non-zero: Claude Code reports it as an error result.
    static let userToolResultExitCode = ##"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_failed","type":"tool_result","content":"Exit code 1","is_error":true}]},"parent_tool_use_id":null,"session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// The result of `Fixtures.canUseToolDeniedBash` once TapQ denied it (03b's log: an error
    /// whose content is the deny's message, and no `tool_result_meta`).
    static let userToolResultDenied = ##"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user said no.","is_error":true,"tool_use_id":"toolu_01Cco4HJbHQP1Pde5MhjgmZU"}]},"parent_tool_use_id":null,"session_id":"bae71aec-59ba-4f25-979e-af5e8955223f"}"##
    /// A subagent's tool result: `parent_tool_use_id` names its Task call.
    static let userToolResultSubagent = ##"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_sub","type":"tool_result","content":"ok"}]},"parent_tool_use_id":"toolu_task","session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// The end of `Fixtures.systemTaskStarted`'s task: the keys 05-midturn's log lists for it.
    static let taskNotification = ##"{"type":"system","subtype":"task_notification","task_id":"b5f31pg24","tool_use_id":"toolu_015F377fkrWdRbGbUoczbpN8","status":"completed","output_file":"/tmp/out","summary":"Count 1 to 15","session_id":"0dc923f4-4ec1-41fe-b53a-880bfa49175f","uuid":"00000000-0000-4000-8000-000000000001"}"##
    /// A failed background task, by its tool call.
    static func taskEnded(_ toolUseID: String, _ status: String) -> String {
        ##"{"type":"system","subtype":"task_notification","task_id":"t","tool_use_id":"\##(toolUseID)","status":"\##(status)","session_id":"0dc923f4-4ec1-41fe-b53a-880bfa49175f"}"##
    }
    static func taskStarted(_ toolUseID: String) -> String {
        ##"{"type":"system","subtype":"task_started","task_id":"t","tool_use_id":"\##(toolUseID)","description":"Run it","is_backgrounded":true,"task_type":"local_bash","session_id":"0dc923f4-4ec1-41fe-b53a-880bfa49175f"}"##
    }
    static func toolResult(_ toolUseID: String) -> String {
        ##"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"\##(toolUseID)","type":"tool_result","content":"Command running in background with ID: t"}]},"parent_tool_use_id":null,"session_id":"0dc923f4-4ec1-41fe-b53a-880bfa49175f"}"##
    }
    /// A task with no tool call behind it.
    static let taskStartedWithoutToolUse = ##"{"type":"system","subtype":"task_started","task_id":"t2","description":"Watch","task_type":"local_bash","session_id":"0dc923f4-4ec1-41fe-b53a-880bfa49175f"}"##
    /// Two parallel tool calls' results in one frame.
    static let userToolResultsTwo = ##"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"a"},{"tool_use_id":"toolu_b","type":"tool_result","content":"b","is_error":true}]},"parent_tool_use_id":null,"session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##

    // MARK: - result (§2.5)

    /// An interrupt that landed while the model was generating.
    static let resultAbortedStreaming = ##"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":[],"session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// An API failure: `subtype` success, `is_error` true, the text in `result`.
    static let resultAPIError = ##"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded","terminal_reason":"api_error","session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// An error subtype whose reason is only in `errors`.
    static let resultMaxTurns = ##"{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","errors":["Reached maximum number of turns (3)","stopping"],"session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// An error result that gives no text at all.
    static let resultModelErrorBare = ##"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"model_error","session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##

    // MARK: - Control (§2.2, §2.3)

    /// The CLI withdraws the K0 Bash request (`Fixtures.canUseToolBash`).
    static let cancelBashRequest = ##"{"type":"control_cancel_request","request_id":"602de92a-6878-4ce9-b730-d509f891207d"}"##
    /// A second request outstanding next to `Fixtures.canUseToolBash`: a subagent's WebFetch.
    static let canUseToolWebFetch = ##"{"type":"control_request","request_id":"req-webfetch","request":{"subtype":"can_use_tool","tool_name":"WebFetch","display_name":"Fetch","input":{"url":"https://example.org/docs","prompt":"Summarize the page"},"tool_use_id":"toolu_web","agent_id":"agent-2"}}"##
    /// An MCP tool whose input keys are not in sorted order, with a safety warning in ANSI
    /// and "don't ask again" suppressed.
    static let canUseToolGmailSend = ##"{"type":"control_request","request_id":"req-gmail","request":{"subtype":"can_use_tool","tool_name":"mcp__gmail__send_message","input":{"to":"bob@example.com","subject":"Notes","body":"See attached."},"title":"Send an email","decision_reason":"\u001b[1mSends mail\u001b[0m on your behalf","suppress_always_allow_rule":true,"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"mcp__gmail__send_message"}],"behavior":"allow","destination":"localSettings"}],"tool_use_id":"toolu_gmail"}}"##
    /// An Edit, whose path is what the prompt names.
    static let canUseToolEdit = ##"{"type":"control_request","request_id":"req-edit","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"/w/README.md","old_string":"a","new_string":"b"},"tool_use_id":"toolu_edit"}}"##
    /// AskUserQuestion with two questions, the second multi-select.
    static let canUseToolTwoQuestions = ##"{"type":"control_request","request_id":"req-questions","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","header":"Database","options":[{"label":"Postgres","description":"Server"},{"label":"SQLite","description":"File"}],"multiSelect":false},{"question":"Which checks should run?","header":"Checks","options":[{"label":"lint"},{"label":"test"},{"label":"build"}],"multiSelect":true}]},"tool_use_id":"toolu_q","requires_user_interaction":true}}"##
    static let elicitation = ##"{"type":"control_request","request_id":"req-elicit","request":{"subtype":"elicitation","mcp_server_name":"github","message":"Sign in to GitHub","mode":"url","url":"https://github.com/login/device"}}"##
    static let requestUserDialog = ##"{"type":"control_request","request_id":"req-dialog","request":{"subtype":"request_user_dialog","dialog_kind":"file_picker","payload":{}}}"##
    /// A subtype TapQ never registered for.
    static let hookCallback = ##"{"type":"control_request","request_id":"req-hook","request":{"subtype":"hook_callback","callback_id":"cb-1","input":{}}}"##
    static let controlResponseError = ##"{"type":"control_response","response":{"subtype":"error","request_id":"tapq-1","error":"no turn to interrupt"}}"##

    // MARK: - Observability (§2.1)

    static let keepAlive = ##"{"type":"keep_alive"}"##
    static let authStatus = ##"{"type":"auth_status","isAuthenticating":false,"output":[]}"##
    static let toolUseSummary = ##"{"type":"tool_use_summary","summary":"Ran 2 commands"}"##
    static let conversationReset = ##"{"type":"conversation_reset","new_conversation_id":"c-2","trigger":"clear"}"##
    static let modelRefusal = ##"{"type":"system","subtype":"model_refusal_no_fallback","session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// Prose, a server tool, a tool use and a block type the codec has never seen, in one frame.
    static let assistantMixedBlocks = ##"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running it."},{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"x"}},{"type":"tool_use","id":"toolu_long","name":"Bash","input":{"command":"swift test --filter 'TapQKernelClaudeTests.ClaudeFrameMapperTests' --parallel --num-workers 4 2>&1 | tee /tmp/claude-tests.txt"}},{"type":"redacted_thinking","data":"…"}]},"session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
    /// CLI debug output on stdout (Python SDK #347).
    static let chatter = "[SandboxDebug] seatbelt profile applied"
}
