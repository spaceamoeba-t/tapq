import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapQContracts

/// Cloud question extraction using Anthropic's Messages API and Claude Haiku.
///
/// The adapter is deliberately small: it implements the existing classifier seam,
/// returns `nil` on every provider failure so the local heuristic can fail open, and
/// never persists or logs the response text or API key.
public struct AnthropicHaikuQuestionClassifier: ResponseQuestionClassifying {
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
            category: "AnthropicClassifier",
            sink: diagnosticSink
        )
    }

    /// Creates the provider only when TapQ's classifier selector explicitly opts in
    /// to Anthropic and a nonempty API key is available. An inherited
    /// `ANTHROPIC_API_KEY` alone must never enable cloud classification.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) -> AnthropicHaikuQuestionClassifier? {
        let diagnostics = TapQDiagnosticEmitter(
            category: "AnthropicClassifier",
            sink: diagnosticSink
        )
        let selector = environment["TAPQ_QUESTION_CLASSIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch selector {
        case "", "default", "off", "local":
            return nil
        case "anthropic":
            break
        default:
            diagnostics.record("configuration.invalid_selector", level: .warning)
            return nil
        }

        guard let key = environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            diagnostics.record("configuration.missing_api_key", level: .warning)
            return nil
        }
        return AnthropicHaikuQuestionClassifier(
            apiKey: key,
            diagnosticSink: diagnosticSink
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
                "kind": Self.kind(of: classification),
                "latency_ms": latency,
                "model": model,
            ])
            return classification
        }
    }

    private func makeRequest(text: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "temperature": 0,
            "system": Self.instructions,
            "messages": [[
                "role": "user",
                "content": "Classify this reply:\n\n\(text)",
            ]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": Self.outputSchema,
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

    private static func decodeResponse(_ data: Data) -> ResponseQuestionClassification? {
        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data),
              message.stopReason != "refusal",
              message.stopReason != "max_tokens",
              let text = message.content.first(where: { $0.type == "text" })?.text,
              let extractionData = text.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: extractionData)
        else { return nil }
        return interpret(extraction)
    }

    private static func interpret(
        _ extraction: Extraction
    ) -> ResponseQuestionClassification? {
        let question = extraction.question.trimmingCharacters(in: .whitespacesAndNewlines)
        switch extraction.kind.lowercased() {
        case "none":
            return .noQuestion
        case "yes_no":
            guard !question.isEmpty else { return nil }
            return .yesNo(question: question)
        case "multi_option":
            guard !question.isEmpty else { return nil }
            let options = extraction.options.prefix(6).compactMap { option -> SelectionOption? in
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                return SelectionOption(
                    label: label,
                    description: option.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard options.count >= 2 else { return nil }
            return .multiOption(question: question, options: options)
        default:
            return nil
        }
    }

    private static func liveSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private static func kind(of classification: ResponseQuestionClassification) -> String {
        switch classification {
        case .noQuestion: return "none"
        case .yesNo: return "yes_no"
        case .multiOption: return "multi_option"
        }
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

    private struct Extraction: Decodable {
        struct Option: Decodable {
            let label: String
            let description: String
        }

        let kind: String
        let question: String
        let options: [Option]
    }

    private static let instructions = """
        You read the final reply a coding assistant sent to its user and decide whether \
        it is waiting on the user to answer a question. Classify the reply:
        - multi_option: it offers two or more distinct alternatives and asks the user to pick one.
        - yes_no: it asks a single question answerable with yes or no.
        - none: everything else, including statements, rhetorical questions, and open-ended \
        questions with no offered alternatives.
        Summarize the question in at most 12 spoken-friendly words. For multi_option, \
        list each offered alternative in order with a label of at most 4 words and a \
        one-line description. Never invent alternatives the reply does not offer. For \
        yes_no and none, return an empty options array.
        """

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": [
                "type": "string",
                "enum": ["none", "yes_no", "multi_option"],
            ],
            "question": [
                "type": "string",
                "description": "At most 12 spoken-friendly words; empty when kind is none.",
            ],
            "options": [
                "type": "array",
                "description": "Offered alternatives in order; empty unless kind is multi_option.",
                "items": [
                    "type": "object",
                    "properties": [
                        "label": [
                            "type": "string",
                            "description": "Short spoken label, at most 4 words.",
                        ],
                        "description": [
                            "type": "string",
                            "description": "One short sentence describing this alternative.",
                        ],
                    ],
                    "required": ["label", "description"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["kind", "question", "options"],
        "additionalProperties": false,
    ]
}
