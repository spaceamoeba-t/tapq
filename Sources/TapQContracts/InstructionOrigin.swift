/// Who put an instruction into the mailbox: the wearer's own dictation, or
/// TapQ's deliberation loop acting on the wearer's behalf.
///
/// This tag exists for exactly one reason, established by the 2026-08-31 M3
/// design review: the 3-in-a-row instruction cap is deliberately stood down
/// in voice sessions (`suppressesLoopCap`), because there every boundary is
/// *supposed* to carry a dictated instruction — but loop-originated
/// instructions must stay capped even there. The cap, the record, and the
/// delivery template all need to know whose sentence it was, so the origin
/// rides the instruction end to end rather than being re-derived at any hop.
///
/// `dictated` is the decode default: a mailbox entry that predates the tag
/// was, by construction, something the wearer said.
public enum InstructionOrigin: String, Sendable, Codable, Equatable {
    /// The wearer spoke this instruction (directly or via free-form intent).
    case dictated
    /// TapQ's deliberation loop composed this instruction autonomously.
    case loop
}
