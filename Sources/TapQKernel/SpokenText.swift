import Foundation

/// An agent's reply as TapQ speaks it: its markdown syntax dropped, its words kept (decided
/// 2026-10-11, widened 2026-10-12). A code fence line goes with its language label, backticks
/// go, a link or image is its text without its target, and a line's quote markers go. Outside
/// a fenced block, so do heading marks, a list item's bullet, a rule line, and paired emphasis
/// marks (`**`, `__`, `~~`, `*`, `_`) around words. Code keeps every character: a fenced line
/// is read as written, and an inline code span is never taken for emphasis (`__init__.py`).
/// Replies only: a request is TapQ's own sentence.
enum SpokenText {
    /// Whether the reply marks a name the way the agents write one: an inline code span, a
    /// code fence, or a link or image (maintainer, 2026-10-16). Such a reply goes to the
    /// summarizer whatever its length, which says what the names are for instead of reading
    /// them. The agents' own markup only: a bare path in prose is not looked for.
    static func marksNames(_ markdown: String) -> Bool {
        markdown.contains(codeSpan) || markdown.contains(link)
            || markdown.split(separator: "\n").contains { $0.drop(while: { $0 == " " }).hasPrefix("```") }
    }

    /// A backquoted run on one line.
    private static let codeSpan = try! Regex(#"`[^`\n]+`"#)

    static func plain(_ markdown: String) -> String {
        var fenced = false
        var lines: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " }).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            lines.append(fenced ? unquoted(line) : prose(unquoted(line)))
        }
        let text = lines.joined(separator: "\n").replacingOccurrences(of: "`", with: "")
        return text.replacing(link) { $0.output.1 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[text](target)` and `![alt](source)`, on one line.
    private static let link = try! Regex<(Substring, Substring)>(#"!?\[([^\]\n]*)\]\([^)\n]*\)"#)

    /// The line without its leading quote markers (`> `, `>> `, ` > `).
    private static func unquoted(_ line: Substring) -> Substring {
        var rest = line
        while let marker = rest.drop(while: { $0 == " " }).first, marker == ">" {
            rest = rest.drop { $0 == " " }.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return rest
    }

    // MARK: - Prose lines

    /// `---`, `***`, `_ _ _`: nothing to say.
    private static let rule = try! Regex<(Substring, Substring)>(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let heading = try! Regex(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#)
    private static let closingHashes = try! Regex(#"[ \t]+#+[ \t]*$"#)
    private static let bullet = try! Regex<(Substring, Substring)>(#"^([ \t]*)[-*+][ \t]+"#)

    /// One pair of emphasis marks around text that starts and ends with neither a space nor the
    /// mark itself, opened after the line's start, a space or an opening bracket or quote, and
    /// closed before its end, a space, closing punctuation, or a period that ends a sentence.
    /// `a*b*c`, `2 * 3 * 4`, `*.py` and `snake_case_name` are not emphasis.
    private static let emphasis: [Regex<(Substring, Substring, Substring)>] = [
        ("**", "*"), ("__", "_"), ("~~", "~"), ("*", "*"), ("_", "_"),
    ].map { mark, character in
        let open = #"(^|[\s(\["'‘“])"#
        let marks = mark.replacingOccurrences(of: "*", with: #"\*"#)
        let text = #"([^\s\#(character)](?:.*?[^\s\#(character)])?)"#
        let close = #"(?=$|[\s,;:!?)\]"'’”]|\.(?:\s|$))"#
        return try! Regex(open + marks + text + marks + close)
    }

    /// Stands in for an inline code span while emphasis is stripped.
    private static let codeMark: Character = "\u{E000}"

    private static func prose(_ line: Substring) -> Substring {
        if line.wholeMatch(of: rule) != nil { return "" }
        var text = line
        if let match = text.prefixMatch(of: heading) {
            text = text[match.range.upperBound...]
            if let hashes = text.firstMatch(of: closingHashes) { text = text[..<hashes.range.lowerBound] }
        }
        text = text.replacing(bullet, maxReplacements: 1) { $0.output.1 }[...]
        return unemphasized(text)
    }

    /// The emphasis marks dropped from everything outside inline code spans. A backquote with
    /// no partner opens nothing.
    private static func unemphasized(_ line: Substring) -> Substring {
        guard line.contains(where: { "*_~".contains($0) }) else { return line }
        var spans: [Substring] = []
        var masked = ""
        var rest = line
        while let open = rest.firstIndex(of: "`"),
              let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            masked += rest[..<open]
            masked.append(codeMark)
            spans.append(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        masked += rest
        for marks in emphasis {
            masked = masked.replacing(marks) { "\($0.output.1)\($0.output.2)" }
        }
        var spoken = ""
        var next = spans.makeIterator()
        for character in masked {
            if character == codeMark, let span = next.next() { spoken += span } else { spoken.append(character) }
        }
        return spoken[...]
    }
}
