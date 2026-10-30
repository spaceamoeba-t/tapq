import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import TapQContracts
import TapQKernel
import TapQOpenAI

/// The only `HTTPSending` the suites use: it records each request and answers from a
/// canned result, so nothing in these tests reaches a network.
final class FakeHTTP: HTTPSending {
    private let result: Result<(status: Int, body: Data), any Error>
    private let recorded = Locked<[URLRequest]>([])

    init(status: Int = 200, body: Data) { result = .success((status, body)) }
    init(throwing error: any Error) { result = .failure(error) }

    /// A 200 whose body carries `text` as the first `output_text`.
    convenience init(outputText text: String) { self.init(body: completedResponse(text)) }

    var requests: [URLRequest] { recorded.value }

    /// The body of the one request sent, as a JSON object.
    var sentBody: [String: JSONValue] {
        get throws {
            let requests = self.requests
            XCTAssertEqual(requests.count, 1)
            let body = try XCTUnwrap(requests.first?.httpBody)
            return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        }
    }

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        recorded.mutate { $0.append(request) }
        return try result.get()
    }
}

final class RecordingSink: TapQDiagnosticSink {
    private let recorded = Locked<[TapQDiagnosticEvent]>([])

    var events: [TapQDiagnosticEvent] { recorded.value }

    func record(_ event: TapQDiagnosticEvent) { recorded.mutate { $0.append(event) } }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

/// Not shaped like a real key, so the public-boundary scan stays quiet.
let testAPIKey = "tapq-test-key-0123456789"

/// `.invalid` never resolves.
func makeClient(_ http: FakeHTTP) -> OpenAIClient {
    OpenAIClient(apiKey: testAPIKey, baseURL: URL(string: "https://api.openai.invalid/v1")!,
                 http: http)
}

func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// A completed Responses body: a reasoning item without content, then the message.
func completedResponse(_ text: String) -> Data {
    responseBody(status: "completed", content: [["type": .string("output_text"), "text": .string(text),
                                                 "annotations": .array([])]])
}

func responseBody(status: String, content: [[String: JSONValue]],
                  extra: [String: JSONValue] = [:]) -> Data {
    let message: JSONValue = .object(["type": .string("message"), "role": .string("assistant"),
                                      "content": .array(content.map(JSONValue.object))])
    let body: [String: JSONValue] = [
        "id": .string("resp_1"), "object": .string("response"), "status": .string(status),
        "error": .null, "incomplete_details": .null,
        "output": .array([.object(["type": .string("reasoning"), "summary": .array([])]), message]),
    ].merging(extra) { $1 }
    return try! JSONEncoder().encode(JSONValue.object(body))
}

/// The typed error `body` throws, or nil with a failure when it returns.
func thrownError<T>(_ body: () async throws(TextModelError) -> T,
                    file: StaticString = #filePath, line: UInt = #line) async -> TextModelError? {
    do {
        let value = try await body()
        XCTFail("expected a TextModelError, got \(value)", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
