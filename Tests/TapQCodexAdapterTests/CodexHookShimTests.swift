import XCTest
@testable import TapQCodexAdapter
import TapQContracts
import TapQWireProtocol

final class CodexHookShimTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    private func input(_ json: String) -> Data { Data(json.utf8) }

    private func permissionObject(
        toolName: String = "Bash",
        toolInput: JSONValue = .object(["command": .string("swift test")])
    ) -> [String: JSONValue] {
        [
            "hook_event_name": .string("PermissionRequest"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "tool_name": .string(toolName),
            "tool_input": toolInput,
        ]
    }

    private func permissionInput(
        toolName: String = "Bash",
        toolInput: JSONValue = .object(["command": .string("swift test")])
    ) -> Data {
        try! JSONEncoder().encode(permissionObject(toolName: toolName, toolInput: toolInput))
    }

    private func requestUserOption(
        label: String,
        description: String
    ) -> JSONValue {
        .object([
            "label": .string(label),
            "description": .string(description),
        ])
    }

    private func requestUserQuestion(
        id: String = "deployment_target",
        header: String = "Deploy",
        question: String = "Where should this be deployed?",
        options: [JSONValue]? = nil
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "header": .string(header),
            "question": .string(question),
            "options": .array(options ?? [
                requestUserOption(
                    label: "Staging",
                    description: "Deploy to the staging environment."
                ),
                requestUserOption(
                    label: "Production",
                    description: "Deploy to the production environment."
                ),
            ]),
        ])
    }

    private func requestUserInputObject(
        questions: [JSONValue]? = nil,
        toolUseID: String? = "tool-use-1"
    ) -> [String: JSONValue] {
        let defaultQuestions: [JSONValue] = [
            requestUserQuestion(),
        ]
        var object: [String: JSONValue] = [
            "hook_event_name": .string("PreToolUse"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "tool_name": .string("request_user_input"),
            "tool_input": .object([
                "questions": .array(questions ?? defaultQuestions),
            ]),
        ]
        if let toolUseID {
            object["tool_use_id"] = .string(toolUseID)
        }
        return object
    }

    private func requestUserInput(
        questions: [JSONValue]? = nil,
        toolUseID: String? = "tool-use-1"
    ) -> Data {
        try! JSONEncoder().encode(
            requestUserInputObject(questions: questions, toolUseID: toolUseID)
        )
    }

    private func stopObject(
        message: JSONValue = .string("Continue?"),
        active: Bool = false
    ) -> [String: JSONValue] {
        [
            "hook_event_name": .string("Stop"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "stop_hook_active": .bool(active),
            "last_assistant_message": message,
        ]
    }

    private func stopInput(
        message: JSONValue = .string("Continue?"),
        active: Bool = false
    ) -> Data {
        try! JSONEncoder().encode(stopObject(message: message, active: active))
    }

    private func userPromptSubmitObject() -> [String: JSONValue] {
        [
            "hook_event_name": .string("UserPromptSubmit"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "prompt": .string("Plan the deployment."),
        ]
    }

    private func userPromptSubmitInput() -> Data {
        try! JSONEncoder().encode(userPromptSubmitObject())
    }

    private func permissionOutput(
        _ stdout: String?
    ) throws -> (event: String, behavior: String, message: String?) {
        let data = Data((stdout ?? "").utf8)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let inner = object["hookSpecificOutput"]?.objectValue
        let decision = inner?["decision"]?.objectValue
        return (
            inner?["hookEventName"]?.stringValue ?? "",
            decision?["behavior"]?.stringValue ?? "",
            decision?["message"]?.stringValue
        )
    }

    // MARK: - UserPromptSubmit steering

    func testUserPromptSubmitEmitsExactContextShapeWhenSteeringEnabled() throws {
        var steeringChecks = 0
        var reachedBroker = false
        let result = CodexHookShim.handle(
            stdinData: userPromptSubmitInput(),
            steeringEnabled: {
                steeringChecks += 1
                return true
            }
        ) { _, _ in
            reachedBroker = true
            return Data()
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(steeringChecks, 1)
        XCTAssertFalse(reachedBroker)
        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        XCTAssertEqual(Set(output.keys), ["hookSpecificOutput"])
        let inner = try XCTUnwrap(output["hookSpecificOutput"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), ["hookEventName", "additionalContext"])
        XCTAssertEqual(inner["hookEventName"]?.stringValue, "UserPromptSubmit")
        XCTAssertEqual(inner["additionalContext"]?.stringValue, CodexHookShim.steeringNudge)
        XCTAssertTrue(CodexHookShim.steeringNudge.contains("request_user_input when available"))
    }

    func testUserPromptSubmitIsSilentWhenSteeringDisabledOrDefaultedOff() {
        var reachedBroker = false
        let disabled = CodexHookShim.handle(
            stdinData: userPromptSubmitInput(),
            steeringEnabled: { false }
        ) { _, _ in
            reachedBroker = true
            return Data()
        }
        let defaulted = CodexHookShim.handle(stdinData: userPromptSubmitInput()) { _, _ in
            reachedBroker = true
            return Data()
        }

        XCTAssertEqual(disabled, CodexHookShim.passThrough)
        XCTAssertEqual(defaulted, CodexHookShim.passThrough)
        XCTAssertFalse(reachedBroker)
    }

    func testUserPromptSubmitInvalidAndSubagentInputsStaySilent() {
        var inputs: [[String: JSONValue]] = []
        for key in [
            "session_id", "turn_id", "transcript_path", "cwd", "model",
            "permission_mode", "prompt",
        ] {
            var missing = userPromptSubmitObject()
            missing.removeValue(forKey: key)
            inputs.append(missing)
        }
        var emptyPrompt = userPromptSubmitObject()
        emptyPrompt["prompt"] = .string(" ")
        inputs.append(emptyPrompt)
        var invalidTranscript = userPromptSubmitObject()
        invalidTranscript["transcript_path"] = .number(1)
        inputs.append(invalidTranscript)
        var invalidMode = userPromptSubmitObject()
        invalidMode["permission_mode"] = .string("futureMode")
        inputs.append(invalidMode)
        for (key, value) in [
            ("agent_id", JSONValue.string("agent-1")),
            ("agent_type", JSONValue.string("worker")),
            ("agent_id", JSONValue.null),
            ("agent_type", JSONValue.null),
        ] {
            var subagent = userPromptSubmitObject()
            subagent[key] = value
            inputs.append(subagent)
        }

        for object in inputs {
            var steeringChecked = false
            var reachedBroker = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object),
                steeringEnabled: {
                    steeringChecked = true
                    return true
                }
            ) { _, _ in
                reachedBroker = true
                return Data()
            }

            XCTAssertEqual(result, CodexHookShim.passThrough)
            XCTAssertFalse(steeringChecked)
            XCTAssertFalse(reachedBroker)
        }
    }

    // MARK: - PreToolUse request_user_input

    func testRequestUserInputForwardsSelectionAndReturnsModelVisibleDeny() throws {
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(
                #"{"selected_indices":[1],"selected_labels":["Production"]}"#.utf8
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(output["hookSpecificOutput"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), [
            "hookEventName", "permissionDecision", "permissionDecisionReason",
        ])
        XCTAssertEqual(inner["hookEventName"]?.stringValue, "PreToolUse")
        XCTAssertEqual(inner["permissionDecision"]?.stringValue, "deny")
        let reason = try XCTUnwrap(inner["permissionDecisionReason"]?.stringValue)
        XCTAssertTrue(
            reason.contains(
                #"{"answers":{"deployment_target":{"answers":["Production"]}}}"#
            )
        )
        XCTAssertTrue(reason.contains("Treat this request_user_input call as successful"))
        XCTAssertTrue(reason.contains("Do not re-ask this question"))
        XCTAssertNil(output["decision"])

        XCTAssertEqual(captured?["type"]?.stringValue, WireType.selection)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "codex")
        XCTAssertEqual(captured?["agent"]?["display_name"]?.stringValue, "Codex")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "session-1")
        XCTAssertEqual(captured?["request_id"]?.stringValue, "tool-use-1")
        XCTAssertEqual(
            captured?["question"]?.stringValue,
            "Where should this be deployed?"
        )
        XCTAssertEqual(captured?["multi_select"]?.boolValue, false)
        XCTAssertEqual(captured?["options"]?.arrayValue?.count, 2)
        XCTAssertEqual(
            captured?["options"]?.arrayValue?.first?["label"]?.stringValue,
            "Staging"
        )
        XCTAssertEqual(
            captured?["options"]?.arrayValue?.last?["description"]?.stringValue,
            "Deploy to the production environment."
        )
        XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version)
        XCTAssertEqual(capturedTimeout, CodexHookShim.approvalTimeout)

        var authenticated = try XCTUnwrap(captured)
        authenticated["token"] = .string("token")
        let request = try BrokerRequest(from: JSONEncoder().encode(authenticated))
        guard case .selection(let selection) = request else {
            return XCTFail("expected selection request")
        }
        XCTAssertEqual(selection.requestID, "tool-use-1")
        XCTAssertEqual(selection.agent, AgentIdentity(id: "codex", displayName: "Codex"))
        XCTAssertFalse(selection.multiSelect)
    }

    func testRequestUserInputAcceptsThreeValidOptionsAndExplicitNonsecret() {
        var question = requestUserQuestion(options: [
            requestUserOption(label: "One", description: "First option."),
            requestUserOption(label: "Two", description: "Second option."),
            requestUserOption(label: "Three", description: "Third option."),
        ]).objectValue ?? [:]
        question["isSecret"] = .bool(false)
        var optionCount: Int?
        let result = CodexHookShim.handle(
            stdinData: requestUserInput(questions: [.object(question)])
        ) { message, _ in
            optionCount = message["options"]?.arrayValue?.count
            return Data(#"{"selected_indices":[2],"selected_labels":["Three"]}"#.utf8)
        }

        XCTAssertEqual(optionCount, 3)
        XCTAssertNotNil(result.stdout)
    }

    func testRequestUserInputResponseJSONSafelyEscapesTheSelectedLabel() throws {
        let selectedLabel = #"Production "blue""#
        let question = requestUserQuestion(options: [
            requestUserOption(label: "Staging", description: "Use staging."),
            requestUserOption(label: selectedLabel, description: "Use production."),
        ])
        let brokerReply = try JSONEncoder().encode([
            "selected_indices": JSONValue.array([.number(1)]),
            "selected_labels": .array([.string(selectedLabel)]),
        ])
        let result = CodexHookShim.handle(
            stdinData: requestUserInput(questions: [question])
        ) { _, _ in
            brokerReply
        }

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let reason = try XCTUnwrap(
            output["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue
        )
        let prefix = try XCTUnwrap(reason.range(of: "response JSON: "))
        let suffix = try XCTUnwrap(
            reason.range(
                of: ". Do not re-ask",
                range: prefix.upperBound..<reason.endIndex
            )
        )
        let responseJSON = String(reason[prefix.upperBound..<suffix.lowerBound])
        let response = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(responseJSON.utf8)
        )
        XCTAssertEqual(
            response["answers"]?["deployment_target"]?["answers"]?
                .arrayValue?.first?.stringValue,
            selectedLabel
        )
    }

    func testRequestUserInputFreeTextReturnsModelVisibleDeny() throws {
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            Data(#"{"selected_indices":[],"selected_labels":[],"free_text":"deploy to staging please"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(output["hookSpecificOutput"]?.objectValue)
        XCTAssertEqual(inner["permissionDecision"]?.stringValue, "deny")
        let reason = try XCTUnwrap(inner["permissionDecisionReason"]?.stringValue)
        XCTAssertTrue(
            reason.contains(
                #"{"answers":{"deployment_target":{"answers":["deploy to staging please"]}}}"#
            )
        )
        XCTAssertTrue(reason.contains("Treat this request_user_input call as successful"))
        XCTAssertTrue(reason.contains("Do not re-ask this question"))
    }

    func testRequestUserInputLabelsPreferredOverFreeText() throws {
        // When both labels and free_text are present, labels win.
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            Data(#"{"selected_indices":[1],"selected_labels":["Production"],"free_text":"staging"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let reason = try XCTUnwrap(
            output["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue
        )
        XCTAssertTrue(reason.contains("Production"), "labels must be preferred")
        XCTAssertFalse(reason.contains(#""staging""#))
    }

    func testRequestUserInputEmptyFreeTextPassesThrough() {
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            Data(#"{"selected_indices":[],"selected_labels":[],"free_text":"   "}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testRequestUserInputMissingFreeTextPassesThrough() {
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            Data(#"{"selected_indices":[],"selected_labels":[]}"#.utf8)
        }
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testRequestUserInputFreeTextEscapesSpecialCharacters() throws {
        let freeText = #"deploy to "blue" env\nplease"#
        let brokerReply = try JSONEncoder().encode([
            "selected_indices": JSONValue.array([]),
            "selected_labels": JSONValue.array([]),
            "free_text": JSONValue.string(freeText),
        ])
        let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            brokerReply
        }

        let output = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let reason = try XCTUnwrap(
            output["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue
        )
        let prefix = try XCTUnwrap(reason.range(of: "response JSON: "))
        let suffix = try XCTUnwrap(
            reason.range(
                of: ". Do not re-ask",
                range: prefix.upperBound..<reason.endIndex
            )
        )
        let responseJSON = String(reason[prefix.upperBound..<suffix.lowerBound])
        let response = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(responseJSON.utf8)
        )
        XCTAssertEqual(
            response["answers"]?["deployment_target"]?["answers"]?
                .arrayValue?.first?.stringValue,
            freeText
        )
    }

    func testRequestUserInputRequiresNonblankToolUseID() {
        for toolUseID in [nil, "   "] as [String?] {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: requestUserInput(toolUseID: toolUseID)
            ) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testRequestUserInputWithAutoResolutionPassesThrough() {
        for milliseconds in [60_000, 240_000] {
            var object = requestUserInputObject()
            var toolInput = object["tool_input"]?.objectValue ?? [:]
            toolInput["autoResolutionMs"] = .number(Double(milliseconds))
            object["tool_input"] = .object(toolInput)

            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testRequestUserInputFromSubagentPassesThrough() {
        for field in ["agent_id", "agent_type"] {
            var object = requestUserInputObject()
            object[field] = .string(field == "agent_id" ? "agent-1" : "worker")

            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testSecretRequestUserInputPassesThroughWithoutReachingTapQ() {
        var question = requestUserQuestion().objectValue ?? [:]
        question["isSecret"] = .bool(true)

        var called = false
        let result = CodexHookShim.handle(
            stdinData: requestUserInput(questions: [.object(question)])
        ) { _, _ in
            called = true
            return Data()
        }

        XCTAssertFalse(called)
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testRequestUserInputMalformedAndMultipleQuestionsFailThrough() {
        let validQuestion = requestUserQuestion()
        let validOptions = [
            requestUserOption(label: "One", description: "First option."),
            requestUserOption(label: "Two", description: "Second option."),
        ]
        let malformedOption: JSONValue = .object([
            "label": .string("Missing description"),
        ])
        let duplicateOptions = [
            requestUserOption(label: "Same", description: "First duplicate."),
            requestUserOption(label: "Same", description: "Second duplicate."),
        ]
        let blankLabelOptions = [
            requestUserOption(label: "   ", description: "Blank label."),
            validOptions[1],
        ]
        let fourOptions = validOptions + [
            requestUserOption(label: "Three", description: "Third option."),
            requestUserOption(label: "Four", description: "Fourth option."),
        ]

        var invalid = [
            requestUserInputObject(questions: []),
            requestUserInputObject(questions: [validQuestion, validQuestion]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: []),
            ]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: [validOptions[0]]),
            ]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: fourOptions),
            ]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: [malformedOption, validOptions[1]]),
            ]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: duplicateOptions),
            ]),
            requestUserInputObject(questions: [
                requestUserQuestion(options: blankLabelOptions),
            ]),
        ]
        var missingSession = requestUserInputObject()
        missingSession.removeValue(forKey: "session_id")
        invalid.append(missingSession)
        var otherTool = requestUserInputObject()
        otherTool["tool_name"] = .string("exec")
        invalid.append(otherTool)

        for object in invalid {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testRequestUserInputUnansweredAndInvalidRepliesFailThrough() {
        for reply in [
            #"{"error":"timeout"}"#,
            #"{"selected_indices":[],"selected_labels":[]}"#,
            #"{"selected_labels":["Staging"]}"#,
            #"{"selected_indices":[0]}"#,
            #"{"selected_indices":[0,1],"selected_labels":["Staging","Production"]}"#,
            #"{"selected_indices":[0],"selected_labels":["Staging","Production"]}"#,
            #"{"selected_indices":[2],"selected_labels":["Production"]}"#,
            #"{"selected_indices":[0.5],"selected_labels":["Staging"]}"#,
            #"{"selected_indices":[1],"selected_labels":["Staging"]}"#,
            #"{"selected_indices":[0],"selected_labels":["Unknown"]}"#,
            #"not json"#,
        ] {
            let result = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
                Data(reply.utf8)
            }
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }

        let unavailable = CodexHookShim.handle(stdinData: requestUserInput()) { _, _ in
            throw StubError.unreachable
        }
        XCTAssertEqual(unavailable, CodexHookShim.passThrough)
    }

    // MARK: - PermissionRequest

    func testPermissionRequestAllowUsesExactCodexShapeAndNormalizedWireMessage() throws {
        let stdin = permissionInput(toolInput: .object([
            "command": .string("swift test"),
            "description": .string("Run the test suite"),
        ]))
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?

        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try permissionOutput(result.stdout)
        XCTAssertEqual(output.event, "PermissionRequest")
        XCTAssertEqual(output.behavior, "allow")
        XCTAssertNil(output.message)

        let encodedOutput = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(encodedOutput["hookSpecificOutput"]?.objectValue)
        let decision = try XCTUnwrap(inner["decision"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), ["hookEventName", "decision"])
        XCTAssertEqual(Set(decision.keys), ["behavior"])

        XCTAssertEqual(captured?["type"]?.stringValue, WireType.approval)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "codex")
        XCTAssertEqual(captured?["agent"]?["display_name"]?.stringValue, "Codex")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "session-1")
        XCTAssertEqual(captured?["cwd"]?.stringValue, "/tmp/project")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Bash")
        XCTAssertEqual(captured?["tool_input"]?["command"]?.stringValue, "swift test")
        XCTAssertEqual(captured?["permission_mode"]?.stringValue, "default")
        XCTAssertEqual(
            captured?["approval_source"]?.stringValue,
            ApprovalSource.permissionRequest.rawValue
        )
        XCTAssertEqual(captured?["summary"]?.stringValue, "run swift test")
        XCTAssertEqual(captured?["detail"]?.stringValue, "Run the test suite")
        XCTAssertFalse(captured?["request_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version)
        XCTAssertEqual(capturedTimeout, CodexHookShim.approvalTimeout)

        var authenticated = try XCTUnwrap(captured)
        authenticated["token"] = .string("token")
        let request = try BrokerRequest(from: JSONEncoder().encode(authenticated))
        guard case .approval(let approval) = request else {
            return XCTFail("expected approval request")
        }
        XCTAssertEqual(approval.agent, AgentIdentity(id: "codex", displayName: "Codex"))
        XCTAssertEqual(approval.approvalSource, .permissionRequest)
    }

    func testMCPPermissionRequestForwardsCanonicalPayloadWithSecretSafePresentation() throws {
        let toolInput: JSONValue = .object([
            "path": .string("/Users/example/private/customer-record.txt"),
            "token": .string("tapq-secret-token"),
            "nested": .object([
                "authorization": .string("Bearer tapq-secret-authorization"),
                "content": .string("tapq-secret-content"),
            ]),
        ])
        var captured: [String: JSONValue]?

        let result = CodexHookShim.handle(
            stdinData: permissionInput(
                toolName: "mcp__filesystem__read_file",
                toolInput: toolInput
            )
        ) { message, _ in
            captured = message
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(try permissionOutput(result.stdout).behavior, "allow")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "mcp__filesystem__read_file")
        XCTAssertEqual(captured?["tool_input"], toolInput)
        XCTAssertEqual(
            captured?["approval_source"]?.stringValue,
            ApprovalSource.permissionRequest.rawValue
        )

        let summary = try XCTUnwrap(captured?["summary"]?.stringValue)
        let detail = try XCTUnwrap(captured?["detail"]?.stringValue)
        for presentation in [summary, detail] {
            XCTAssertTrue(presentation.localizedCaseInsensitiveContains("filesystem"))
            XCTAssertTrue(presentation.localizedCaseInsensitiveContains("read file"))
            XCTAssertFalse(presentation.contains("mcp__"))
            XCTAssertFalse(presentation.contains("\n"))
            for secret in [
                "/Users/example/private/customer-record.txt",
                "tapq-secret-token",
                "tapq-secret-authorization",
                "tapq-secret-content",
            ] {
                XCTAssertFalse(presentation.contains(secret))
            }
        }
        XCTAssertLessThanOrEqual(summary.count, 64)
    }

    func testMCPPermissionRequestDenyAndDeferralPreserveNativeSemantics() throws {
        let stdin = permissionInput(
            toolName: "mcp__github__create_issue",
            toolInput: .object([
                "owner": .string("example"),
                "title": .string("Test issue"),
            ])
        )

        let denied = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"deny","reason":"Connector call declined"}"#.utf8)
        }
        XCTAssertEqual(try permissionOutput(denied.stdout).behavior, "deny")
        XCTAssertEqual(
            try permissionOutput(denied.stdout).message,
            "Connector call declined"
        )

        let deferred = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"ask"}"#.utf8)
        }
        XCTAssertEqual(deferred, CodexHookShim.passThrough)

        let unavailable = CodexHookShim.handle(stdinData: stdin) { _, _ in
            throw StubError.unreachable
        }
        XCTAssertEqual(unavailable, CodexHookShim.passThrough)
    }

    func testPermissionRequestDenyUsesBrokerReason() throws {
        let stdin = permissionInput(
            toolName: "apply_patch",
            toolInput: .object(["command": .string("*** Begin Patch")])
        )
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"deny","reason":"Protected path"}"#.utf8)
        }

        let output = try permissionOutput(result.stdout)
        XCTAssertEqual(output.behavior, "deny")
        XCTAssertEqual(output.message, "Protected path")
    }

    func testPermissionRequestDenyReasonIsJSONEscaped() throws {
        let reason = "Blocked \"release\" path\\name\nUse staging instead."
        let brokerReply = try JSONEncoder().encode([
            "decision": JSONValue.string("deny"),
            "reason": .string(reason),
        ])
        let result = CodexHookShim.handle(stdinData: permissionInput()) { _, _ in
            brokerReply
        }

        XCTAssertEqual(try permissionOutput(result.stdout).message, reason)
    }

    func testPermissionRequestDenyFallsBackToTapQReason() throws {
        let stdin = permissionInput(toolInput: .object(["command": .string("rm file")]))
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"deny","reason":"  "}"#.utf8)
        }

        XCTAssertEqual(try permissionOutput(result.stdout).message, "Denied via TapQ")
    }

    func testPermissionRequestDeclinesToDecideForAskAndBrokerErrors() {
        let stdin = permissionInput(toolInput: .object(["command": .string("make")]))
        for reply in [
            #"{"decision":"ask"}"#,
            #"{"error":"timeout"}"#,
            #"{"error":"unauthorized","decision":"allow"}"#,
        ] {
            let result = CodexHookShim.handle(stdinData: stdin) { _, _ in Data(reply.utf8) }
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testPermissionRequestAcceptsAllCurrentPermissionModesOnly() throws {
        for mode in ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"] {
            var object = permissionObject()
            object["permission_mode"] = .string(mode)
            var capturedMode: String?
            let result = CodexHookShim.handle(
                stdinData: try JSONEncoder().encode(object)
            ) { message, _ in
                capturedMode = message["permission_mode"]?.stringValue
                return Data(#"{"decision":"allow"}"#.utf8)
            }

            XCTAssertEqual(try permissionOutput(result.stdout).behavior, "allow")
            XCTAssertEqual(capturedMode, mode)
        }

        var future = permissionObject()
        future["permission_mode"] = .string("futureMode")
        var called = false
        let result = CodexHookShim.handle(
            stdinData: try JSONEncoder().encode(future)
        ) { _, _ in
            called = true
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        XCTAssertFalse(called)
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testPermissionRequestFailsOpenWhenBrokerUnavailableOrReplyIsMalformed() {
        let stdin = permissionInput(toolInput: .object(["command": .string("make")]))

        let unavailable = CodexHookShim.handle(stdinData: stdin) { _, _ in
            throw StubError.unreachable
        }
        XCTAssertEqual(unavailable, CodexHookShim.passThrough)

        let malformed = CodexHookShim.handle(stdinData: stdin) { _, _ in Data("not json".utf8) }
        XCTAssertEqual(malformed, CodexHookShim.passThrough)
    }

    func testInvalidPermissionRequestDoesNotReachBroker() {
        var invalidObjects: [[String: JSONValue]] = []
        for key in [
            "session_id", "turn_id", "transcript_path", "cwd", "model",
            "permission_mode", "tool_name", "tool_input",
        ] {
            var missing = permissionObject()
            missing.removeValue(forKey: key)
            invalidObjects.append(missing)
        }
        var wrongTranscriptType = permissionObject()
        wrongTranscriptType["transcript_path"] = .bool(false)
        invalidObjects.append(wrongTranscriptType)
        var wrongModelType = permissionObject()
        wrongModelType["model"] = .number(5)
        invalidObjects.append(wrongModelType)
        var emptySession = permissionObject()
        emptySession["session_id"] = .string("  ")
        invalidObjects.append(emptySession)
        var nonObjectInput = permissionObject()
        nonObjectInput["tool_input"] = .string("command")
        invalidObjects.append(nonObjectInput)

        for object in invalidObjects {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data(#"{"decision":"allow"}"#.utf8)
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    // MARK: - Stop

    func testStopAnswerUsesLastAssistantMessageAndEmitsTopLevelContinuation() throws {
        let stdin = stopInput(message: .string("Deploy to staging or production?"))
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            sentTypes.append(message["type"]?.stringValue ?? "")
            XCTAssertEqual(message["agent"]?["id"]?.stringValue, "codex")
            XCTAssertEqual(message["session_id"]?.stringValue, "session-1")
            XCTAssertEqual(message["request_id"]?.stringValue, "turn-1")
            XCTAssertEqual(message["text"]?.stringValue, "Deploy to staging or production?")
            XCTAssertEqual(timeout, CodexHookShim.approvalTimeout)
            return Data(#"{"action":"answer","reply":"The user chose staging."}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        XCTAssertEqual(object["decision"]?.stringValue, "block")
        XCTAssertEqual(object["reason"]?.stringValue, "The user chose staging.")
        XCTAssertNil(object["hookSpecificOutput"])
        XCTAssertEqual(sentTypes, [WireType.stopQuestion])
    }

    func testStopPassSendsCompletionNotification() {
        let stdin = stopInput(message: .string("Which target?"))
        var sentTypes: [String] = []
        var notificationEvent: String?
        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.stopQuestion {
                return Data(#"{"action":"pass"}"#.utf8)
            }
            notificationEvent = message["event"]?.stringValue
            XCTAssertEqual(message["agent"]?["display_name"]?.stringValue, "Codex")
            XCTAssertEqual(timeout, CodexHookShim.notifyTimeout)
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion, WireType.notification])
        XCTAssertEqual(notificationEvent, "stop")
    }

    func testActiveStopSkipsQuestionInterceptionButStillNotifies() {
        let stdin = stopInput(message: .string("Ask again?"), active: true)
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    /// A statement is forwarded exactly as a question is: the runtime decides what the
    /// boundary says, and a reply kept inside the hook is a reply the wearer never hears.
    func testStopWithoutQuestionIsForwardedThenNotifies() {
        let stdin = stopInput(message: .string("All tests pass."))
        var sentTypes: [String] = []
        var forwarded: String?
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.stopQuestion {
                forwarded = message["text"]?.stringValue
                return Data(#"{"action":"pass"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion, WireType.notification])
        XCTAssertEqual(forwarded, "All tests pass.")
    }

    func testStopWithNullAssistantMessageOnlyNotifies() {
        let stdin = stopInput(message: .null)
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    func testStopQuestionBrokerFailureFailsOpenWithoutSecondSend() {
        let stdin = stopInput()
        var sends = 0
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            sends += 1
            throw StubError.unreachable
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sends, 1)
    }

    func testMalformedStopReplyFailsOpenAndStillNotifies() {
        let stdin = stopInput()
        var sends = 0
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sends += 1
            if message["type"]?.stringValue == WireType.stopQuestion {
                return Data("not json".utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sends, 2)
    }

    func testEmptyStopAnswerFailsOpenAndStillNotifies() {
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stopInput()) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.stopQuestion {
                return Data(#"{"action":"answer","reply":"   "}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion, WireType.notification])
    }

    func testStopQuestionTextIsTailCapped() {
        let long = String(repeating: "a", count: 20_000) + " Continue?"
        let stdin = stopInput(message: .string(long))
        var sentText: String?

        _ = CodexHookShim.handle(stdinData: stdin) { message, _ in
            if message["type"]?.stringValue == WireType.stopQuestion {
                sentText = message["text"]?.stringValue
                return Data(#"{"action":"pass"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(sentText?.count, CodexHookShim.maxStopQuestionCharacters)
        XCTAssertTrue(sentText?.hasSuffix("Continue?") ?? false)
    }

    func testInvalidStopInputDoesNotReachBroker() {
        var invalidObjects: [[String: JSONValue]] = []
        for key in [
            "session_id", "turn_id", "transcript_path", "cwd", "model",
            "permission_mode", "stop_hook_active", "last_assistant_message",
        ] {
            var missing = stopObject()
            missing.removeValue(forKey: key)
            invalidObjects.append(missing)
        }
        var wrongActiveType = stopObject()
        wrongActiveType["stop_hook_active"] = .string("false")
        invalidObjects.append(wrongActiveType)
        var emptyTurn = stopObject()
        emptyTurn["turn_id"] = .string("")
        invalidObjects.append(emptyTurn)
        var unknownMode = stopObject()
        unknownMode["permission_mode"] = .string("futureMode")
        invalidObjects.append(unknownMode)
        var wrongMessageType = stopObject()
        wrongMessageType["last_assistant_message"] = .array([])
        invalidObjects.append(wrongMessageType)

        for object in invalidObjects {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data(#"{"ok":true}"#.utf8)
            }

            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    // MARK: - Generic fail-open behavior

    func testUnknownEventAndMalformedStdinDoNothing() {
        for stdin in [input(#"{"hook_event_name":"PostToolUse"}"#), input("not json")] {
            var called = false
            let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }
}
