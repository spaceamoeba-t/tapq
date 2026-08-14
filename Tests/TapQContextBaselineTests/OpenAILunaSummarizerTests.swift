import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAILunaSummarizerTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testSummaryUsesResponsesAPIAndStrictSchema() async throws {
        let summarizer = makeSummarizer { request in
            XCTAssertEqual(request.url, OpenAILunaSummarizer.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-key"
            )

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, OpenAILunaSummarizer.defaultModel)
            XCTAssertEqual(json["max_output_tokens"] as? Int, 256)
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertTrue((json["instructions"] as? String)?.contains("sentence") == true)
            XCTAssertTrue((json["input"] as? String)?.contains("microphone pump") == true)

            let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "none")
            let text = try XCTUnwrap(json["text"] as? [String: Any])
            let format = try XCTUnwrap(text["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["name"] as? String, "tapq_spoken_summary")
            XCTAssertEqual(format["strict"] as? Bool, true)
            XCTAssertNotNil(format["schema"] as? [String: Any])

            return try self.httpResponse(extraction: [
                "sentence": "I rewrote the pump.",
                "detail": "Two files changed and the flake is gone.",
            ])
        }

        let result = await summarizer.summarize("I rewrote the microphone pump.")
        XCTAssertEqual(
            result,
            SpokenSummary(
                sentence: "I rewrote the pump.",
                detail: "Two files changed and the flake is gone."
            )
        )
    }

    func testOversizedModelOutputIsTruncatedLocally() async throws {
        let summarizer = makeSummarizer { _ in
            try self.httpResponse(extraction: [
                "sentence": "First sentence stays. " + String(repeating: "extra words here ", count: 40),
                "detail": Array(repeating: "beta", count: 200).joined(separator: " "),
            ])
        }

        let summary = await summarizer.summarize("A very long reply.")
        let result = try XCTUnwrap(summary)
        XCTAssertEqual(result.sentence, "First sentence stays.")
        XCTAssertLessThanOrEqual(result.detail.count, SpokenSummary.detailCharacterLimit)
    }

    func testEmptySentenceReturnsNil() async throws {
        let summarizer = makeSummarizer { _ in
            try self.httpResponse(extraction: ["sentence": "", "detail": "Orphan detail."])
        }
        let result = await summarizer.summarize("Anything at all.")
        XCTAssertNil(result)
    }

    func testHTTPErrorAndInvalidResponsesReturnNil() async throws {
        let rejected = makeSummarizer { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        let rejectedResult = await rejected.summarize("I rewrote the microphone pump.")
        XCTAssertNil(rejectedResult)

        for body in [
            #"{"status":"failed","error":{"code":"server_error"},"incomplete_details":null,"output":[]}"#,
            #"{"status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[{"content":[{"type":"refusal"}]}]}"#,
            #"{"status":"completed","error":null,"incomplete_details":null,"output":[]}"#,
            #"{"not":"a response"}"#,
        ] {
            let summarizer = makeSummarizer { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
            let result = await summarizer.summarize("I rewrote the microphone pump.")
            XCTAssertNil(result, body)
        }
    }

    func testTimeoutReturnsNil() async {
        let summarizer = OpenAILunaSummarizer(
            apiKey: "test-key",
            model: OpenAILunaSummarizer.defaultModel,
            endpoint: OpenAILunaSummarizer.defaultEndpoint,
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
        let result = await summarizer.summarize("I rewrote the microphone pump.")
        XCTAssertNil(result)
    }

    func testBlankTextSkipsNetwork() async {
        let counter = Counter()
        let summarizer = OpenAILunaSummarizer(
            apiKey: "test-key",
            model: OpenAILunaSummarizer.defaultModel,
            endpoint: OpenAILunaSummarizer.defaultEndpoint,
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

        let result = await summarizer.summarize("\n\t  ")
        let count = await counter.value
        XCTAssertNil(result)
        XCTAssertEqual(count, 0)
    }

    func testProviderFailureFallsBackToTheLocalReduction() async throws {
        let primary = makeSummarizer { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        let chain = SpokenSummarizerChain(
            primary: primary,
            fallback: HeuristicSpokenSummarizer()
        )

        let result = await chain.summarize("Rebuilt the bundle. Reinstalled the hook.")
        XCTAssertEqual(result?.sentence, "Rebuilt the bundle.")
        XCTAssertEqual(result?.detail, "Rebuilt the bundle. Reinstalled the hook.")
    }

    private func makeSummarizer(
        send: @escaping OpenAILunaSummarizer.HTTPSender
    ) -> OpenAILunaSummarizer {
        OpenAILunaSummarizer(
            apiKey: "test-key",
            model: OpenAILunaSummarizer.defaultModel,
            endpoint: OpenAILunaSummarizer.defaultEndpoint,
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
            url: OpenAILunaSummarizer.defaultEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
