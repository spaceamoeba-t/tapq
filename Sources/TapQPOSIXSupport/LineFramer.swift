import Foundation

/// Bytes in, whole lines out.
///
/// A pipe read returns whatever happened to be in the buffer, which splits a line across
/// chunks and packs several into one; the Python SDK keeps a `_LineFramer` for the same
/// reason. Bytes that are not yet a whole line are kept for the next read, and a final
/// unterminated line is delivered at EOF.
///
/// Invalid UTF-8 is decoded with replacement characters rather than dropped: a JSON line
/// then fails to parse and is reported, which is what a corrupt line is. Silently losing
/// one would leave a reader waiting forever for a frame that came.
struct LineFramer {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(decode(line))
        }
        return lines
    }

    /// Whatever is left when the pipe closes.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = decode(buffer)
        buffer.removeAll()
        return line
    }

    private func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
