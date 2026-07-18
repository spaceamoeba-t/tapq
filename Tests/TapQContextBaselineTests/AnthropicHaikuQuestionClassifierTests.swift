import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AnthropicHaikuQuestionClassifierTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testYesNoUsesMessagesAPIAndStrictSchema() async throws {
        let classifier = makeClassifier { request in
            XCTAssertEqual(request.url, AnthropicHaikuQuestionClassifier.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, AnthropicHaikuQuestionClassifier.defaultModel)
            let output = try XCTUnwrap(json["output_config"] as? [String: Any])
            let format = try XCTUnwrap(output["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")

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
            return XCTFail("expected multi-option classification")
        }
        XCTAssertEqual(question, "Where should deployment go?")
        XCTAssertEqual(decoded.count, 6)
        XCTAssertEqual(decoded.first, .init(label: "Option 1", description: "Description 1"))
        XCTAssertEqual(decoded.last, .init(label: "Option 6", description: "Description 6"))
    }

    func testNoQuestionIsAuthoritative() async throws {
        let classifier = makeClassifier { _ in
            try self.httpResponse(extraction: [
                "kind": "none",
                "question": "",
                "options": [],
            ])
        }
        let result = await classifier.classify("Tests passed—is anything else needed?")
        XCTAssertEqual(result, .noQuestion)
    }

    func testInvalidSemanticOutputReturnsNil() async throws {
        let classifier = makeClassifier { _ in
            try self.httpResponse(extraction: [
                "kind": "multi_option",
                "question": "Choose?",
                "options": [["label": "Only", "description": "one option"]],
            ])
        }
        let result = await classifier.classify("Which option should I use?")
        XCTAssertNil(result)
    }

    func testRefusalAndMaximumTokenResponsesReturnNil() async throws {
        for reason in ["refusal", "max_tokens"] {
            let classifier = makeClassifier { _ in
                try self.httpResponse(
                    extraction: ["kind": "yes_no", "question": "Continue?", "options": []],
                    stopReason: reason
                )
            }
            let result = await classifier.classify("Should I continue?")
            XCTAssertNil(result, "\(reason) must fail open")
        }
    }

    func testHTTPAndMalformedResponsesReturnNil() async throws {
        let rejected = makeClassifier { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"error":"rate limited"}"#.utf8), response)
        }
        let rejectedResult = await rejected.classify("Should I continue?")
        XCTAssertNil(rejectedResult)

        let malformed = makeClassifier { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"content":[]}"#.utf8), response)
        }
        let malformedResult = await malformed.classify("Should I continue?")
        XCTAssertNil(malformedResult)
    }

    func testTimeoutReturnsNil() async throws {
        let classifier = AnthropicHaikuQuestionClassifier(
            apiKey: "test-key",
            model: AnthropicHaikuQuestionClassifier.defaultModel,
            endpoint: AnthropicHaikuQuestionClassifier.defaultEndpoint,
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
        let classifier = AnthropicHaikuQuestionClassifier(
            apiKey: "test-key",
            model: AnthropicHaikuQuestionClassifier.defaultModel,
            endpoint: AnthropicHaikuQuestionClassifier.defaultEndpoint,
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

    func testEnvironmentFactoryRequiresANonemptyKey() {
        XCTAssertNil(AnthropicHaikuQuestionClassifier.fromEnvironment([:]))
        XCTAssertNil(AnthropicHaikuQuestionClassifier.fromEnvironment([
            "ANTHROPIC_API_KEY": "  ",
        ]))
        XCTAssertNotNil(AnthropicHaikuQuestionClassifier.fromEnvironment([
            "ANTHROPIC_API_KEY": "test-key",
        ]))
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
        send: @escaping AnthropicHaikuQuestionClassifier.HTTPSender
    ) -> AnthropicHaikuQuestionClassifier {
        AnthropicHaikuQuestionClassifier(
            apiKey: "test-key",
            model: AnthropicHaikuQuestionClassifier.defaultModel,
            endpoint: AnthropicHaikuQuestionClassifier.defaultEndpoint,
            timeout: 1,
            diagnosticSink: NoOpTapQDiagnosticSink(),
            send: send
        )
    }

    private func httpResponse(
        extraction: [String: Any],
        stopReason: String = "end_turn"
    ) throws -> (Data, HTTPURLResponse) {
        let extractionData = try JSONSerialization.data(withJSONObject: extraction)
        let extractionText = String(decoding: extractionData, as: UTF8.self)
        let message: [String: Any] = [
            "content": [["type": "text", "text": extractionText]],
            "stop_reason": stopReason,
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        let response = HTTPURLResponse(
            url: AnthropicHaikuQuestionClassifier.defaultEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
