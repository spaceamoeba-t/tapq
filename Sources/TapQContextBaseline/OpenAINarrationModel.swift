import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapQContracts

/// The narration model for the `openai-realtime` path: a side call to OpenAI's REST API
/// that decides what TapQ says at a turn boundary.
///
/// ## Why the Responses API and not chat completions
///
/// Two reasons, and neither is a preference. First, it is what this repo already speaks:
/// ``OpenAILunaSummarizer`` and ``OpenAILunaQuestionClassifier`` both POST to
/// `/v1/responses` with `text.format.json_schema`, and their response decoding — the
/// `status`/`incomplete_details`/`refusal` triad — is the shape this file reuses rather
/// than reinventing. Second, strict structured output is load-bearing here: TapQ speaks
/// `utterance` verbatim and *branches* on `mode`, so a free-text completion that drifted
/// into prose would be read out as prose. `reasoning.effort: none` is set for the same
/// reason the summarizer sets it — the wearer is standing at a held boundary waiting to
/// hear something.
///
/// ## Why this is not the realtime session
///
/// The realtime session is a duplex voice pipe that *generates* audio from text. Asking it
/// to decide narration would let it rewrite the sentence on the way out, and the run has
/// exactly one voice by construction (`BackendSpeechSink`). So narration is decided here,
/// over plain HTTP, and the resulting text goes out on the scripted-speech channel where
/// it is repeated word for word.
///
/// The API key is never logged, and neither is the request body or the agent's output:
/// diagnostics carry counts, lengths, statuses, and timings only.
public struct OpenAINarrationModel: BoundaryNarrating {
    /// The maintainer-specified narration model (ratified 2026-08-28).
    public static let defaultModel = "gpt-5.6-luna"
    /// The single override seam. No CLI flag: the model id is an operational detail of a
    /// path the operator already selected with `--voice-backend openai-realtime`, and it
    /// follows the same environment-key convention as `TAPQ_SPEECH_VOICE`.
    public static let environmentKey = "TAPQ_NARRATION_MODEL"
    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    /// Generous on purpose. The wearer is at a held turn boundary whose lease renews while
    /// this runs, so a slow narration costs latency and nothing else — while a tight bound
    /// would break the run's voice pipe over a busy minute at the provider.
    public static let defaultTimeout: TimeInterval = 15

    /// The model id for this run: the environment override when set and non-blank,
    /// otherwise ``defaultModel``.
    public static func resolvedModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let override = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty else { return defaultModel }
        return override
    }

    typealias HTTPSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let send: HTTPSender
    private let diagnostics: TapQDiagnosticEmitter

    public init(
        apiKey: String,
        model: String = OpenAINarrationModel.resolvedModel(),
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
            category: "Narration",
            sink: diagnosticSink
        )
    }

    public func narrate(_ request: NarrationRequest) async throws -> NarrationUtterance {
        diagnostics.record("narration.requested", fields: [
            "items": "\(request.items.count)",
            "model": model,
        ])

        let httpRequest: URLRequest
        do {
            httpRequest = try makeRequest(for: request)
        } catch {
            diagnostics.record("narration.request_invalid", level: .warning)
            throw NarrationFailure.transport("request could not be encoded")
        }

        let started = ContinuousClock.now
        let result = await withTaskGroup(of: RequestResult.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await send(httpRequest)
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
            diagnostics.record("narration.timeout", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
                "timeout_s": "\(Int(timeout))",
            ])
            throw NarrationFailure.timedOut

        case .failed:
            diagnostics.record("narration.failed", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
            ])
            throw NarrationFailure.transport("send failed")

        case let .response(data, response):
            guard (200..<300).contains(response.statusCode) else {
                diagnostics.record("narration.http_error", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                    "status": "\(response.statusCode)",
                ])
                throw NarrationFailure.http(status: response.statusCode)
            }
            let utterance: NarrationUtterance
            do {
                utterance = try Self.decodeResponse(data)
            } catch let failure as NarrationFailure {
                diagnostics.record("narration.response_rejected", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                    "reason": failure.reason,
                ])
                throw failure
            }
            diagnostics.record("narration.spoken", fields: [
                "latency_ms": latency,
                "length": "\(utterance.text.count)",
                "mode_hint": utterance.mode.rawValue,
                "model": model,
            ])
            return utterance
        }
    }

    private func makeRequest(for request: NarrationRequest) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "instructions": NarrationContract.instructions,
            "input": NarrationContract.input(for: request),
            "max_output_tokens": 512,
            "reasoning": ["effort": "none"],
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": NarrationContract.schemaName,
                    "strict": true,
                    "schema": NarrationContract.outputSchema,
                ],
            ],
        ]

        var httpRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    private static func decodeResponse(_ data: Data) throws -> NarrationUtterance {
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data),
              response.status == "completed",
              response.error == nil,
              response.incompleteDetails == nil else {
            throw NarrationFailure.malformedResponse
        }

        let content = response.output.compactMap(\.content).flatMap { $0 }
        guard !content.contains(where: { $0.type == "refusal" }) else {
            throw NarrationFailure.malformedResponse
        }
        guard let text = content.first(where: { $0.type == "output_text" })?.text else {
            throw NarrationFailure.malformedResponse
        }
        return try NarrationContract.decode(text)
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
