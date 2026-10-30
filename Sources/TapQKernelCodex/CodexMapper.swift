import Foundation
import TapQContracts
import TapQKernel

/// A server request TapQ has passed to the kernel and not yet answered.
struct OpenRequest: Equatable {
    enum Kind: Equatable {
        /// `item/commandExecution/requestApproval` or `item/fileChange/requestApproval`,
        /// answered `{decision}`.
        case decision(offersSession: Bool)
        /// `item/permissions/requestApproval`: allow echoes `granted`, deny grants nothing.
        case permissions(granted: [String: JSONValue])
        /// `item/tool/requestUserInput`. `asked` went to the kernel in order; `secret` are
        /// answered empty and never read aloud.
        case question(asked: [String], secret: [String])
    }

    /// The JSON-RPC id, as `PermissionRequest.id` and `QuestionRequest.id` carry it.
    let key: String
    /// The same id as the server sent it, for the reply.
    let id: JSONValue
    let kind: Kind
}

/// Codex's app-server vocabulary in TapQ's terms. Pure: the delegate owns the state and the
/// channel.
enum CodexMapper {
    enum Mapped: Equatable {
        /// Ask the user; the reply waits for `resolve`.
        case ask(OpenRequest, DelegateEvent)
        /// Answered at once, without the user, who is told `spoken`. `diagnostic` names the
        /// line to record.
        case answer(String, diagnostic: String, spoken: String)
        /// No such request in TapQ's vocabulary: JSON-RPC -32601.
        case unhandled
        case violation(String)
    }

    /// §7.2: a secret is never read aloud; the user types it in Codex.
    static let secretNotice = "Codex asked for a secret; type it in Codex."

    /// §7.2: the same notice as Claude's declined elicitation.
    static func elicitationNotice(server: String?) -> String {
        let name = server.map { "\($0) server" } ?? "MCP server"
        return "\(AgentID.codex.displayName)'s \(name) asked for input; I declined."
    }

    static func key(_ id: JSONValue) -> String {
        id.stringValue ?? JSONText.serialize(id)
    }

