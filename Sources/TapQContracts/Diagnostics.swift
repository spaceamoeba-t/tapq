import Foundation

/// A deliberately small observability contract for hosts embedding TapQ Open.
///
/// Public modules emit operational facts through this interface without depending on
/// a logging backend, telemetry schema, persistence policy, or product diagnostics.
public struct TapQDiagnosticEvent: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable {
        case debug
        case info
        case warning
        case error
    }

    public let category: String
    public let name: String
    public let level: Level
    public let fields: [String: String]

    public init(category: String, name: String, level: Level = .info,
                fields: [String: String] = [:]) {
        self.category = category
        self.name = name
        self.level = level
        self.fields = fields
    }
}

public protocol TapQDiagnosticSink: Sendable {
    func record(_ event: TapQDiagnosticEvent)
}

/// Default sink used by every public component unless its host injects observability.
public struct NoOpTapQDiagnosticSink: TapQDiagnosticSink {
    public init() {}
    public func record(_ event: TapQDiagnosticEvent) {}
}

/// Convenience wrapper that fixes a component category while keeping the host-owned
/// sink and storage policy outside the open modules.
public struct TapQDiagnosticEmitter: Sendable {
    private let sink: any TapQDiagnosticSink
    public let category: String

    public init(category: String, sink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.category = category
        self.sink = sink
    }

    public func record(_ name: String, level: TapQDiagnosticEvent.Level = .info,
                       fields: [String: String] = [:]) {
        sink.record(.init(category: category, name: name, level: level, fields: fields))
    }
}
