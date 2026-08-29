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
public struct OpenAINarrationModel: BoundaryNarrating, WorkQuestionAnswering {
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
    /// One boundary utterance: a sentence or two of speech.
    static let narrationOutputTokens = 512
    /// One answer about the work. Larger than a boundary utterance because the wearer asked
    /// a question and the honest answer to "what did the tests say?" is sometimes a list of
    /// failures, and because a cap that clips is a cap that lies about what the history
    /// contained.
    static let answerOutputTokens = 1_024

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
        let (text, latency) = try await perform(
            body: makeBody(
                instructions: NarrationContract.instructions,
                input: NarrationContract.input(for: request),
                schemaName: NarrationContract.schemaName,
                schema: NarrationContract.outputSchema,
                maxOutputTokens: Self.narrationOutputTokens
            ),
            label: "narration"
        )
        let utterance: NarrationUtterance
        do {
            utterance = try NarrationContract.decode(text)
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

    /// Answers one question about an agent's work from the slices it was given
    /// (`docs/TRANSCRIPT_CONTEXT_PLAN.md`).
    ///
    /// The same client as narration, deliberately: the same model family, the same key, the
    /// same endpoint, the same strict-schema decoding, and — the part that matters — the
    /// same failure posture. A separate client would be a second place for this call to
    /// learn how to degrade.
    public func answer(_ request: WorkQuestionRequest) async throws -> String {
        let (text, latency) = try await perform(
            body: makeBody(
                instructions: WorkAnswerContract.instructions,
                input: WorkAnswerContract.input(for: request),
                schemaName: WorkAnswerContract.schemaName,
                schema: WorkAnswerContract.outputSchema,
                maxOutputTokens: Self.answerOutputTokens
            ),
            label: "ask"
        )
        do {
            return try WorkAnswerContract.decode(text)
        } catch let failure as NarrationFailure {
            diagnostics.record("ask.response_rejected", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
                "reason": failure.reason,
            ])
            throw failure
        }
    }

    /// One request against the Responses API, with the timeout race, the status check, and
    /// the `output_text` extraction every caller of this endpoint needs.
    ///
    /// Shared rather than duplicated because the failure posture is what is actually being
    /// reused: both callers are voice-pipeline calls whose every unhappy answer must reach
    /// the same latch, and two copies of this would be two chances for one of them to
    /// quietly degrade instead.
    ///
    /// - Parameter label: the diagnostic name prefix — `narration` or `ask` — so an
    ///   operator can tell which call failed without either caller inventing its own
    ///   transport logging.
    /// - Returns: the response's text payload and the call's latency in milliseconds.
    private func perform(body: [String: Any], label: String) async throws -> (String, String) {
        let httpRequest: URLRequest
        do {
            httpRequest = try makeRequest(body: body)
        } catch {
            diagnostics.record("\(label).request_invalid", level: .warning)
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
            diagnostics.record("\(label).timeout", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
                "timeout_s": "\(Int(timeout))",
            ])
            throw NarrationFailure.timedOut

        case .failed:
            diagnostics.record("\(label).failed", level: .warning, fields: [
                "latency_ms": latency,
                "model": model,
            ])
            throw NarrationFailure.transport("send failed")

        case let .response(data, response):
            guard (200..<300).contains(response.statusCode) else {
                diagnostics.record("\(label).http_error", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                    "status": "\(response.statusCode)",
                ])
                throw NarrationFailure.http(status: response.statusCode)
            }
            do {
                return (try Self.decodeResponse(data), latency)
            } catch let failure as NarrationFailure {
                diagnostics.record("\(label).response_rejected", level: .warning, fields: [
                    "latency_ms": latency,
                    "model": model,
                    "reason": failure.reason,
                ])
                throw failure
            }
        }
    }

    /// The Responses API body, minus the two things that differ per call: what the model is
    /// told to do, and the schema it must fill.
    private func makeBody(
        instructions: String,
        input: String,
        schemaName: String,
        schema: [String: Any],
        maxOutputTokens: Int
    ) -> [String: Any] {
        [
            "model": model,
            "instructions": instructions,
            "input": input,
            "max_output_tokens": maxOutputTokens,
            "reasoning": ["effort": "none"],
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var httpRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    /// The `status`/`incomplete_details`/`refusal` triad, then the text payload. Which
    /// contract that text has to satisfy is the caller's business.
    private static func decodeResponse(_ data: Data) throws -> String {
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
        return text
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
