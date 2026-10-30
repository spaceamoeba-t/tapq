import Foundation
import TapQContracts

/// The connection both realtime sessions stand on: connect, the one `session.update`, a
/// bounded wait for `session.updated`, one ordered outbound pump, the receive loop, and a
/// single end.
///
/// It handles the ack and every `error` frame itself and hands every other server event to
/// `onEvent`, and one error frame with it: an empty commit, which answers a client's own
/// commit and ends nothing (2026-10-19). `onEnd` is called exactly once, when the connection
/// ends: with `.expired` for `session_expired` once open (D4), with `.failed` for any other
/// failure after the handshake or before `open()`, and with `nil` for `close()` or a failed
/// `open()`, which throws its own `VoiceBackendFailure` instead. Nothing here retries or
/// reconnects.
@MainActor final class RealtimeConnection {
    enum Phase { case idle, handshaking, open, ended }
    /// `retryable`: the network ended it (a transport error, the peer hanging up, a stalled
    /// queue, a handshake that never finished, the service's own `server_error`), so a new
    /// session can be tried; not the credentials, and not something the service refused.
    enum Ending: Equatable { case expired, failed(String, retryable: Bool) }

    private(set) var phase = Phase.idle
    let diagnostics: TapQDiagnosticEmitter
    var onEvent: (@MainActor (RealtimeServerEvent) -> Void)?
    var onEnd: (@MainActor (Ending?) -> Void)?

    private let transport: any RealtimeTransporting
    /// "speech" or "transcription", for the failures this reports.
    private let name: String
    private let timeout: TimeInterval
    /// How long one send may go without returning before the socket is taken for one that
    /// stopped draining (2026-10-19): a half-open link fails no send and resets nothing, and a
    /// caller that paces its own sending never fills the queue far enough for the cap to see
    /// it. `nil`, the loop's: unbounded, the cap stands alone.
    private let sendTimeout: TimeInterval?
    private let sleep: @Sendable (TimeInterval) async -> Void

    private let outbound: AsyncStream<String>
    private let outboundContinuation: AsyncStream<String>.Continuation
    /// UTF-8 bytes queued for the pump whose send has not returned.
    private var queuedBytes = 0
    /// Bytes handed to the pump and not yet sent.
    var outboundBytes: Int { queuedBytes }
    /// Every byte ever handed to the pump, and every byte whose send has returned: together,
    /// how much of what a caller handed over has left this process (2026-10-19). A send that
    /// returned is the one sign of life an outbound socket gives.
    private(set) var handedBytes = 0
    private(set) var sentBytes = 0
    /// Fired each time the pump has sent everything it was handed: the event a caller that
    /// paces its own sending waits on.
    var onDrained: (@MainActor () -> Void)?
    /// The pump is inside a send that has not returned.
    private var sending = false
    /// Which send that is, so a bound armed for an earlier one does nothing.
    private var sendSerial = 0
    private var pump: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?
    private var handshake: CheckedContinuation<Void, any Error>?
    private var handshakeBound: Task<Void, Never>?
    /// The failure that ended the connection during the handshake: what `open()` throws when
    /// the end landed after the ack, in the same turn, before `open()` could resume.
    private var handshakeEnding: VoiceBackendFailure?

