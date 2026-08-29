import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The narration client's wire shape, its four delivery modes, and its failure posture.
///
/// Every failure here is asserted as a *thrown* ``NarrationFailure`` rather than a `nil`,
/// which is the difference between this and the summarizer it replaced: there is no local
/// heuristic behind it to fail open to, so "cannot answer" has to be loud enough for the
/// coordinator to break the run's voice pipe.
final class OpenAINarrationModelTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private static let request = NarrationRequest(
        agentDisplayName: "Claude Code",
        items: [NarrationItem(
            kind: .agentMessage,
            text: "I rewrote Sources/TapQAppleAdapters/MicrophonePumpVoiceBackend.swift."
        )]
    )

    // MARK: - Wire shape

    func testNarrationUsesResponsesAPIAndStrictSchema() async throws {
        let narrator = makeNarrator { request in
            XCTAssertEqual(request.url, OpenAINarrationModel.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-key"
            )

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, OpenAINarrationModel.defaultModel)
            XCTAssertEqual(json["max_output_tokens"] as? Int, 512)
            XCTAssertEqual(json["store"] as? Bool, false)
            let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "none")

            let instructions = try XCTUnwrap(json["instructions"] as? String)
            for mode in NarrationDeliveryMode.allCases {
                XCTAssertTrue(
                    instructions.contains("\"\(mode.rawValue)\""),
                    "the guidance prompt must name the \(mode.rawValue) mode"
                )
            }

            let text = try XCTUnwrap(json["text"] as? [String: Any])
            let format = try XCTUnwrap(text["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["name"] as? String, NarrationContract.schemaName)
            XCTAssertEqual(format["strict"] as? Bool, true)
            let schema = try XCTUnwrap(format["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties["utterance"])
            XCTAssertNotNil(properties["mode"])

            return try self.httpResponse(
                utterance: "It rewrote the microphone pump.",
                mode: "summary"
            )
        }

        let result = try await narrator.narrate(Self.request)
        XCTAssertEqual(result.text, "It rewrote the microphone pump.")
        XCTAssertEqual(result.mode, .summary)
        XCTAssertFalse(result.isQuestion)
    }

    // MARK: - Redaction

    /// The narration model may only see speech-eligible surfaces. The type system already
    /// makes that true — a `NarrationItem` has nowhere to hold a tool input — and this
    /// asserts the *serialization* keeps the promise: nothing but the agent's display name
    /// and the items' own text reaches the wire.
    func testRequestBodyCarriesOnlySpeechEligibleSurfaces() async throws {
        let excluded = [
            "rm -rf /tmp/build", // a toolInput
            "/Users/wearer/secret-project", // a cwd
            "acceptEdits", // a permissionMode
            "sess-4f19ac", // a session identifier
        ]
        let narrator = makeNarrator { request in
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            for field in excluded {
                XCTAssertFalse(
                    body.contains(field),
                    "the narration request must never carry \(field)"
                )
            }
            XCTAssertTrue(body.contains("Claude Code"))
            XCTAssertTrue(body.contains("the migration finished"))
            return try self.httpResponse(utterance: "The migration finished.", mode: "verbatim")
        }

        _ = try await narrator.narrate(NarrationRequest(
            agentDisplayName: "Claude Code",
            items: [NarrationItem(kind: .agentMessage, text: "the migration finished")]
        ))
    }

    func testInputRendersEveryPendingItemInOrderAndNothingElse() {
        let rendered = NarrationContract.input(for: NarrationRequest(
            agentDisplayName: "Codex",
            items: [
                NarrationItem(kind: .agentMessage, text: "Tests are green."),
                NarrationItem(kind: .notice, text: "That's three instructions in a row."),
            ]
        ))
        XCTAssertEqual(rendered, """
            Agent: Codex
            Pending items (2), oldest first:
            1. [agent_message] Tests are green.
            2. [notice] That's three instructions in a row.
            """)
    }

    // MARK: - Delivery modes

    func testEveryDeliveryModeDecodes() async throws {
        for mode in NarrationDeliveryMode.allCases {
            let narrator = makeNarrator { _ in
                try self.httpResponse(utterance: "Utterance for \(mode.rawValue).",
                                      mode: mode.rawValue)
            }
            let result = try await narrator.narrate(Self.request)
            XCTAssertEqual(result.mode, mode)
            XCTAssertEqual(result.text, "Utterance for \(mode.rawValue).")
            XCTAssertEqual(result.isQuestion, mode == .question)
        }
    }

    /// The one thing narration must never do to its own output: shorten it. The removed
    /// heuristics capped a spoken detail at 320 characters; the model was asked to decide
    /// the length and its answer is spoken as written.
    func testLongUtteranceIsSpokenWholeAndOnlyWhitespaceIsNormalized() async throws {
        let long = Array(repeating: "beta", count: 300).joined(separator: " ")
        let narrator = makeNarrator { _ in
            try self.httpResponse(utterance: "Line one.\n\n  " + long, mode: "verbatim")
        }
        let result = try await narrator.narrate(Self.request)
        XCTAssertEqual(result.text, "Line one. " + long)
        XCTAssertGreaterThan(result.text.count, SpokenSummary.detailCharacterLimit)
    }

    /// A path or a command in the pending text has to survive the round trip byte for byte,
    /// because a wearer who cannot see a screen has only this to go on.
    func testTechnicalTokensSurviveDecodingUntouched() async throws {
        let utterance = "It changed Sources/TapQCLI/CLICommand.swift and ran "
            + "swift test --filter InstructionQueueTests, 3 of 141 failing."
        let narrator = makeNarrator { _ in
            try self.httpResponse(utterance: utterance, mode: "verbatim")
        }
        let result = try await narrator.narrate(Self.request)
        XCTAssertEqual(result.text, utterance)
    }

    // MARK: - Failure posture

    func testHTTPErrorThrowsWithTheStatus() async throws {
        let narrator = makeNarrator { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        await assertNarrationFails(narrator, is: .http(status: 429))
    }

    func testTimeoutThrows() async {
        let narrator = OpenAINarrationModel(
            apiKey: "test-key",
            model: OpenAINarrationModel.defaultModel,
            endpoint: OpenAINarrationModel.defaultEndpoint,
            timeout: 0.01,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: { request in
                try await Task.sleep(for: .seconds(1))
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(), response)
            }
        )
        await assertNarrationFails(narrator, is: .timedOut)
    }

    func testTransportFailureThrows() async {
        let narrator = OpenAINarrationModel(
            apiKey: "test-key",
            model: OpenAINarrationModel.defaultModel,
            endpoint: OpenAINarrationModel.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: { _ in throw URLError(.notConnectedToInternet) }
        )
        await assertNarrationFails(narrator, is: .transport("send failed"))
    }

    func testEmptyUtteranceThrowsRatherThanSpeakingSilence() async throws {
        let narrator = makeNarrator { _ in
            try self.httpResponse(utterance: "   \n\t ", mode: "verbatim")
        }
        await assertNarrationFails(narrator, is: .emptyOutput)
    }

    func testMalformedAndRefusedResponsesThrow() async throws {
        let bodies = [
            #"{"status":"failed","error":{"code":"server_error"},"incomplete_details":null,"output":[]}"#,
            #"{"status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[{"content":[{"type":"refusal"}]}]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[]}"#,
            #"{"not":"a response"}"#,
        ]
        for body in bodies {
            let narrator = makeNarrator { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
            await assertNarrationFails(narrator, is: .malformedResponse, body)
        }
    }

    /// A mode the enum does not know is a protocol mismatch, not something to guess at.
    func testUnknownDeliveryModeThrows() async throws {
        let narrator = makeNarrator { _ in
            try self.httpResponse(utterance: "Something happened.", mode: "improvise")
        }
        await assertNarrationFails(narrator, is: .malformedResponse)
    }

    // MARK: - Model selection

    func testModelDefaultsToLunaAndReadsTheEnvironmentOverride() {
        XCTAssertEqual(OpenAINarrationModel.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(OpenAINarrationModel.environmentKey, "TAPQ_NARRATION_MODEL")
        XCTAssertEqual(OpenAINarrationModel.resolvedModel(environment: [:]), "gpt-5.6-luna")
        XCTAssertEqual(
            OpenAINarrationModel.resolvedModel(environment: ["TAPQ_NARRATION_MODEL": "  "]),
            "gpt-5.6-luna",
            "a blank override is not an override"
        )
        XCTAssertEqual(
            OpenAINarrationModel.resolvedModel(
                environment: ["TAPQ_NARRATION_MODEL": " gpt-5.6-nano "]
            ),
            "gpt-5.6-nano"
        )
    }

    func testOverriddenModelIsWhatGoesOnTheWire() async throws {
        let narrator = OpenAINarrationModel(
            apiKey: "test-key",
            model: "gpt-5.6-nano",
            endpoint: OpenAINarrationModel.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: { request in
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(json["model"] as? String, "gpt-5.6-nano")
                return try self.httpResponse(utterance: "Done.", mode: "verbatim")
            }
        )
        _ = try await narrator.narrate(Self.request)
    }

    // MARK: - Helpers

    private func assertNarrationFails(
        _ narrator: OpenAINarrationModel,
        is expected: NarrationFailure,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let utterance = try await narrator.narrate(Self.request)
            XCTFail("expected \(expected), got '\(utterance.text)' \(message)",
                    file: file, line: line)
        } catch let failure as NarrationFailure {
            XCTAssertEqual(failure, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected NarrationFailure, got \(error) \(message)",
                    file: file, line: line)
        }
    }

    private func makeNarrator(
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

    private func httpResponse(
        utterance: String,
        mode: String
    ) throws -> (Data, HTTPURLResponse) {
        let extractionData = try JSONSerialization.data(
            withJSONObject: ["utterance": utterance, "mode": mode]
        )
        let body: [String: Any] = [
            "status": "completed",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "output": [[
                "type": "message",
                "status": "completed",
                "content": [[
                    "type": "output_text",
                    "text": String(decoding: extractionData, as: UTF8.self),
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: OpenAINarrationModel.defaultEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
