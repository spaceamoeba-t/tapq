import Foundation

/// A minimal, lossless JSON value. Used to carry an agent's arbitrary `tool_input`
/// (whose shape varies per tool) and to edit `settings.json` while preserving every
/// key the user authored.
///
/// It lives in the contracts layer because both the wire messages and the in-process
/// `ApprovalRequest` carry tool input, and `TapQWireProtocol` depends on this module
/// rather than the other way round. `TapQWireProtocol` re-exports it under the same
/// name, so its encoding — and every existing consumer — is unchanged.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self { return Int(exactly: n) ?? Int(n) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

/// JSON as text, written by hand in one deterministic spelling, so the bytes a delegate puts
/// on a CLI's stdin are a property of this code and a test can pin them.
public enum JSONText {
    public static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Compact, keys sorted (`JSONValue` has no source order to keep), and an integral number
    /// without a fractional part: `30000`, not `30000.0`, the spelling a CLI reads back.
    public static func serialize(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                return String(Int64(number))
            }
            return String(number)
        case .string(let string): return quoted(string)
        case .array(let items): return array(items.map(serialize))
        case .object(let members):
            return object(members.keys.sorted().map { ($0, serialize(members[$0] ?? .null)) })
        }
    }

    /// `{"a":<fragment>,"b":<fragment>}` in the order given. The values are raw JSON.
    public static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { quoted($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    /// `[<fragment>,…]`. The items are raw JSON.
    public static func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    /// A string as a JSON string, quotes included.
    public static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
