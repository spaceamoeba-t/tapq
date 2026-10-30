#if canImport(Darwin)
import Foundation

/// `HTTPSending` over `URLSession.shared`. The kernel bounds the call.
public struct URLSessionHTTPSender: HTTPSending {
    public init() {}

    public func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}
#endif
