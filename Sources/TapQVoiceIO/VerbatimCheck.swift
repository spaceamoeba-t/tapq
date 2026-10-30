import Foundation

/// Whether the voice said what it was given: every token of the input, in
/// order, in the session's own transcript of what it spoke, with nothing but filler between.
///
/// Both texts are case-folded and split into runs of letters and digits, each of
/// ``requiredSymbols`` is a token of its own, and number words become digits (``digits(_:)``).
/// An input word matches one or more consecutive transcript tokens joined: "rm" read as
/// "r m", "8080" as "eighty eighty". A required symbol matches itself or one of its spoken
/// names. Every transcript token left over must be one of ``fillers``: a missing, reordered
/// or inserted word makes the reading not verbatim.
public enum VerbatimCheck {
    /// Symbols a reading must voice, with their spoken names.
    static let requiredSymbols: [Character: [[String]]] = [
        "~": [["tilde"], ["home"]],
        "/": [["slash"]],
        "*": [["star"], ["asterisk"]],
        "|": [["pipe"]],
        ">": [["greater", "than"]],
        "<": [["less", "than"]],
        ";": [["semicolon"]],
        "&": [["and"], ["ampersand"]],
        "$": [["dollar"]],
    ]

    /// The words a reading may insert: spoken punctuation ("point" for the dot of a version,
    /// "two point one"; "single quote", "double dash", live 2026-10-11), and the required
    /// symbols and their names.
    static let fillers: Set<String> = Set([
        "dash", "minus", "dot", "point", "period", "slash", "backslash", "colon", "underscore",
        "at", "hash", "percent", "plus", "equals", "comma", "quote", "space", "and",
        "single", "double",
    ]).union(requiredSymbols.keys.map(String.init))
        .union(requiredSymbols.values.joined().joined())

    static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000]

    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
                continue
            }
            if !word.isEmpty { tokens.append(word) }
            word = ""
            if requiredSymbols[character] != nil { tokens.append(String(character)) }
        }
        if !word.isEmpty { tokens.append(word) }
        return digits(tokens)
    }

    public static func isVerbatim(input: String, heard: String) -> Bool {
        let heard = tokens(heard)
        var position = 0
        for token in spoken(tokens(input)) {
            while true {
                guard position < heard.count else { return false }
                if let end = match(token, in: heard, at: position) {
                    position = end
                    break
                }
                guard fillers.contains(heard[position]) else { return false }
                position += 1
            }
        }
        return heard[position...].allSatisfy(fillers.contains)
    }

    /// The input as a voice says it: `&&` is one "and" (live, "git status && ls" was read
    /// "git status and ls"). Other doubled symbols stay two: `>>` is not `>`.
    static func spoken(_ tokens: [String]) -> [String] {
        var result: [String] = []
        for token in tokens where !(token == "&" && result.last == "&") {
            result.append(token)
        }
        return result
    }

    /// Where `token` ends if it is said at `start`: a required symbol as itself or one of its
    /// names, any other token as one or more consecutive transcript tokens joined.
    static func match(_ token: String, in heard: [String], at start: Int) -> Int? {
        if token.count == 1, let names = token.first.flatMap({ requiredSymbols[$0] }) {
            let said = ([[token]] + names).first { heard[start...].starts(with: $0) }
            return said.map { start + $0.count }
        }
        var joined = ""
        for index in start..<heard.count {
            joined += heard[index]
            if joined == token { return index + 1 }
            guard token.hasPrefix(joined) else { return nil }
        }
        return nil
    }

    /// Number words as digit strings, one per spoken group: "forty" is "40", "twenty six"
    /// "26", "three thousand" "3000", and "eighty eighty" the two groups "80" "80".
    static func digits(_ words: [String]) -> [String] {
        enum Kind { case small, tens, hundred, scale }
        var result: [String] = []
        var total = 0
        var part = 0
        var last: Kind?
        func close() {
            if last != nil { result.append(String(total + part)) }
            total = 0
            part = 0
            last = nil
        }
        for word in words {
            if let value = smallNumbers[word] {
                let joins = last == .hundred || last == .scale
                    || (last == .tens && value < 10 && part % 10 == 0)
                if !joins { close() }
                part += value
                last = .small
            } else if let value = tens[word] {
                if last != .hundred && last != .scale { close() }
                part += value
                last = .tens
            } else if word == "hundred" {
                if last == .small {
                    part *= 100
                } else {
                    close()
                    part = 100
                }
                last = .hundred
            } else if let value = scales[word] {
                if last == nil || last == .scale {
                    close()
                    total = value
                } else {
                    total += part * value
                    part = 0
                }
                last = .scale
            } else {
                close()
                result.append(word)
            }
        }
        close()
        return result
    }
}
