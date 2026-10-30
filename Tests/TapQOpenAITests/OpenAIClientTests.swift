import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import TapQContracts
import TapQKernel
import TapQOpenAI

final class OpenAIClientTests: XCTestCase {
    private let body = Data(#"{"model":"m"}"#.utf8)

    func testPostsTheBodyToResponsesWithTheKey() async throws {
        let http = FakeHTTP(outputText: "hello")
        let client = OpenAIClient(apiKey: testAPIKey, http: http)

        let text = try await client.respond(body)

        XCTAssertEqual(text, "hello")
        let sent = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(testAPIKey)")
        XCTAssertEqual(sent.httpBody, body)
    }

    func testStatusCodesSplitIntoCallBoundAndContract() async {
        let table: [(status: Int, expected: TextModelError)] = [
            (408, .callBound("http 408")), (429, .callBound("http 429")),
            (500, .callBound("http 500")), (502, .callBound("http 502")),
            (503, .callBound("http 503")), (504, .callBound("http 504")),
            (599, .callBound("http 599")),
            (400, .contract("http 400")), (401, .contract("http 401")),
            (403, .contract("http 403")), (404, .contract("http 404")),
            (409, .contract("http 409")), (422, .contract("http 422")),
            (302, .contract("http 302")),
        ]
        for (status, expected) in table {
            let client = makeClient(FakeHTTP(status: status, body: Data()))
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertEqual(error, expected, "status \(status)")
        }
    }

    func testAContractErrorNamesTheAPIErrorCode() async {
        let client = makeClient(FakeHTTP(status: 404, body: Data(#"""
            {"error":{"message":"The model `gpt-x` does not exist","type":"invalid_request_error","param":null,"code":"model_not_found"}}
            """#.utf8)))
        let error = await thrownError { () async throws(TextModelError) in
            try await client.respond(body)
        }
        XCTAssertEqual(error, .contract("http 404 model_not_found"))
    }

    func testTransportErrorIsCallBound() async {
        for failure: any Error in [URLError(.timedOut), URLError(.notConnectedToInternet),
                                   URLError(.networkConnectionLost), CancellationError()] {
            let client = makeClient(FakeHTTP(throwing: failure))
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertEqual(error, .callBound("transport"))
        }
    }

    /// The user's own words decide these, so they are spoken, never fatal (V1 P1-2).
    func testARefusalIsCallBound() async {
        let client = makeClient(FakeHTTP(body: responseBody(status: "completed", content: [
            ["type": .string("refusal"), "refusal": .string("I can't help with that.")],
        ])))
        let error = await thrownError { () async throws(TextModelError) in
            try await client.respond(body)
        }
        XCTAssertEqual(error, .callBound("refusal"))
    }

    func testAnIncompleteResponseIsCallBoundForAnyReason() async {
        for reason in ["max_output_tokens", "content_filter"] {
            let client = makeClient(FakeHTTP(body: responseBody(
                status: "incomplete",
                content: [["type": .string("output_text"), "text": .string(#"{"action":"instr"#)]],
                extra: ["incomplete_details": .object(["reason": .string(reason)])])))
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertEqual(error, .callBound("response incomplete \(reason)"))
        }
    }

    func testAnotherStatusIsContract() async {
        let client = makeClient(FakeHTTP(body: responseBody(status: "failed", content: [])))
        let error = await thrownError { () async throws(TextModelError) in
            try await client.respond(body)
        }
        XCTAssertEqual(error, .contract("response failed"))
    }

    func testIncompleteDetailsOrAnErrorOnACompletedResponseIsContract() async {
        for extra: [String: JSONValue] in [
            ["incomplete_details": .object(["reason": .string("content_filter")])],
            ["error": .object(["code": .string("server_error"), "message": .string("boom")])],
        ] {
            let client = makeClient(FakeHTTP(body: responseBody(
                status: "completed",
                content: [["type": .string("output_text"), "text": .string("partial")]],
                extra: extra)))
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertEqual(error, .contract("completed response carries error or incomplete_details"))
        }
    }

    func testABodyWithoutOutputTextIsContract() async {
        let client = makeClient(FakeHTTP(body: responseBody(status: "completed", content: [])))
        let error = await thrownError { () async throws(TextModelError) in
            try await client.respond(body)
        }
        XCTAssertEqual(error, .contract("response has no output_text"))
    }

    func testABodyOutsideTheResponsesSchemaIsContract() async {
        for canned in [#"{"status":"completed"}"#, "not json", ""] {
            let client = makeClient(FakeHTTP(body: Data(canned.utf8)))
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertEqual(error, .contract("response misses the Responses schema"), canned)
        }
    }

    func testTheKeyAppearsInNoErrorString() async {
        let echo = Data("""
            {"error":{"message":"Incorrect API key provided: \(testAPIKey).","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}
            """.utf8)
        let leakyTransport = URLError(.cannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "failed with Bearer \(testAPIKey)",
        ])
        let fakes = [
            FakeHTTP(status: 401, body: echo), FakeHTTP(status: 403, body: echo),
            FakeHTTP(status: 500, body: echo), FakeHTTP(status: 200, body: echo),
            FakeHTTP(throwing: leakyTransport), FakeHTTP(throwing: URLError(.timedOut)),
        ]
        for http in fakes {
            let client = makeClient(http)
            let error = await thrownError { () async throws(TextModelError) in
                try await client.respond(body)
            }
            XCTAssertNotNil(error)
            for rendered in [String(describing: error), String(reflecting: error)] {
                XCTAssertFalse(rendered.contains(testAPIKey), rendered)
            }
        }
        XCTAssertEqual(fakes[0].requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(testAPIKey)", "the key was sent, so its absence above means something")
    }
}
