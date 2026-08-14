import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapQContracts

/// Cloud spoken summarization using Anthropic's Messages API and Claude Haiku.
///
/// The adapter is deliberately small: it implements the existing summarizer seam,
/// returns `nil` on every provider failure so the local heuristic can fail open, and
/// never persists or logs the reply text or API key.
public struct AnthropicHaikuSummarizer: SpokenSummarizing {
    public static let defaultModel = "claude-haiku-4-5-20251001"
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
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
            category: "AnthropicSummarizer",
            sink: diagnosticSink
        )
    }

    public func summarize(_ text: String) async -> SpokenSummary? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

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
            guard let summary = Self.decodeResponse(data) else {
                diagnostics.record("response.invalid", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                ])
                return nil
            }
            diagnostics.record("request.completed", fields: [
                "detail_chars": "\(summary.detail.count)",
                "latency_ms": latency,
                "model": model,
                "sentence_chars": "\(summary.sentence.count)",
            ])
            return summary
        }
    }

    private func makeRequest(text: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "temperature": 0,
            "system": CloudSpokenSummaryContract.instructions,
            "messages": [[
                "role": "user",
                "content": "Summarize this reply for speech:\n\n\(text)",
            ]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": CloudSpokenSummaryContract.outputSchema,
                ],
            ],
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func decodeResponse(_ data: Data) -> SpokenSummary? {
        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data),
              message.stopReason != "refusal",
              message.stopReason != "max_tokens",
              let text = message.content.first(where: { $0.type == "text" })?.text,
              let summary = CloudSpokenSummaryContract.decode(text)
        else { return nil }
        return summary
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

    private struct MessageResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }
}
