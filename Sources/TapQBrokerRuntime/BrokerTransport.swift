import Foundation

/// A listening transport that exchanges one normalized broker request for one response.
/// Agent adapters and broker policy are intentionally independent of the transport.
public protocol BrokerTransport: AnyObject {
    func start(handler: @escaping @Sendable (Data) async -> Data) throws
    func stop()
}

