import Foundation

/// When TapQ summarizes a reply before reading it out, and how long the summary may be.
///
/// A reply is what a coding agent or a desktop chat app sent back, complete. TapQ never tells
/// either of them how to answer and never cuts or rewrites what they wrote:
///
/// - A reply of at most ``characters`` is read exactly as written.
/// - A longer one goes, whole, to TapQ's own summary model, which is told ``promptRule``. Its
///   summary is spoken as it returns, followed by ``offer(chinese:)``, and "read it all" reads
///   the original reply in full.
///
/// The budget counts characters of the reply. It is never an estimate of how long the reply
/// takes to say.
public enum SpokenBudget {
    /// The longest reply read out as written, and the longest summary TapQ's model is asked
    /// for: about two short sentences. The maintainer's figure (2026-09-15, restated
    /// 2026-09-24).
    public static let characters = 120

    /// Whether `reply` is longer than `limit`, and so is summarized rather than read.
    public static func exceeds(_ reply: String, limit: Int = characters) -> Bool {
        reply.count > limit
    }

    /// The length rule as given to TapQ's own models — the summary model, and the models that
    /// write TapQ's own answers. Never to the agent or the chat app.
    public static let promptRule = """
        Keep what you say to at most \(characters) characters, about two short sentences. \
        The listener cannot see a screen or skim. Lead with what they most need to know. If \
        there is more worth hearing, leave it out: TapQ keeps the rest and reads it out when \
        they ask.
        """

    /// The sentence that tells the user the whole reply can be heard, in the summary's
    /// language. A phrase to say rather than a description of one, because the user repeats
    /// what they heard.
    public static func offer(chinese: Bool) -> String {
        chinese ? "想听完整内容，就说“全部读出来”。" : "Say \"read it all\" for the rest."
    }

    /// `summary` followed by the offer in its language, with a space between them only where
    /// the script uses one.
    public static func withOffer(_ summary: String) -> String {
        let offer = offer(chinese: isChinese(summary))
        guard let last = summary.last, let first = offer.first else { return summary + offer }
        return isWide(last) || isWide(first) ? summary + offer : summary + " " + offer
    }

    /// Whether `text` reads as Chinese: more Han characters than Latin words. It picks the
    /// offer's language and does nothing to the text.
    public static func isChinese(_ text: String) -> Bool {
        var han = 0
        var latinWords = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
                han += 1
                inLatinWord = false
            case 0x41...0x5A, 0x61...0x7A:
                if !inLatinWord { latinWords += 1 }
                inLatinWord = true
            default:
                inLatinWord = false
            }
        }
        return han > latinWords
    }

    /// A character written without spaces around it: Han, and the full-width punctuation that
    /// goes with it.
    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
                 0xFF00...0xFFEF, 0x20000...0x2A6DF:
                return true
            default:
                return false
            }
        }
    }
}
