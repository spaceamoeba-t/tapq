import Foundation
import TapQContracts

/// One line from `codex app-server`'s stdout, classified by JSON-RPC shape.
enum CodexInbound: Equatable {
    /// A server → client request. `id` is Codex's `RequestId` (`string | number`), echoed
    /// back verbatim in the reply.
    case request(id: JSONValue, method: String, params: JSONValue)
    /// A response to one of TapQ's requests, whose ids are integers.
    case result(id: Int, JSONValue)
    /// `info`: the `codexErrorInfo` variant in `error.data`, when Codex typed the error.
    case error(id: Int, code: Int, message: String, info: String?)
    case notification(method: String, params: JSONValue)
}

/// The app-server wire: JSON-RPC 2.0 without the `"jsonrpc"` member, one message per line
/// (research §1.1). Every outgoing line is built here by hand in a fixed key order, so a
/// test pins the exact bytes on Codex's stdin.
enum CodexRPCCodec {
    /// nil: not a JSON object, or no JSON-RPC shape TapQ can act on.
    static func decode(_ line: String) -> CodexInbound? {
        guard let message = JSONText.parse(line), message.objectValue != nil else { return nil }
        let params = message["params"] ?? .object([:])
        switch (message["id"], message["method"]?.stringValue) {
        case (let id?, let method?):
            return .request(id: id, method: method, params: params)
        case (nil, let method?):
            return .notification(method: method, params: params)
        case (let id?, nil):
            guard case .number(let raw) = id, let id = Int(exactly: raw) else { return nil }
            if let error = message["error"] {
                guard let code = error["code"]?.intValue else { return nil }
                // A unit variant is a string; one with fields, an object keyed by its name.
                let info = error["data"]?["codexErrorInfo"]
                return .error(id: id, code: code, message: error["message"]?.stringValue ?? "",
                              info: info?.stringValue ?? info?.objectValue?.keys.first)
            }
            return message["result"].map { .result(id: id, $0) }
        default:
            return nil
        }
    }

    static func request(id: Int, method: String, params: String) -> String {
        JSONText.object([("id", String(id)), ("method", JSONText.quoted(method)), ("params", params)])
    }

    static func notification(method: String) -> String {
        JSONText.object([("method", JSONText.quoted(method))])
    }

    static func result(id: JSONValue, _ result: String) -> String {
        JSONText.object([("id", JSONText.serialize(id)), ("result", result)])
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        JSONText.object([("id", JSONText.serialize(id)),
                         ("error", JSONText.object([("code", String(code)), ("message", JSONText.quoted(message))]))])
    }
}
