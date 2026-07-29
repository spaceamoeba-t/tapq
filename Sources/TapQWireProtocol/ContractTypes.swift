/// Wire vocabulary that the in-process contracts also need.
///
/// `JSONValue` and `ApprovalSource` are declared in `TapQContracts` so `ApprovalRequest`
/// can carry a tool's arguments and its originating hook event; the module dependency
/// only ever runs wire → contracts. Re-exporting the two declarations — rather than
/// aliasing them, which would make the name ambiguous wherever both modules are
/// imported — keeps `import TapQWireProtocol` alone sufficient for existing consumers.
/// The encodings are the declarations' own, so the bytes on the wire are unchanged.
@_exported import enum TapQContracts.JSONValue
@_exported import enum TapQContracts.ApprovalSource
