import Foundation
import TapQContracts
import TapQKernel

/// The model both text calls use unless the environment names another (ratified
/// 2026-08-28; research §5.2).
let defaultTextModel = "gpt-5.6-luna"

/// `environment[key]` when set and non-blank, else ``defaultTextModel``.
func resolvedTextModel(_ key: String, in environment: [String: String]) -> String {
    let override = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return override.isEmpty ? defaultTextModel : override
}

/// A `/v1/responses` body. `store: false` is D3: nothing the user said is retained server-side.
struct ResponsesRequest: Encodable {
    struct Reasoning: Encodable {
        let effort = "none"
    }

    struct Text: Encodable {
        struct Format: Encodable {
            let type = "json_schema"
            let name: String
            let strict = true
            let schema: JSONValue
        }

        let verbosity = "low"
        let format: Format
    }

    let model: String
    let instructions: String
    let input: String
    let reasoning = Reasoning()
    /// Nil asks for plain text.
    let text: Text?
    let maxOutputTokens: Int
    let promptCacheKey: String?
    let store = false

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, reasoning, text, store
        case maxOutputTokens = "max_output_tokens"
        case promptCacheKey = "prompt_cache_key"
    }

    /// Strings and a parsed schema cannot fail to encode.
    func encoded() -> Data {
        try! KernelJSON.encoder().encode(self)
    }
}
