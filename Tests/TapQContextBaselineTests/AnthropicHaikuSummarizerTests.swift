import XCTest
import TapQContracts
@testable import TapQContextBaseline
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AnthropicHaikuSummarizerTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testSummaryUsesMessagesAPIAndStrictSchema() async throws {
        let summarizer = makeSummarizer { request in
            XCTAssertEqual(request.url, AnthropicHaikuSummarizer.defaultEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, AnthropicHaikuSummarizer.defaultModel)
            let output = try XCTUnwrap(json["output_config"] as? [String: Any])
            let format = try XCTUnwrap(output["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")

            return try self.httpResponse(extraction: [
                "sentence": " I rewrote the pump. ",
                "detail": " Two files changed and the flake is gone. ",
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
                "sentence": Array(repeating: "alpha", count: 60).joined(separator: " "),
                "detail": Array(repeating: "beta", count: 200).joined(separator: " "),
            ])
        }

        let summary = await summarizer.summarize("A very long reply.")
        let result = try XCTUnwrap(summary)
        XCTAssertLessThanOrEqual(result.sentence.count, SpokenSummary.sentenceCharacterLimit)
        XCTAssertLessThanOrEqual(result.detail.count, SpokenSummary.detailCharacterLimit)
        XCTAssertFalse(result.sentence.hasSuffix(" "))
    }

    func testEmptySentenceReturnsNil() async throws {
        let summarizer = makeSummarizer { _ in
            try self.httpResponse(extraction: ["sentence": "   ", "detail": "Orphan detail."])
        }
        let result = await summarizer.summarize("Anything at all.")
        XCTAssertNil(result)
    }

    func testRefusalAndMaximumTokenResponsesReturnNil() async throws {
        for reason in ["refusal", "max_tokens"] {
            let summarizer = makeSummarizer { _ in
                try self.httpResponse(
                    extraction: ["sentence": "Rewrote the pump.", "detail": ""],
                    stopReason: reason
                )
            }
            let result = await summarizer.summarize("I rewrote the microphone pump.")
            XCTAssertNil(result, "\(reason) must fail open")
        }
    }

    func testHTTPAndMalformedResponsesReturnNil() async throws {
        let rejected = makeSummarizer { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"error":"rate limited"}"#.utf8), response)
        }
        let rejectedResult = await rejected.summarize("I rewrote the microphone pump.")
        XCTAssertNil(rejectedResult)

        let malformed = makeSummarizer { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"content":[]}"#.utf8), response)
        }
        let malformedResult = await malformed.summarize("I rewrote the microphone pump.")
        XCTAssertNil(malformedResult)
    }

    func testTimeoutReturnsNil() async throws {
        let summarizer = AnthropicHaikuSummarizer(
            apiKey: "test-key",
            model: AnthropicHaikuSummarizer.defaultModel,
            endpoint: AnthropicHaikuSummarizer.defaultEndpoint,
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
        let summarizer = AnthropicHaikuSummarizer(
            apiKey: "test-key",
            model: AnthropicHaikuSummarizer.defaultModel,
            endpoint: AnthropicHaikuSummarizer.defaultEndpoint,
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
        let result = await summarizer.summarize("   \n ")
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
    }

    private func makeSummarizer(
        send: @escaping AnthropicHaikuSummarizer.HTTPSender
    ) -> AnthropicHaikuSummarizer {
        AnthropicHaikuSummarizer(
            apiKey: "test-key",
            model: AnthropicHaikuSummarizer.defaultModel,
            endpoint: AnthropicHaikuSummarizer.defaultEndpoint,
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
            url: AnthropicHaikuSummarizer.defaultEndpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
