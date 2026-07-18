import TapQContracts

/// Deterministic, hardware-independent keyword grammar for short voice commands.
/// Speech-to-text acquisition remains the responsibility of a platform adapter.
public enum VoiceCommandMatcher {
    public static func match(_ raw: String) -> VoiceCommand? {
        let text = raw.lowercased()
        let tokens = Set(text.split { !$0.isLetter }.map(String.init))
        func token(_ words: String...) -> Bool { words.contains { tokens.contains($0) } }
        func phrase(_ phrases: String...) -> Bool { phrases.contains { text.contains($0) } }

        if token("repeat", "again") || phrase("say again", "one more time") { return .repeatRequest }
        if token("details", "detail", "explain") || phrase("more info", "tell me more") { return .details }
        if token("skip", "later", "unsure") || phrase("ask later", "not sure") { return .skip }
        if token("next") || phrase("next option", "move on") { return .next }
        if token("previous", "back") || phrase("go back", "last one") { return .previous }
        if token("select", "choose", "pick") || phrase("pick this", "this one", "go with this") { return .select }
        if token("one", "first") { return .number(1) }
        if token("two", "second") { return .number(2) }
        if token("three", "third") { return .number(3) }
        if token("four", "fourth") { return .number(4) }
        if token("yes", "yeah", "yep", "yup", "approve", "approved", "sure", "okay", "ok", "confirm")
            || phrase("do it", "go ahead", "go for it") { return .yes }
        if token("no", "nope", "nah", "deny", "denied", "cancel", "stop", "reject")
            || phrase("don't", "do not") { return .no }
        return nil
    }
}
