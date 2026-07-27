import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAILunaQuestionClassifierTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testYesNoUsesResponsesAPIAndStrictSchema() async throws {
        let classifier = makeClassifier { request in
            XCTAssertEqual(request.url, OpenAILunaQuestionClassifier.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-key"
            )

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, OpenAILunaQuestionClassifier.defaultModel)
            XCTAssertEqual(json["max_output_tokens"] as? Int, 256)
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertTrue((json["instructions"] as? String)?.contains("yes_no") == true)
            XCTAssertTrue((json["input"] as? String)?.contains("rollback plan") == true)

            let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "none")
            let text = try XCTUnwrap(json["text"] as? [String: Any])
            let format = try XCTUnwrap(text["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["name"] as? String, "tapq_question_classification")
            XCTAssertEqual(format["strict"] as? Bool, true)
            XCTAssertNotNil(format["schema"] as? [String: Any])

            return try self.httpResponse(extraction: [
                "kind": "yes_no",
                "question": "Prepare the rollback plan?",
                "options": [],
            ])
        }

        let result = await classifier.classify(
            "Before continuing, should I also prepare the rollback plan?"
        )
        XCTAssertEqual(result, .yesNo(question: "Prepare the rollback plan?"))
    }

    func testMultiOptionTrimsAndCapsOptions() async throws {
        let options: [[String: String]] = (1...7).map {
            ["label": " Option \($0) ", "description": " Description \($0) "]
        }
        let classifier = makeClassifier { _ in
            try self.httpResponse(extraction: [
                "kind": "multi_option",
                "question": " Where should deployment go? ",
                "options": options,
            ])
        }

        let result = await classifier.classify(
            "Should deployment target staging, production, or wait?"
        )
        guard case .multiOption(let question, let decoded)? = result else {
            return XCTFail("expected multiOption")
        }
        XCTAssertEqual(question, "Where should deployment go?")
        XCTAssertEqual(decoded.count, 6)
        XCTAssertEqual(decoded.first?.label, "Option 1")
        XCTAssertEqual(decoded.first?.description, "Description 1")
    }

    func testNoQuestionIsAuthoritative() async throws {
        let classifier = makeClassifier { _ in
            try self.httpResponse(extraction: [
                "kind": "none",
                "question": "",
                "options": [],
            ])
        }
        let result = await classifier.classify("This is complete, understood?")
        XCTAssertEqual(result, .noQuestion)
    }

    func testHTTPErrorAndInvalidResponsesReturnNil() async throws {
        let rejected = makeClassifier { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        let rejectedResult = await rejected.classify("Should I continue?")
        XCTAssertNil(rejectedResult)

        for body in [
            #"{"status":"failed","error":{"code":"server_error"},"incomplete_details":null,"output":[]}"#,
            #"{"status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[{"content":[{"type":"refusal"}]}]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[]}"#,
            #"{"not":"a response"}"#,
        ] {
            let classifier = makeClassifier { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
            let result = await classifier.classify("Should I continue?")
            XCTAssertNil(result, body)
        }
    }

    func testTimeoutReturnsNil() async {
        let classifier = OpenAILunaQuestionClassifier(
            apiKey: "test-key",
            model: OpenAILunaQuestionClassifier.defaultModel,
            endpoint: OpenAILunaQuestionClassifier.defaultEndpoint,
            timeout: 0.01,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: { request in
                try await Task.sleep(for: .seconds(1))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )
        let result = await classifier.classify("Should I continue?")
        XCTAssertNil(result)
    }

    func testTextWithoutQuestionMarkSkipsNetwork() async {
        let counter = Counter()
        let classifier = OpenAILunaQuestionClassifier(
            apiKey: "test-key",
            model: OpenAILunaQuestionClassifier.defaultModel,
            endpoint: OpenAILunaQuestionClassifier.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: { request in
                await counter.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )

        let result = await classifier.classify("Everything is complete.")
        let count = await counter.value
        XCTAssertNil(result)
        XCTAssertEqual(count, 0)
    }

    func testProviderFailureFallsBackToStructuredHeuristic() async throws {
        let primary = makeClassifier { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        let chain = QuestionClassifierChain(
            primary: primary,
            fallback: HeuristicQuestionClassifier()
        )

        let result = await chain.classify("Which target?\n1) Staging\n2) Production")
        guard case .multiOption(let question, let options)? = result else {
            return XCTFail("expected heuristic fallback")
        }
        XCTAssertEqual(question, "Which target?")
        XCTAssertEqual(options.map(\.label), ["Staging", "Production"])
    }

    private func makeClassifier(
        send: @escaping OpenAILunaQuestionClassifier.HTTPSender
    ) -> OpenAILunaQuestionClassifier {
        OpenAILunaQuestionClassifier(
            apiKey: "test-key",
            model: OpenAILunaQuestionClassifier.defaultModel,
            endpoint: OpenAILunaQuestionClassifier.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: send
        )
    }

    private func httpResponse(
        extraction: [String: Any]
    ) throws -> (Data, HTTPURLResponse) {
        let extractionData = try JSONSerialization.data(withJSONObject: extraction)
        let extractionText = String(decoding: extractionData, as: UTF8.self)
        let body: [String: Any] = [
            "status": "completed",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "output": [[
                "type": "message",
                "status": "completed",
                "content": [[
                    "type": "output_text",
                    "text": extractionText,
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: OpenAILunaQuestionClassifier.defaultEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
