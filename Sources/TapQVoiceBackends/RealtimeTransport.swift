import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a realtime transport could not do what it was asked.
///
/// Split by stage rather than collapsed into one case because the adapter maps them to
/// different `VoiceBackendFailure`s: a connect that never happened is worth failing over
/// for, while a peer that hung up mid-session is a closed session.
public enum RealtimeTransportFailure: Error, LocalizedError, Equatable, Sendable {
    case connectFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case closed(String)
    /// The peer refused the connection rather than losing it (2026-10-19): an HTTP status
    /// at the upgrade that blames the credentials or the request, or a close frame that
    /// names a refusal. A new connection would be refused the same way.
    case refused(String, authorization: Bool)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let detail):
            return "The realtime transport could not connect: \(detail)."
        case .sendFailed(let detail):
            return "The realtime transport could not send a frame: \(detail)."
        case .receiveFailed(let detail):
            return "The realtime transport stopped receiving: \(detail)."
        case .closed(let detail):
            return "The realtime transport is closed: \(detail)."
        case .refused(let detail, _):
            return "The realtime service refused the connection: \(detail)."
        }
    }

    /// The error types a close frame's reason names when the service refused the request
    /// (`invalid_request_error.missing_model`, close 4000, measured in §8.1) or the caller.
    static let refusalTypes = ["invalid_request_error", "authentication_error",
                               "permission_error"]

    /// A receive that ended, with the peer's WebSocket close code and reason when it sent
    /// a close frame (03-8): "close 4000 (invalid_request_error.missing_model)" names the
    /// cause where the POSIX error under it only says the socket went away.
    ///
    /// A refusal is told apart from the network (2026-10-19) where the peer said which it
    /// was: an upgrade answered 401 or 403 (the credentials) or 400 or 404 (the request), a
    /// close 1008 (policy), or a close whose reason names a refusal's error type. Anything
    /// else, any 4xxx close that names nothing included, is the network's, as it always was:
    /// a refusal ends a recording, so only one the peer stated is one.
    public static func receiveFailed(_ error: any Error, closeCode: Int, closeReason: Data?,
                                     httpStatus: Int? = nil) -> RealtimeTransportFailure {
        if let httpStatus, [400, 401, 403, 404].contains(httpStatus) {
            return .refused("HTTP \(httpStatus) at the upgrade: \(error)",
                            authorization: httpStatus == 401 || httpStatus == 403)
        }
        guard closeCode != 0 else { return .receiveFailed(String(describing: error)) }
        let reason = closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let detail = "close \(closeCode)" + (reason.isEmpty ? "" : " (\(reason))") + ": \(error)"
        let lowered = reason.lowercased()
        if closeCode == 1008 || refusalTypes.contains(where: { lowered.contains($0) }) {
            return .refused(detail, authorization: lowered.contains("authentication")
                                || lowered.contains("api_key") || lowered.contains("permission"))
        }
        return .receiveFailed(detail)
    }
}

/// The one thing a realtime session needs from the outside world: an ordered,
/// bidirectional stream of JSON text frames.
///
/// This exists so no test ever opens a socket. It is also insurance:
/// `URLSessionWebSocketTask` is only reliably available on Apple platforms, and the
/// corelibs implementation has a long history of misbehaving, so the live class below is
/// compiled out where it cannot be trusted while the adapter above stays portable and
/// fully exercised.
///
/// `@MainActor` to match the backend that drives it — the adapter's whole state lives on
/// the main actor, and a transport on a different isolation domain would mean hopping for
/// every 100 ms audio frame.
@MainActor public protocol RealtimeTransporting: AnyObject {
    /// Establishes the connection. Throws `RealtimeTransportFailure` on failure.
    func connect() async throws

    /// Sends one text frame. Frames must arrive at the peer in call order — the realtime
    /// protocol is a sequence of appends terminated by a commit, and a reordered append is
    /// scrambled audio.
    func send(_ frame: String) async throws

    /// Frames from the peer, in order.
    ///
    /// Finishes normally when the peer closes cleanly, and throws
    /// `RealtimeTransportFailure` when the connection drops. Call once per connection.
    func receiveFrames() -> AsyncThrowingStream<String, any Error>

    /// Tears the connection down. Idempotent and non-throwing, like every teardown path in
    /// this codebase.
    func close()
}

#if canImport(Darwin)
/// The live transport: a WebSocket to the OpenAI Realtime endpoint.
///
/// Compiled only where `URLSessionWebSocketTask` ships in Foundation proper (Apple
/// platforms). On Linux the package still builds — the adapter, the message codec, and
/// every test depend on `RealtimeTransporting`, never on this class.
///
/// Deliberately thin: it holds no protocol knowledge, no retry policy, and no timeout of
/// its own. Timeouts belong to the adapter, which is where the session state that decides
/// what a timeout means lives.
@MainActor public final class URLSessionWebSocketRealtimeTransport: RealtimeTransporting {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    /// - Parameters:
    ///   - url: the realtime endpoint, model already in the query string.
    ///   - apiKey: sent as a bearer header and never stored anywhere else, never logged,
    ///     and never included in a failure description.
    ///
    /// Authorization is the only header GA needs. `OpenAI-Beta: realtime=v1` used to ride
    /// along here and is deliberately gone: it is what routed the connection to the Beta
    /// API, which was retired on 2026-08-27 and now refuses the session outright.
    public init(url: URL, apiKey: String, session: URLSession = .shared) {
        self.url = url
        self.headers = ["Authorization": "Bearer \(apiKey)"]
        self.session = session
    }

    public func connect() async throws {
        guard task == nil else {
            throw RealtimeTransportFailure.connectFailed("the transport is already connected")
        }
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    public func send(_ frame: String) async throws {
        guard let task else {
            throw RealtimeTransportFailure.closed("no connection is open")
        }
        do {
            try await task.send(.string(frame))
        } catch {
            throw RealtimeTransportFailure.sendFailed(String(describing: error))
        }
    }

    public func receiveFrames() -> AsyncThrowingStream<String, any Error> {
        guard let task else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RealtimeTransportFailure.closed("no connection is open"))
            }
        }
        return AsyncThrowingStream { continuation in
            // The receive loop captures the task, not `self`: it outlives any main-actor
            // hop and must not keep the transport alive on its own.
            let pump = Task.detached {
                while true {
                    do {
                        switch try await task.receive() {
                        case .string(let frame):
                            continuation.yield(frame)
                        case .data(let data):
                            // The realtime protocol is text-only; binary here means the
                            // peer is speaking something this adapter does not know.
                            continuation.yield(String(decoding: data, as: UTF8.self))
                        @unknown default:
                            continue
                        }
                    } catch {
                        // An upgrade the service answered with a status of its own (401
                        // for a key it refuses) fails the first receive; the response says
                        // which status it was.
                        let status = (task.response as? HTTPURLResponse)?.statusCode
                        continuation.finish(throwing: RealtimeTransportFailure.receiveFailed(
                            error, closeCode: task.closeCode.rawValue,
                            closeReason: task.closeReason,
                            httpStatus: status.flatMap { $0 >= 400 ? $0 : nil }))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
#endif
