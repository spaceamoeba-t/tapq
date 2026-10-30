import Foundation
import TapQContracts

/// Values that must travel back to Claude Code unchanged — a tool's `input`, a question
/// list — are cut out of the line they arrived in and spliced, never re-modelled.
extension JSONText {
    /// The value of `key` in the JSON object `text`, exactly as written: same key order, same
    /// spelling. `JSONValue` is a dictionary and keeps neither, so a tool's `input` is cut out
    /// of the line rather than re-serialized; the user hears its fields in the order Claude
    /// wrote them. `text` must already have parsed as JSON.
    static func rawMember(_ key: String, of text: Substring) -> Substring? {
        let bytes = text.utf8
        var index = skipSpace(bytes, from: bytes.startIndex)
        guard index < bytes.endIndex, bytes[index] == UInt8(ascii: "{") else { return nil }
        index = bytes.index(after: index)
        while true {
            index = skipSpace(bytes, from: index)
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let keyEnd = endOfValue(bytes, from: index)
            let name = parse(String(text[index..<keyEnd]))?.stringValue
            index = skipSpace(bytes, from: keyEnd)
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: ":") else { return nil }
            let valueStart = skipSpace(bytes, from: bytes.index(after: index))
            let valueEnd = endOfValue(bytes, from: valueStart)
            if name == key { return text[valueStart..<valueEnd] }
            index = skipSpace(bytes, from: valueEnd)
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: ",") else { return nil }
            index = bytes.index(after: index)
        }
    }

    private static func skipSpace(_ bytes: Substring.UTF8View, from start: String.Index) -> String.Index {
        var index = start
        while index < bytes.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index = bytes.index(after: index)
        }
        return index
    }

    /// Just past the value that starts at `start`: a string, a nested object or array, or a
    /// bare number or literal.
    private static func endOfValue(_ bytes: Substring.UTF8View, from start: String.Index) -> String.Index {
        var index = start
        var depth = 0
        var inString = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            if inString {
                if byte == UInt8(ascii: "\\") {
                    index = bytes.index(after: index)
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                    if depth == 0 { return index }
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth <= 0 { return depth == 0 ? index : bytes.index(before: index) }
            case UInt8(ascii: ","), 0x20, 0x09, 0x0A, 0x0D:
                if depth == 0 { return bytes.index(before: index) }
            default: break
            }
        }
        return index
    }
}
