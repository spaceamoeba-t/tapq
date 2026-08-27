import Foundation

/// Whose voice TapQ is willing to take an *instruction* from.
///
/// The name is deliberately narrow. This setting says nothing about approvals: an
/// instruction is text entering an agent's session, an approval authorizes an action, and
/// the two have never shared a policy. Under either value the approval grammar, the
/// approval read-backs, and the fail-open-to-screen semantics are exactly what they were.
///
/// - ``wearer`` is the default and reproduces today's behavior byte for byte. Dictation is
///   fail-closed on IMU wearer attribution, so a voice TapQ cannot prove is the wearer's —
///   including one where the signal cannot answer at all — is refused out loud.
/// - ``environment`` trades that proof for a stated assumption: with no earbuds in, the
///   microphone is in a quiet, single-person room and whoever it hears is the user. The
///   read-back confirmation stays, because it catches mis-transcription and not just
///   misattribution, and it is the only thing between a stray sentence and an agent's inbox.
///
/// The honest cost of ``environment``, which the docs state in the same words: anyone
/// audible to the microphone can *instruct* — and still cannot approve, deny, select, or
/// defer anything the wearer would not have.
public enum VoiceTrust: String, Sendable, Codable, Equatable, CaseIterable {
    /// Instructions require IMU wearer attribution. The default.
    case wearer
    /// The microphone is trusted as the user; the attribution check is skipped and the
    /// bypass is recorded as `instruction.trusted_environment`.
    case environment
}