    /// `items`: every item this turn has started, by id; a file change's paths live there.
    static func serverRequest(id: JSONValue, method: String, params: JSONValue,
                              items: [String: JSONValue]) -> Mapped {
        let key = key(id)
        let reason = params["reason"]?.stringValue
        let step = params["itemId"]?.stringValue
        switch method {
        case "item/commandExecution/requestApproval":
            // A managed-network prompt is about a host, not a command, and cannot be
            // accepted for the session (research §1.10).
            let network = params["networkApprovalContext"].flatMap { $0 == .null ? nil : $0 }
            let offered = params["availableDecisions"]?.arrayValue
                .map { $0.contains(.string("acceptForSession")) } ?? true
            let offersSession = network == nil && offered
            let request = PermissionRequest(
                id: key, tool: "commandExecution", inputJSON: JSONText.serialize(params),
                command: params["command"]?.stringValue.map(spokenCommand),
                title: network.map { "network access to \($0["host"]?.stringValue ?? "a host")" },
                reason: reason, alwaysAllow: offersSession ? sessionOffer : nil, step: step)
            return .ask(OpenRequest(key: key, id: id, kind: .decision(offersSession: offersSession)),
                        .permission(request))
        case "item/fileChange/requestApproval":
            // The approval carries no diff; the item that started before it does. Nothing
            // promises that order (0.161.0 sends the approval straight from the patch event),
            // so without the item TapQ asks with what the approval itself says.
            guard var input = params.objectValue else {
                return .violation("item/fileChange/requestApproval without params")
            }
            let request: PermissionRequest
            if let changes = changes(params, items) {
                input["changes"] = .array(changes)
                request = PermissionRequest(
                    id: key, tool: "fileChange", inputJSON: JSONText.serialize(.object(input)),
                    paths: changes.compactMap { $0["path"]?.stringValue },
                    reason: reason, alwaysAllow: sessionOffer, step: step)
            } else {
                let root = params["grantRoot"]?.stringValue
                request = PermissionRequest(
                    id: key, tool: "fileChange", inputJSON: "{}",
                    title: root.map { "write access under \($0)" } ?? "changes to files it has not named",
                    reason: reason, alwaysAllow: sessionOffer, step: step)
            }
            return .ask(OpenRequest(key: key, id: id, kind: .decision(offersSession: true)),
                        .permission(request))
        case "item/permissions/requestApproval":
            guard let requested = params["permissions"]?.objectValue else {
                return .violation("item/permissions/requestApproval without permissions")
            }
            // `GrantedPermissionProfile`'s members are optional and nullable; nulls are dropped.
            let granted = requested.filter { $0.value != .null }
            let request = PermissionRequest(
                id: key, tool: "permissions", inputJSON: JSONText.serialize(params),
                title: summary(of: granted), reason: reason,
                alwaysAllow: AlwaysAllowOffer(description: "grant it for the rest of this Codex session",
                                              payloadJSON: #""session""#))
            return .ask(OpenRequest(key: key, id: id, kind: .permissions(granted: granted)),
                        .permission(request))
        case "item/tool/requestUserInput":
            guard let questions = params["questions"]?.arrayValue,
                  questions.allSatisfy({ $0["id"]?.stringValue != nil && $0["question"]?.stringValue != nil })
            else { return .violation("item/tool/requestUserInput without well-formed questions") }
            let secret = questions.filter { $0["isSecret"]?.boolValue == true }.compactMap { $0["id"]?.stringValue }
            let asked = questions.filter { $0["isSecret"]?.boolValue != true }.map(question)
            if asked.isEmpty {
                return .answer(answers(asked: [], secret: secret, []),
                               diagnostic: "codex.secret_question", spoken: secretNotice)
            }
            return .ask(OpenRequest(key: key, id: id, kind: .question(asked: asked.map(\.key), secret: secret)),
                        .question(QuestionRequest(id: key, questions: asked)))
        case "mcpServer/elicitation/request":
            return .answer(#"{"action":"decline","content":null,"_meta":null}"#,
                           diagnostic: "codex.elicitation_declined",
                           spoken: elicitationNotice(server: params["serverName"]?.stringValue))
        default:
            return .unhandled
        }
    }

    /// The reply body for a permission, or nil when `kind` is a question.
    static func reply(_ kind: OpenRequest.Kind, _ decision: PermissionDecision) -> String? {
        switch (kind, decision) {
        case (.decision(let offersSession), .allow(let always)):
            return #"{"decision":"\#(always && offersSession ? "acceptForSession" : "accept")"}"#
        case (.decision, .deny):
            return #"{"decision":"decline"}"#
        case (.permissions(let granted), .allow(let always)):
            return JSONText.object([("permissions", JSONText.serialize(.object(granted))),
                                         ("scope", always ? #""session""# : #""turn""#)])
        case (.permissions, .deny):
            return #"{"permissions":{},"scope":"turn"}"#
        case (.question, _):
            return nil
        }
    }

    /// `{answers:{<id>:{answers:[…]}}}`; secret questions get `[]`.
    static func answers(asked: [String], secret: [String], _ answers: [[String]]) -> String {
        let pairs = zip(asked, answers).map { ($0, $1) } + secret.map { ($0, [String]()) }
        return JSONText.object([("answers", JSONText.object(pairs.map { id, values in
            (id, JSONText.object([("answers", JSONText.array(values.map(JSONText.quoted)))]))
        }))])
    }

    /// `item/started` → the step line for status: "running <command>" / "editing <paths>". A
    /// command whose `commandActions` Codex parsed is named the way Codex's own screen names it
    /// instead ("reading README.md", 2026-10-15).
    static func progress(_ item: JSONValue) -> String? {
        switch item["type"]?.stringValue {
        case "commandExecution":
            if let line = item["commandActions"]?.arrayValue.flatMap(parsedActions) { return line }
            return item["command"]?.stringValue.map { "running \(spokenCommand($0))" }
        case "fileChange":
            let paths = item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
            return paths.isEmpty ? nil : "editing " + paths.joined(separator: ", ")
        default:
            return nil
        }
    }

    /// `item/completed` → how the step ended: its `status` (`completed`, `failed`, `declined`);
    /// a command that completed with a non-zero `exitCode` failed, as Codex's screen marks it.
    /// Nil while it is still `inProgress`.
    static func outcome(_ item: JSONValue) -> StepOutcome? {
        switch item["status"]?.stringValue {
        case "inProgress": return nil
        case "failed": return .failed
        case "declined": return .declined
        default:
            if let exitCode = item["exitCode"]?.intValue, exitCode != 0 { return .failed }
            return .done
        }
    }

    /// A command's parsed actions as Codex's TUI shows them (`exec_cell/render.rs`): adjacent
    /// reads merged ("reading a.swift, b.swift"), "listing <path>", "searching for <query> in
    /// <path>". The same phrase twice in a row is said once: live, `ls; ls -la` was "listing
    /// files, then listing files" (2026-10-15). Nil when there are none or any is `unknown`:
    /// the TUI shows that command whole.
    static func parsedActions(_ actions: [JSONValue]) -> String? {
        guard !actions.isEmpty else { return nil }
        var parts: [String] = []
        var reads: [String] = []
        for action in actions {
            let field = { (key: String) in action[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
            let path = field("path")
            if action["type"]?.stringValue == "read" {
                guard let name = field("name") ?? path else { return nil }
                if !reads.contains(name) { reads.append(name) }
                continue
            }
            if !reads.isEmpty { parts.append("reading " + reads.joined(separator: ", ")); reads = [] }
            switch (action["type"]?.stringValue, field("query"), path) {
            case ("listFiles", _, let path): parts.append(path.map { "listing \($0)" } ?? "listing files")
            case ("search", let query?, let path?): parts.append("searching for \(query) in \(path)")
            case ("search", let query?, nil): parts.append("searching for \(query)")
            case ("search", nil, let path?): parts.append("searching \(path)")
            case ("search", nil, nil): parts.append("searching")
            default: return nil
            }
        }
        if !reads.isEmpty { parts.append("reading " + reads.joined(separator: ", ")) }
        return parts.enumerated().filter { $0.offset == 0 || parts[$0.offset - 1] != $0.element }
            .map(\.element).joined(separator: ", then ")
    }

    /// The command as TapQ reads it. Codex 0.161.0 runs a command as `/bin/bash -lc '<command>'`
    /// (live 2026-10-11), or as `/bin/bash -lc "<command>"` when the command holds a `'` (live
    /// 2026-10-12), and that wrapper is read as the command inside it: the reading is shorter,
    /// and the words that matter are what is described. Only those exact forms, with nothing
    /// inside that the quotes would change: no `'` in single quotes (Codex writes one as
    /// `'\''`), and none of `" \ $` or a backquote in double quotes, where the shell would
    /// unescape or expand them. Anything else is read whole. The request's `inputJSON` keeps
    /// the command as Codex sent it.
    static func spokenCommand(_ command: String) -> String {
        for (quote, special) in [("'", "'"), ("\"", "\"\\$`")] {
            let prefix = "/bin/bash -lc " + quote
            guard command.hasPrefix(prefix), command.hasSuffix(quote), command.count > prefix.count + 1 else {
                continue
            }
            let inner = command.dropFirst(prefix.count).dropLast()
            guard !inner.contains(where: special.contains), !inner.allSatisfy(\.isWhitespace) else {
                return command
            }
            return String(inner)
        }
        return command
    }

    /// `turn/completed` → the terminal event. `lastText`: the last agentMessage completed in it.
    static func terminal(_ turn: JSONValue, lastText: String?) -> DelegateEvent {
        switch turn["status"]?.stringValue {
        case "completed": return .finished(text: lastText ?? "")
        case "interrupted": return .stopped
        case "failed": return .failed(reason: turn["error"]?["message"]?.stringValue ?? "no error message")
        case let status: return .violation("turn/completed with status \(status ?? "missing")")
        }
    }

    /// The changes of the file-change item an approval names, when that item has started.
    static func changes(_ params: JSONValue, _ items: [String: JSONValue]) -> [JSONValue]? {
        params["itemId"]?.stringValue.flatMap { items[$0]?["changes"]?.arrayValue }
    }

    /// How an error answering `turn/steer` or `turn/interrupt` says the turn TapQ named is not
    /// the live one. Both are JSON-RPC -32600 (`invalid_request`; seen live on 0.161.0).
    enum TurnRace: Equatable {
        /// "no active turn to steer" / "no active turn to interrupt": `turn/completed` crossed it.
        case noActiveTurn
        /// "expected active turn id A but found B": another turn is live, B when it is named.
        case otherTurn(String?)
    }

    /// nil = a refusal of a live turn (`activeTurnNotSteerable` among them), not a race.
    static func race(code: Int, message: String, info: String?) -> TurnRace? {
        guard code == -32600, info != "activeTurnNotSteerable" else { return nil }
        let lowered = message.lowercased()
        if lowered.hasPrefix("no active turn") { return .noActiveTurn }
        guard lowered.hasPrefix("expected active turn id") else { return nil }
        guard let range = message.range(of: "but found ") else { return .otherTurn(nil) }
        let found = message[range.upperBound...].prefix { !$0.isWhitespace }
        return .otherTurn(found.isEmpty ? nil : String(found))
    }

    /// D2: the thread must run with exactly what TapQ asked for. The response's `sandbox` is
    /// a `SandboxPolicy` object, not the `SandboxMode` string sent.
    static func policyMismatch(_ response: JSONValue, reviewer: CodexApprovalsReviewer = .user) -> String? {
        let echoed = [response["approvalPolicy"], response["approvalsReviewer"], response["sandbox"]?["type"]]
        guard echoed != [.string("on-request"), .string(reviewer.rawValue), .string("workspaceWrite")] else {
            return nil
        }
        return "Codex did not apply TapQ's approval policy (on-request, \(reviewer.rawValue), workspaceWrite); "
            + "it reported " + echoed.map { $0.map(JSONText.serialize) ?? "nothing" }.joined(separator: ", ")
    }

    /// `--auto-mode`: Codex's reviewer turned a request down on the user's behalf.
    static let autoReviewDenied = "Codex's auto-review blocked one of its actions."

    /// `guardianWarning`: Codex's own "concise warning message for the user".
    static func guardianWarning(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Codex warns: " + text + (text.last.map { ".?!".contains($0) } == true ? "" : ".")
    }

    private static let sessionOffer = AlwaysAllowOffer(
        description: "allow it for the rest of this Codex session", payloadJSON: #""acceptForSession""#)

    private static func question(_ raw: JSONValue) -> Question {
        Question(key: raw["id"]?.stringValue ?? "", header: raw["header"]?.stringValue,
                 text: raw["question"]?.stringValue ?? "",
                 options: (raw["options"]?.arrayValue ?? []).compactMap { option in
                     option["label"]?.stringValue.map {
                         QuestionOption(label: $0, description: option["description"]?.stringValue)
                     }
                 },
                 multiSelect: false, allowsFreeText: raw["isOther"]?.boolValue == true)
    }

    /// The requested profile, field by field: "network access; read /a; write /b".
    private static func summary(of profile: [String: JSONValue]) -> String? {
        var parts: [String] = []
        if profile["network"]?["enabled"]?.boolValue == true { parts.append("network access") }
        let fileSystem = profile["fileSystem"]
        for access in ["read", "write"] {
            let paths = fileSystem?[access]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !paths.isEmpty { parts.append("\(access) " + paths.joined(separator: ", ")) }
        }
        if let entries = fileSystem?["entries"]?.arrayValue, !entries.isEmpty {
            parts.append("\(entries.count) file system entries")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
