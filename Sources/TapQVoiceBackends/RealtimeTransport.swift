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
        }
    }
}

/// The one thing `OpenAIRealtimeVoiceBackend` needs from the outside world: an ordered,
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
    public init(url: URL, apiKey: String, session: URLSession = .shared) {
        self.url = url
        self.headers = [
            "Authorization": "Bearer \(apiKey)",
            "OpenAI-Beta": "realtime=v1",
        ]
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
                        continuation.finish(
                            throwing: RealtimeTransportFailure.receiveFailed(String(describing: error)))
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
