import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The loop's turn, over the wire: the third method on the narration client.
///
/// Two things are being defended. The request shape — Responses API function tools, the same
/// endpoint, key, and timeout race as narration and `ask_about_work` — because "one client
/// family" is what keeps the failure posture from diverging. And the decode, because a turn
/// that came back as prose, as a refusal, or as two calls at once is the tool protocol being
/// wrong, and this path answers that the way every other one does: loudly, so the run's voice
/// breaks rather than continuing with a loop inventing actions.
final class OpenAITaskTurnTests: XCTestCase {
    private static let request = WearerTaskTurnRequest(
        goal: "check whether the tests passed",
        mode: .task,
        steps: [],
        stepsRemaining: 6
    )

    // MARK: - Wire shape

    func testATurnSendsFunctionToolsOnTheNarrationEndpoint() async throws {
        let model = makeModel { request in
            XCTAssertEqual(request.url, OpenAINarrationModel.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key"
            )

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, OpenAINarrationModel.defaultModel)
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(json["tool_choice"] as? String, "required")
            let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "none")
            // Tools, not a strict text schema: a turn produces a choice among tools.
            XCTAssertNil(json["text"])
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
                "search_memory", "read_transcript", "get_status", "queue_instruction",
                "speak", "ask_wearer", "finish", "cannot_do", "set_followup",
            ])
            let input = try XCTUnwrap(json["input"] as? String)
            XCTAssertTrue(input.contains("check whether the tests passed"), input)

            return try self.functionCall(
                name: "read_transcript", arguments: #"{"query":"tests"}"#
            )
        }

        let decision = try await model.decide(Self.request)
        XCTAssertEqual(decision, .readTranscript(agent: nil, query: "tests"))
    }

    func testTheQuestionLaneSendsOnlyItsThreeTools() async throws {
        let model = makeModel { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                           ["search_memory", "read_transcript", "finish"])
            return try self.functionCall(
                name: "finish", arguments: #"{"summary":"All green."}"#
            )
        }

        let decision = try await model.decide(WearerTaskTurnRequest(
            goal: "what did the tests say?",
            mode: .question,
            agentDisplayName: "Claude Code",
            steps: [],
            stepsRemaining: 3
        ))
        XCTAssertEqual(decision, .finish(summary: "All green."))
    }

    // MARK: - Decode failures

    func testATurnThatCameBackAsProseIsAProtocolFailure() async throws {
        let model = makeModel { _ in try self.textResponse("I would read the transcript.") }
        await assertThrows(model, containing: "no tool call")
    }

    func testATurnCarryingTwoToolCallsIsAProtocolFailure() async throws {
        // Taking the first and dropping the second would silently discard an action the
        // model believed it had taken.
        let model = makeModel { _ in
            try self.response(output: [
                self.callItem(name: "get_status", arguments: "{}"),
                self.callItem(name: "finish", arguments: #"{"summary":"done"}"#),
            ])
        }
        await assertThrows(model, containing: "2 tool calls")
    }

    func testARefusalIsAProtocolFailure() async throws {
        let model = makeModel { _ in
            try self.response(output: [[
                "type": "message",
                "content": [["type": "refusal", "text": "no"]],
            ]])
        }
        await assertThrows(model, containing: "malformed")
    }

    func testAnIncompleteResponseIsAProtocolFailure() async throws {
        let model = makeModel { _ in
            let body: [String: Any] = [
                "status": "incomplete",
                "error": NSNull(),
                "incomplete_details": ["reason": "max_output_tokens"],
                "output": [],
            ]
            return (
                try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(
                    url: OpenAINarrationModel.defaultEndpoint,
                    statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
        await assertThrows(model, containing: "malformed")
    }

    func testAnHTTPErrorThrowsTheSameFailureNarrationThrows() async throws {
        let model = makeModel { _ in
            (
                Data(),
                HTTPURLResponse(
                    url: OpenAINarrationModel.defaultEndpoint,
                    statusCode: 503, httpVersion: nil, headerFields: nil
                )!
            )
        }
        do {
            _ = try await model.decide(Self.request)
            XCTFail("expected a thrown failure")
        } catch let failure as NarrationFailure {
            XCTAssertEqual(failure, .http(status: 503))
        }
    }

    func testATurnNamingATheUndeclaredToolIsAProtocolFailure() async throws {
        let model = makeModel { _ in
            try self.functionCall(name: "approve", arguments: "{}")
        }
        await assertThrows(model, containing: "undeclared")
    }

    // MARK: - Helpers

    private func assertThrows(
        _ model: OpenAINarrationModel,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await model.decide(Self.request)
            XCTFail("expected a thrown failure", file: file, line: line)
        } catch let failure as NarrationFailure {
            XCTAssertTrue(failure.reason.contains(fragment),
                          failure.reason, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func makeModel(
        send: @escaping OpenAINarrationModel.HTTPSender
    ) -> OpenAINarrationModel {
        OpenAINarrationModel(
            apiKey: "test-key",
            model: OpenAINarrationModel.defaultModel,
            endpoint: OpenAINarrationModel.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: send
        )
    }

    private func callItem(name: String, arguments: String) -> [String: Any] {
        [
            "type": "function_call",
            "call_id": "call_1",
            "name": name,
            "arguments": arguments,
        ]
    }

    private func functionCall(
        name: String, arguments: String
    ) throws -> (Data, HTTPURLResponse) {
        try response(output: [callItem(name: name, arguments: arguments)])
    }

    private func textResponse(_ text: String) throws -> (Data, HTTPURLResponse) {
        try response(output: [[
            "type": "message",
            "content": [["type": "output_text", "text": text]],
        ]])
    }

    private func response(output: [[String: Any]]) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = [
            "status": "completed",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "output": output,
        ]
        return (
            try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(
                url: OpenAINarrationModel.defaultEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}
