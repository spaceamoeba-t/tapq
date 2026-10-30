import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TapQContracts
import TapQKernel

/// One HTTP POST. The URLSession implementation is `#if canImport(Darwin)`; tests use fakes.
public protocol HTTPSending: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// The Responses API as the text models need it. The API key never appears in an error
/// string or a diagnostic. The kernel bounds every call, so the client sets no bound of its own.
public struct OpenAIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    private let apiKey: String
    private let baseURL: URL
    private let http: any HTTPSending

    public init(apiKey: String, baseURL: URL = OpenAIClient.defaultBaseURL,
                http: any HTTPSending) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    /// Decodes a Responses-API body: requires `status == "completed"`, no `error`, no
    /// `incomplete_details`, no `refusal`, then returns the first `output_text` (R §5.1). An
    /// incomplete response and a refusal are call-bound: the user's own words caused them.
    public func respond(_ body: Data) async throws(TextModelError) -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let status: Int, data: Data
        do {
            (status, data) = try await http.post(request)
        } catch {
            // Never the error's own description: it may quote the request.
            throw .callBound("transport")
        }
        switch status {
        case 200..<300:
            return try Self.outputText(data)
        case 408, 429, 500..<600:
            throw .callBound("http \(status)")
        default:
            // Only the error's `code` (e.g. `invalid_api_key`): a 401 `message` quotes the key.
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.code
            throw .contract(["http \(status)", code].compactMap { $0 }.joined(separator: " "))
        }
    }

    private static func outputText(_ data: Data) throws(TextModelError) -> String {
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw .contract("response misses the Responses schema")
        }
        switch response.status {
        case "completed":
            break
        case "incomplete":
            let reason = response.incompleteDetails?["reason"]?.stringValue
            throw .callBound(["response incomplete", reason].compactMap { $0 }.joined(separator: " "))
        default:
            throw .contract("response \(response.status)")
        }
        guard response.error == nil, response.incompleteDetails == nil else {
            throw .contract("completed response carries error or incomplete_details")
        }
        let content = response.output.compactMap(\.content).joined()
        if content.contains(where: { $0.type == "refusal" }) { throw .callBound("refusal") }
        guard let text = content.first(where: { $0.type == "output_text" })?.text else {
            throw .contract("response has no output_text")
        }
        return text
    }

    private struct ResponseBody: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        struct Item: Decodable {
            /// Absent on reasoning items.
            let content: [Content]?
        }

        let status: String
        let error: JSONValue?
        let incompleteDetails: JSONValue?
        let output: [Item]

        enum CodingKeys: String, CodingKey {
            case status, error, output
            case incompleteDetails = "incomplete_details"
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String? }
        let error: Detail
    }
}
