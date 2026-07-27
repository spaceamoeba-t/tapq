import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapQContracts

/// Cloud question extraction using OpenAI's Responses API and GPT-5.6 Luna.
///
/// Provider failures return `nil` so the classifier chain can fail open through its
/// deterministic local fallback. The API key and submitted reply are never logged.
public struct OpenAILunaQuestionClassifier: ResponseQuestionClassifying {
    public static let defaultModel = "gpt-5.6-luna"
    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let defaultTimeout: TimeInterval = 5

    typealias HTTPSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let send: HTTPSender
    private let diagnostics: TapQDiagnosticEmitter

    public init(
        apiKey: String,
        model: String = Self.defaultModel,
        endpoint: URL = Self.defaultEndpoint,
        timeout: TimeInterval = Self.defaultTimeout,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.init(
            apiKey: apiKey,
            model: model,
            endpoint: endpoint,
            timeout: timeout,
            diagnosticSink: diagnosticSink,
            send: { request in try await Self.liveSend(request) }
        )
    }

    init(
        apiKey: String,
        model: String,
        endpoint: URL,
        timeout: TimeInterval,
        diagnosticSink: any TapQDiagnosticSink,
        send: @escaping HTTPSender
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
        self.send = send
        self.diagnostics = TapQDiagnosticEmitter(
            category: "OpenAIClassifier",
            sink: diagnosticSink
        )
    }

    public func classify(_ text: String) async -> ResponseQuestionClassification? {
        guard text.contains("?") else { return nil }

        let request: URLRequest
        do {
            request = try makeRequest(text: text)
        } catch {
            diagnostics.record("request.invalid", level: .warning)
            return nil
        }

        let started = ContinuousClock.now
        let result = await withTaskGroup(of: RequestResult.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await send(request)
                    return .response(data, response)
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
        let latency = Self.milliseconds(from: started, to: .now)

        switch result {
        case .timedOut:
            diagnostics.record("request.timeout", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
            ])
            return nil
        case .failed:
            diagnostics.record("request.failed", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
            ])
            return nil
        case .response(let data, let response):
            guard (200..<300).contains(response.statusCode) else {
                diagnostics.record("request.http_error", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                    "status": "\(response.statusCode)",
                ])
                return nil
            }
            guard let classification = Self.decodeResponse(data) else {
                diagnostics.record("response.invalid", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                ])
                return nil
            }
            diagnostics.record("request.completed", fields: [
                "kind": CloudQuestionExtractionContract.kind(of: classification),
                "latency_ms": latency,
                "model": model,
            ])
            return classification
        }
    }

    private func makeRequest(text: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "instructions": CloudQuestionExtractionContract.instructions,
            "input": "Classify this reply:\n\n\(text)",
            "max_output_tokens": 256,
            "reasoning": ["effort": "none"],
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "tapq_question_classification",
                    "strict": true,
                    "schema": CloudQuestionExtractionContract.outputSchema,
                ],
            ],
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func decodeResponse(_ data: Data) -> ResponseQuestionClassification? {
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data),
              response.status == "completed",
              response.error == nil,
              response.incompleteDetails == nil else { return nil }

        let content = response.output.compactMap(\.content).flatMap { $0 }
        guard !content.contains(where: { $0.type == "refusal" }),
              let text = content.first(where: { $0.type == "output_text" })?.text else {
            return nil
        }
        return CloudQuestionExtractionContract.decode(text)
    }

    private static func liveSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> String {
        let components = start.duration(to: end).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
        return String(format: "%.0f", milliseconds)
    }

    private enum RequestResult: @unchecked Sendable {
        case response(Data, HTTPURLResponse)
        case failed
        case timedOut
    }

    private struct ResponseBody: Decodable {
        struct APIError: Decodable {
            let code: String?
        }

        struct IncompleteDetails: Decodable {
            let reason: String?
        }

        struct OutputItem: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }

            let content: [Content]?
        }

        let status: String
        let error: APIError?
        let incompleteDetails: IncompleteDetails?
        let output: [OutputItem]

        enum CodingKeys: String, CodingKey {
            case status
            case error
            case incompleteDetails = "incomplete_details"
            case output
        }
    }
}