    init(transport: any RealtimeTransporting, name: String, timeout: TimeInterval,
         sendTimeout: TimeInterval? = nil,
         sleep: @escaping @Sendable (TimeInterval) async -> Void,
         diagnostics: TapQDiagnosticEmitter) {
        self.transport = transport
        self.name = name
        self.timeout = timeout
        self.sendTimeout = sendTimeout
        self.sleep = sleep
        self.diagnostics = diagnostics
        (outbound, outboundContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Connects, sends `session` as the first frame, and waits at most `timeout` for the
    /// ack. Throws `VoiceBackendFailure`.
    func open(_ session: some Encodable) async throws {
        guard phase == .idle else {
            throw VoiceBackendFailure.protocolViolation("a \(name) session opens once")
        }
        let update: String
        do {
            update = String(decoding: try JSONEncoder.sorted.encode(SessionUpdate(session: session)),
                            as: UTF8.self)
        } catch {
            throw VoiceBackendFailure.protocolViolation("the session could not be encoded: \(error)")
        }
        phase = .handshaking
        do {
            try await transport.connect()
        } catch RealtimeTransportFailure.refused(let detail, let authorization) {
            // Refused before any socket opened (no key to connect with): a new
            // connection would be refused the same way, so it is no network failure.
            let kind = authorization ? VoiceBackendFailure.authorization : VoiceBackendFailure.protocolViolation
            fail(detail, kind)
            throw kind(detail)
        } catch {
            fail(error.localizedDescription, VoiceBackendFailure.network)
            throw VoiceBackendFailure.network(error.localizedDescription)
        }
        guard phase == .handshaking else {
            throw VoiceBackendFailure.closed("the session was closed while it connected")
        }
        startReceiveLoop()
        startPump()
        yieldOutbound(update)
        let bound = timeout
        let sleep = self.sleep
        let name = self.name
        handshakeBound = Task { @MainActor [weak self] in
            await sleep(bound)
            guard !Task.isCancelled else { return }
            self?.fail("the \(name) handshake timed out after \(String(format: "%g", bound)) s",
                       VoiceBackendFailure.network)
        }
        try await withCheckedThrowingContinuation { handshake = $0 }
        // The ack resumed this, and the connection may have ended after it before this ran:
        // a hang-up or an error frame right behind `session.updated`, or a `close()`. A
        // connection that ended is not handed back as open (review, 2026-10-19).
        guard phase == .handshaking else {
            throw handshakeEnding
                ?? VoiceBackendFailure.closed("the session ended as its handshake landed")
        }
        phase = .open
    }

    func send(_ event: RealtimeClientEvent) {
        do {
            yieldOutbound(try event.encodedFrame())
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Ends the connection once. During the handshake `open()` throws `kind(reason)`;
    /// otherwise `onEnd` gets `.failed(reason)`.
    func fail(_ reason: String,
              _ kind: (String) -> VoiceBackendFailure = VoiceBackendFailure.protocolViolation) {
        guard phase != .ended else { return }
        diagnostics.record("session.failed", level: .warning, fields: ["detail": reason])
        let failure = kind(reason)
        if phase == .handshaking {
            handshakeEnding = failure
            settleHandshake(.failure(failure))
            end(nil)
        } else {
            end(.failed(reason, retryable: Self.isRetryable(failure)))
        }
    }

    /// Idempotent; no ending is reported.
    /// The network's failures, which a new session may outlive.
    static func isRetryable(_ failure: VoiceBackendFailure) -> Bool {
        switch failure {
        case .network, .closed: return true
        case .protocolViolation, .authorization: return false
        }
    }

    func close() {
        guard phase != .ended else { return }
        if phase != .idle { diagnostics.record("session.closed") }
        end(nil)
    }

    // MARK: - Inbound

    private func startReceiveLoop() {
        let frames = transport.receiveFrames()
        receiveLoop = Task { @MainActor [weak self] in
            do {
                for try await frame in frames {
                    guard let self, self.phase != .ended else { return }
                    self.handle(frame)
                }
            } catch RealtimeTransportFailure.refused(let detail, let authorization) {
                // The peer refused the connection, not the network losing it: a new one
                // would be refused the same way.
                self?.fail(detail, authorization ? VoiceBackendFailure.authorization
                               : VoiceBackendFailure.protocolViolation)
                return
            } catch {
                self?.fail(error.localizedDescription, VoiceBackendFailure.network)
                return
            }
            self?.fail("the peer closed the session", VoiceBackendFailure.closed)
        }
    }

    private func handle(_ frame: String) {
        let event: RealtimeServerEvent
        do {
            event = try RealtimeServerEvent.decode(frame)
        } catch {
            return fail(error.localizedDescription)
        }
        switch event {
        case .sessionUpdated:
            settleHandshake(.success(()))
        case .failure(let failure) where failure.isSessionExpired && phase == .open:
            diagnostics.record("session.expired")
            end(.expired)
        case .failure(let failure) where failure.isCommitEmpty && phase == .open:
            // The answer to a commit of the caller's, which ends nothing (review S6,
            // 2026-10-19): the caller decides what an empty commit means. The loop never
            // commits, so it never sees one.
            onEvent?(event)
        case .failure(let failure):
            diagnostics.record("error.frame", level: .error, fields: [
                "code": failure.code ?? "unnamed",
                "type": failure.type ?? "unnamed",
            ])
            // `server_error` is the service failing, not refusing: a new session may work.
            fail(failure.message + (failure.code.map { " (\($0))" } ?? ""),
                 failure.isAuthorization ? VoiceBackendFailure.authorization
                     : failure.type == "server_error" ? VoiceBackendFailure.network
                     : VoiceBackendFailure.protocolViolation)
        default:
            onEvent?(event)
        }
    }

    // MARK: - Outbound

    /// 03-8, 07-10: a backlog past ``RealtimeDefaults/outboundQueueLimit`` behind a send that
    /// has not returned is a socket that stopped draining. A burst queued before the pump
    /// next runs is not.
    private func yieldOutbound(_ frame: String) {
        queuedBytes += frame.utf8.count
        handedBytes += frame.utf8.count
        guard !sending || queuedBytes <= RealtimeDefaults.outboundQueueLimit else {
            return fail("the outbound queue passed \(RealtimeDefaults.outboundQueueLimit) "
                        + "bytes: the connection is not draining", VoiceBackendFailure.network)
        }
        outboundContinuation.yield(frame)
    }

    private func startPump() {
        let frames = outbound
        pump = Task { @MainActor [weak self] in
            for await frame in frames {
                guard let self, self.phase != .ended else { return }
                self.sending = true
                let bound = self.boundSend()
                do {
                    try await self.transport.send(frame)
                } catch {
                    bound?.cancel()
                    return self.fail(error.localizedDescription, VoiceBackendFailure.network)
                }
                bound?.cancel()
                self.sending = false
                self.queuedBytes -= frame.utf8.count
                self.sentBytes += frame.utf8.count
                if self.queuedBytes == 0 { self.onDrained?() }
            }
        }
    }

    /// The bound on the send just begun, when there is one: a send that has not returned when
    /// it runs out is a socket that stopped draining, and ends the connection as the network
    /// does. Cancelled when the send returns.
    private func boundSend() -> Task<Void, Never>? {
        guard let sendTimeout else { return nil }
        sendSerial += 1
        let serial = sendSerial
        let sleep = self.sleep
        return Task { @MainActor [weak self] in
            await sleep(sendTimeout)
            guard !Task.isCancelled, let self, self.sending, self.sendSerial == serial else { return }
            self.fail("a send did not return within \(String(format: "%g", sendTimeout)) s: the "
                          + "connection is not draining", VoiceBackendFailure.network)
        }
    }

    // MARK: - Endings

    private func settleHandshake(_ result: Result<Void, any Error>) {
        handshakeBound?.cancel()
        handshakeBound = nil
        let waiting = handshake
        handshake = nil
        waiting?.resume(with: result)
    }

    private func end(_ ending: Ending?) {
        guard phase != .ended else { return }
        phase = .ended
        settleHandshake(.failure(VoiceBackendFailure.closed("the session ended during the handshake")))
        outboundContinuation.finish()
        pump?.cancel()
        receiveLoop?.cancel()
        transport.close()
        onEnd?(ending)
    }

    private struct SessionUpdate<Session: Encodable>: Encodable {
        let type = "session.update"
        let session: Session
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
