import Foundation

/// Every sentence TapQ speaks. Exact, and pinned by tests.
///
/// Consent text is built from whole fields and never truncated: the user approves what
/// they heard, so what they hear is everything the agent asked.
enum Sentences {
    static let reask = "I'll ask again."
    static let okay = "Okay."
    static let steered = "Okay, I'll add that."
    static let missed = "Sorry, I missed that. Please say it again."
    static let nothingWaiting = "Nothing is waiting on you."
    /// The feedback and free-text answer an unreadable request is resolved with.
    static let unreadableFeedback =
        "TapQ could not read this request aloud to the user; ask again in simpler terms"

    /// The intent model could not tell which agent a yes, no or answer is for (§4.2): `agents`
    /// are those it may be for, in `AgentID` order.
    static func whichAgent(_ agents: [AgentID]) -> String {
        "For \(list(agents.map(\.displayName)))? Say the name with your answer."
    }

    // MARK: Prompts

    /// Into a conversation TapQ read out (2026-10-12), by the number and name it was read with:
    /// the one start TapQ still asks about (2026-10-24).
    static func switchConversation(_ agent: AgentID, number: Int, title: String) -> String {
        "Switch \(agent.displayName) to \(noun(agent)) \(number): \(unended(title))?"
    }

    // MARK: Starts (2026-10-24)

    /// A first instruction carried on in one of the agent's conversations. `name`: what it is
    /// about, as the picker named it; nil, it is told as the last one or an earlier one.
    static func continuing(_ agent: AgentID, name: String?, last: Bool) -> String {
        let which = name.map(unended) ?? (last ? "its last \(noun(agent))" : "an earlier \(noun(agent))")
        return "Okay, \(agent.displayName) continues \(which)."
    }

    /// A first instruction the picker found starting something new. `lastOpenElsewhere`: the
    /// conversation it was last in is open in another process, so it was not offered.
    static func startingNew(_ agent: AgentID, lastOpenElsewhere: Bool = false) -> String {
        "Okay, \(agent.displayName) starts a new \(noun(agent))."
            + (lastOpenElsewhere ? " Its last one is open elsewhere." : "")
    }

    /// The pick failed: the conversation it was last in is carried on, else a new one started.
    static func pickFailed(_ agent: AgentID, continued: Bool) -> String {
        "I couldn't tell which \(noun(agent)) you meant, so \(agent.displayName) "
            + (continued ? "continues its last one." : "starts a new one.")
    }

    /// Its conversations could not be read for a first instruction.
    static func unreadConversations(_ agent: AgentID) -> String {
        "I couldn't read \(agent.displayName)'s \(noun(agent))s, so it starts a new one."
    }

    /// What the agent calls one of its conversations: a chat's is a chat.
    private static func noun(_ agent: AgentID) -> String {
        agent.kind == .chat ? "chat" : "conversation"
    }

    static func permission(_ agent: AgentID, _ request: PermissionRequest) -> String {
        "\(agent.displayName) wants to \(action(request)).\(reason(request)) Allow it?"
    }

    /// A shell command's request, asked with what the command does (maintainer ruling
    /// 2026-10-12). nil when the description holds no words.
    static func permission(_ agent: AgentID, _ request: PermissionRequest, described: String) -> String? {
        guard let action = describedAction(described, agent: agent) else { return nil }
        return "\(agent.displayName) wants to \(action).\(reason(request)) Allow it?"
    }

    /// A reason that ends a sentence itself ("…outside the sandbox?", live) gets no period.
    private static func reason(_ request: PermissionRequest) -> String {
        nonEmpty(request.reason?.trimmingCharacters(in: .whitespacesAndNewlines)).map {
            " It says: \(ended($0))"
        } ?? ""
    }

    /// The describer's phrase as the middle of "<A> wants to …": one line, no markdown, no
    /// surrounding quotes, no echo of "<A> wants to" or "to", no closing punctuation, and a
    /// capital dropped from a first word that is not an acronym.
    static func describedAction(_ phrase: String, agent: AgentID) -> String? {
        var text = SpokenText.plain(phrase).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        for lead in ["\(agent.displayName) wants to ", "wants to ", "to "]
        where text.lowercased().hasPrefix(lead.lowercased()) {
            text = String(text.dropFirst(lead.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'“”‘’"))
        guard let first = text.first else { return nil }
        if first.isUppercase, text.dropFirst().first?.isLowercase == true {
            text = first.lowercased() + text.dropFirst()
        }
        return text
    }

    static func question(_ agent: AgentID, _ request: QuestionRequest) -> String {
        let questions = request.questions
        if questions.count == 1 { return "\(agent.displayName) asks: \(ask(questions[0]))" }
        let parts = questions.enumerated().map { "\(ordinal($0.offset + 1)): \(ask($0.element))" }
        return "\(agent.displayName) has \(questions.count) questions. "
            + parts.joined(separator: " ")
    }

    /// Otherwise the title, if any, then every top-level input field: what the user
    /// approves is everything the tool will be given.
    private static func action(_ request: PermissionRequest) -> String {
        if let command = request.command { return "run \(command)" }
        if !request.paths.isEmpty { return "edit \(request.paths.joined(separator: " and "))" }
        var scanner = ObjectScanner(bytes: Array(request.inputJSON.utf8))
        let fields = scanner.fields()
        if request.tool == "WebFetch", let url = fields.first(where: { $0.key == "url" }) {
            return "fetch \(url.value)"
        }
        let parts = [nonEmpty(request.title)].compactMap { $0 } + fields.map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? "use \(request.tool)" : "use \(request.tool): " + parts.joined(separator: ", ")
    }

    private static func ask(_ question: Question) -> String {
        guard !question.options.isEmpty else { return question.text }
        let lead = question.multiSelect ? "Pick any of" : "Options"
        return "\(question.text) \(lead): \(list(question.options.map(\.label)))."
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        if items.count == 2 { return "\(items[0]) or \(last)" }
        return items.dropLast().joined(separator: ", ") + ", or " + last
    }

    private static func ordinal(_ n: Int) -> String {
        let words = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n <= words.count ? words[n - 1] : "\(n)"
    }

    // MARK: Acks

    /// A chat agent is installed when `--desktop-chat` names it and its app is on this Mac, or
    /// `--api-chat` names it and TapQ has its key (2026-10-13): what the user can change is the
    /// opt-in, or the key. `appMissing`: a chat the user turned on whose app is not on this Mac.
    /// `keyMissing`: one turned on over the API without its vendor's key. `notOnPlan`: one
    /// `--agents` leaves out, whatever is installed.
    static func notInstalled(_ agent: AgentID, appMissing: Bool = false, keyMissing: Bool = false,
                             notOnPlan: Bool = false) -> String {
        if notOnPlan { return "\(agent.displayName) isn't turned on in TapQ." }
        switch agent.kind {
        case .coding: return "\(agent.displayName) isn't installed on this Mac."
        case .chat where keyMissing:
            return "\(agent.displayName) needs \(agent == .claudeChat ? "an Anthropic" : "an OpenAI") API key in TapQ."
        case .chat where appMissing:
            return "The \(agent == .claudeChat ? "Claude" : "ChatGPT") app isn't installed on this Mac."
        case .chat: return "\(agent.displayName) isn't turned on in TapQ."
        }
    }

    static func unclear(_ agent: AgentID) -> String {
        "I didn't catch what \(agent.displayName) should do. Say it again."
    }

    static func stayingOff(_ agent: AgentID) -> String { "Okay, \(agent.displayName) stays off." }
    /// A no to a switch asked of an agent that runs.
    static func staying(_ agent: AgentID) -> String {
        "Okay, \(agent.displayName) stays in its \(noun(agent))."
    }
    static func stopping(_ agent: AgentID) -> String { "Stopping \(agent.displayName)." }

    static func notWorking(_ agent: AgentID) -> String {
        "\(agent.displayName) isn't working on anything."
    }

    /// Words for a chat agent while it answers: a chat app's answer cannot be steered, so they
    /// are not sent (2026-10-13).
    static func stillAnswering(_ agent: AgentID) -> String {
        let name = agent.displayName
        return "\(name) is still answering. Say it again when it's done, or say: \(name), stop."
    }

    /// Each names the agent, so a yes taken for the wrong one is heard (routing by the model,
    /// 2026-10-12). `askedAlways` without `always`: the user said "don't ask again" to a
    /// request that offered no such rule.
    static func allowed(_ agent: AgentID, always: Bool, askedAlways: Bool = false) -> String {
        let name = agent.displayName
        if always { return "Allowed for \(name), and it won't ask again for that." }
        return askedAlways ? "Allowed for \(name), but it will still ask next time." : "Allowed for \(name)."
    }

    static func denied(_ agent: AgentID, feedback: Bool) -> String {
        feedback ? "Denied, and I told \(agent.displayName) why." : "Denied for \(agent.displayName)."
    }

    static func answered(_ agent: AgentID) -> String { "\(agent.displayName) has your answer." }

    static func unreadable(_ agent: AgentID) -> String {
        "I couldn't read \(agent.displayName)'s request reliably, so I said no."
    }

    static func readAll(_ agent: AgentID, held: String?) -> String {
        guard let held else { return "There's no reply from \(agent.displayName) to read." }
        return "\(agent.displayName) said: \(SpokenText.plain(held))"
    }

    /// `openElsewhere`: the agent's conversations here that a process other than TapQ's has open,
    /// looked up when TapQ's isn't running (2026-10-12), so that "isn't running" is not heard as
    /// "nowhere".
    static func status(_ agent: AgentID, _ state: AgentState, openElsewhere: [OpenSession] = []) -> String {
        let name = agent.displayName
        var sentence: String
        switch state.phase {
        case .idle: sentence = "\(name) is idle."
        case .working:
            // Never the tool line, nor the agent's own words, which can hold a command: they
            // read shell commands aloud (2026-10-15). Said when the agent has shown no work yet;
            // with work, its summary is asked (`progress`), and a failed one is told
            // (`progressFailed`).
            sentence = "\(name) is working."
        case .awaitingYes:
            // A switch asked of an agent that runs leaves it running until the yes.
            if case .launch(let launch)? = state.head?.kind, launch.running {
                sentence = "\(name) is idle."
            } else {
                sentence = notRunning(agent, openElsewhere)
            }
        case .none, .notInstalled: sentence = notRunning(agent, openElsewhere)
        }
        return sentence + waitingOn(state)
    }

    /// The head's prompt, once it can be asked: a shell command's is the command read whole
    /// until its description arrives (2026-10-12), and it is offered on its own then.
    private static func waitingOn(_ state: AgentState) -> String {
        guard let head = state.head, !head.describing else { return "" }
        return " It's waiting on you: \(head.prompt)"
    }

    /// A status summary that failed or said nothing, told out loud as a failed reply summary
    /// is (maintainer, 2026-10-16): never passed off as a status. What it waits on follows.
    static func progressFailed(_ agent: AgentID, _ state: AgentState) -> String {
        "\(agent.displayName) is working, but I couldn't summarize where it is." + waitingOn(state)
    }

    /// A status while the agent works: the progress summarizer's words, which start with the
    /// agent's name (its name is put first when they do not, so the user knows whose it is),
    /// then what it waits on, as `status` says it (2026-10-15). nil for words that read as
    /// nothing once plain, which `progressFailed` answers instead.
    static func progress(_ agent: AgentID, _ summary: String, _ state: AgentState) -> String? {
        let name = agent.displayName
        let words = oneLine(SpokenText.plain(summary))
        guard !words.isEmpty else { return nil }
        var sentence = words.hasPrefix(name) ? words : "\(name): \(words)"
        if !".?!…".contains(sentence.last ?? ".") { sentence += "." }
        return sentence + waitingOn(state)
    }

    /// Paragraphs and line breaks read as one line: each run of whitespace one space.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func notRunning(_ agent: AgentID, _ open: [OpenSession]) -> String {
        let name = agent.displayName
        guard !open.isEmpty else { return "\(name) isn't running." }
        let which = open.count == 1 ? "one of its conversations is" : "\(open.count) of its conversations are"
        let items = open.map { "\(unended(SpokenText.plain($0.title))), \($0.working ? "working" : "idle")" }
        return "\(name) isn't running in TapQ, but \(which) open elsewhere: \(items.joined(separator: "; "))."
    }

    // MARK: Conversations (2026-10-12)

    /// One reading of the list, numbered from `first`: the count and folder before the first
    /// five, and how many are left after any. Never more than the user asked for. `open`: the
    /// numbers of those a process other than TapQ's has open (2026-10-12).
    static func conversations(_ agent: AgentID, folder: String, read: [ConversationChoice], total: Int,
                              left: Int, open: Set<Int> = []) -> String {
        let name = agent.displayName
        let items = read.map { choice in
            let marks = (choice.current ? ", the current one" : "") + (open.contains(choice.number) ? ", open elsewhere" : "")
            return "\(choice.number), \(choice.age)\(marks): \(ended(choice.title))"
        }
        let opening = read.first?.number == 1
            ? ["\(name) has \(total) \(noun(agent))\(total == 1 ? "" : "s") in \(folder)."] : []
        let closing = left == 0
            ? (opening.isEmpty ? ["That's all."] : [])
            : ["There \(left == 1 ? "is 1 more" : "are \(left) more")."]
        return (opening + items + closing).joined(separator: " ")
    }

    /// A chat agent's conversations are its app's, and TapQ does not read them (2026-10-13).
    static func cannotListChats(_ agent: AgentID) -> String {
        "TapQ can't list \(agent.displayName)'s chats yet."
    }

    static func noConversations(_ agent: AgentID, folder: String) -> String {
        "\(agent.displayName) has no \(noun(agent))s in \(folder) yet."
    }

    static func allConversationsRead(_ agent: AgentID) -> String {
        "That's all of \(agent.displayName)'s \(noun(agent))s."
    }

    static func listFailed(_ agent: AgentID, reason: String) -> String {
        "I couldn't list \(agent.displayName)'s \(noun(agent))s: \(ended(SpokenText.plain(reason)))"
    }

    /// `listed`: some of its conversations were read, so the number is one TapQ did not read.
    static func noSuchConversation(_ agent: AgentID, number: Int, listed: Bool) -> String {
        listed ? "I didn't read a \(noun(agent)) \(number) for \(agent.displayName)."
            : "Ask for \(agent.displayName)'s \(noun(agent))s first, then choose one by its number."
    }

    static func alreadyIn(_ agent: AgentID, number: Int) -> String {
        "\(agent.displayName) is already in \(noun(agent)) \(number)."
    }

    /// A switch refused because a process other than TapQ's has that conversation open
    /// (2026-10-12): the two would each go on without the other's turns. `number`: the
    /// conversation as read. A first instruction never meets it: one open elsewhere is not
    /// offered to the picker (2026-10-24).
    static func openElsewhere(_ agent: AgentID, number: Int) -> String {
        let name = agent.displayName
        return "I can't continue \(noun(agent)) \(number) while it's open elsewhere. Close it there and ask again, "
            + "or say: \(name), new conversation."
    }

    static func busy(_ agent: AgentID) -> String {
        "\(agent.displayName) is working. To switch conversations, first say: \(agent.displayName), stop."
    }

    static func switched(_ agent: AgentID, number: Int?) -> String {
        number.map { "\(agent.displayName) is in \(noun(agent)) \($0) now." }
            ?? "\(agent.displayName) is in a new \(noun(agent))."
    }

    /// The agent began work in its conversation while TapQ asked to switch it.
    static func switchWithdrawn(_ agent: AgentID) -> String {
        "\(agent.displayName) started working, so it stays in its \(noun(agent))."
    }

    /// How long ago, as a person says it: "today", "yesterday", "on Monday" within the week,
    /// "on October 3" within the year, "on October 3, 2025" before it.
    static func age(of date: Date, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            formatter.dateFormat = sameYear ? "MMMM d" : "MMMM d, yyyy"
        }
        return "on " + formatter.string(from: date)
    }

    // MARK: Requests and results

    static func withdrew(_ agent: AgentID) -> String { "\(agent.displayName) withdrew that request." }

    /// Replies are spoken as `SpokenText.plain`: their words, not their markdown.
    static func finished(_ agent: AgentID, _ text: String) -> String {
        let spoken = SpokenText.plain(text)
        return spoken.isEmpty ? "\(agent.displayName) is done." : "\(agent.displayName) says: \(spoken)"
    }

    static func summary(_ agent: AgentID, _ summary: String) -> String {
        "\(agent.displayName) says, in short: \(SpokenText.plain(summary))"
    }

    static func summaryFailed(_ agent: AgentID) -> String {
        "\(agent.displayName) is done, but I couldn't summarize the reply. "
            + "Say: \(agent.displayName), read it all."
    }

    static func stopped(_ agent: AgentID) -> String { "\(agent.displayName) stopped." }

    /// The agent's own reason, which may end its sentence itself ("You've hit your usage
    /// limit."). `resumed`: the first turn of a resumed conversation failed, so the way out of a
    /// conversation that is gone is said too, once (2026-10-12).
    static func failed(_ agent: AgentID, reason: String, resumed: Bool = false) -> String {
        "\(agent.displayName) stopped: \(ended(reason.trimmingCharacters(in: .whitespacesAndNewlines)))"
            + (resumed ? startOver(agent) : "")
    }

    /// The way out of a conversation the agent can no longer resume.
    static func startOver(_ agent: AgentID) -> String {
        " If that \(noun(agent)) is gone, say: \(agent.displayName), new conversation."
    }

    /// `text` closed with a period, unless it already ends with ".", "?" or "!".
    static func ended(_ text: String) -> String {
        guard let last = text.last, ".?!".contains(last) else { return text + "." }
        return text
    }

    /// `text` without the punctuation that closes it, for a sentence that goes on.
    static func unended(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!…"))
    }

    /// One per agent whose turn or requests a restart cut off (`openRequests` non-nil), or
    /// whose last reply was never spoken (§4.9). nil = nothing to tell.
    /// `taskDelivered`: the lost turn had reached the agent, which may then take it up again.
    static func resumed(_ agent: AgentID, openRequests: Int?, unheardReply: Bool,
                        taskDelivered: Bool = false, chats: ChatBackend = .app) -> String? {
        let lost = openRequests.map { count in
            switch (agent.kind, chats) {
            case (.chat, .app):
                // A chat's app goes on answering whatever TapQ does: its answer is left, not stopped.
                return "TapQ restarted. \(agent.displayName)'s last answer is left in the app, unread, "
                    + "and nothing was resent."
            case (.chat, .api):
                // The request died with TapQ's process, and the chat keeps no part of that turn.
                return "TapQ restarted. \(agent.displayName)'s unfinished answer stopped, and nothing was resent."
            case (.coding, _):
                break
            }
            let requests = count == 0 ? "" : " and \(count) open request\(count == 1 ? "" : "s")"
            let retake = taskDelivered && agent.mayRetakeLostTask
                ? ", but \(agent.displayName) may take the task up again when it resumes" : ""
            return "TapQ restarted. \(agent.displayName)'s unfinished task\(requests) stopped, "
                + "and nothing was resent\(retake)."
        }
        let parts = [lost, unheardReply ? Self.unheardReply(agent) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One agent failed while TapQ runs on (maintainer ruling 2026-10-12). `openRequests`
    /// non-nil: its task or requests were cut off, as in `resumed`.
    /// `resumed`: it failed resuming a conversation, before it said anything, and the
    /// conversation may be gone from the agent's store (Claude Code deletes old ones), so the way
    /// out is said (2026-10-12).
    static func agentFailed(_ agent: AgentID, _ failure: AgentFailure, openRequests: Int?,
                            taskDelivered: Bool, resumed: Bool = false, chats: ChatBackend = .app) -> String {
        let name = agent.displayName
        let startOver = resumed ? Self.startOver(agent) : ""
        let inApp = agent.kind == .chat && chats == .app
        let what: String
        switch failure {
        case .startFailed(let reason):
            return "\(name) couldn't start: \(ended(SpokenText.plain(reason)))" + startOver
        case .exited:
            what = "\(name) quit unexpectedly."
        case .lostTrack where inApp:
            // TapQ lets go of the app; it never stops or quits it.
            what = "TapQ lost track of \(name), so it let go of the app."
        case .lostTrack:
            what = "TapQ lost track of \(name), so it stopped it."
        }
        let lost = openRequests.map { count in
            if inApp, failure == .lostTrack {
                return " Its last answer is left in the app, unread, and nothing was resent."
            }
            if agent.kind == .chat, chats == .api { return " Its unfinished answer stopped, and nothing was resent." }
            let requests = count == 0 ? "" : " and \(count) open request\(count == 1 ? "" : "s")"
            let retake = taskDelivered && agent.mayRetakeLostTask
                ? ", but \(name) may take the task up again when it resumes" : ""
            return " Its unfinished task\(requests) stopped, and nothing was resent\(retake)."
        } ?? ""
        return what + lost + " Talk to \(name) to start it again." + startOver
    }

    static func unheardReply(_ agent: AgentID) -> String {
        "\(agent.displayName) has a reply; say: \(agent.displayName), read it all."
    }

    // MARK: Helpers

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// The top-level fields of a JSON object as spoken, in input order: `JSONSerialization`
/// loses the order, and the order is how the agent wrote the request.
private struct ObjectScanner {
    let bytes: [UInt8]
    var index = 0

    private static let quote = UInt8(ascii: "\"")

    mutating func fields() -> [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = []
        skipSpace()
        guard take("{") else { return fields }
        while true {
            skipSpace()
            guard let key = string() else { return fields }
            skipSpace()
            guard take(":"), let value = value() else { return fields }
            fields.append((key, value))
            skipSpace()
            guard take(",") else { return fields }
        }
    }

    /// A string unescaped, an array of scalars joined with " and ", anything else as its
    /// JSON text (the delegates pass compact JSON).
    private mutating func value() -> String? {
        skipSpace()
        let start = index
        if peek("\"") { return string() }
        guard take("[") else {
            skipValue()
            return text(from: start)
        }
        var scalars: [String]? = []
        skipSpace()
        if !take("]") {
            repeat {
                skipSpace()
                if peek("{") || peek("[") {
                    scalars = nil
                    skipValue()
                } else {
                    guard let item = value() else { return nil }
                    scalars?.append(item)
                }
                skipSpace()
            } while take(",")
            guard take("]") else { return nil }
        }
        if let scalars, !scalars.isEmpty { return scalars.joined(separator: " and ") }
        return text(from: start)
    }

    private func text(from start: Int) -> String {
        String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func peek(_ byte: Unicode.Scalar) -> Bool {
        index < bytes.count && bytes[index] == UInt8(ascii: byte)
    }

    private mutating func take(_ byte: Unicode.Scalar) -> Bool {
        guard peek(byte) else { return false }
        index += 1
        return true
    }

    private mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    /// A whole string token, unescaped by the JSON parser itself.
    private mutating func string() -> String? {
        guard peek("\"") else { return nil }
        let start = index
        index += 1
        while index < bytes.count, bytes[index] != Self.quote {
            index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard index < bytes.count else { return nil }
        index += 1
        let token = Data(bytes[start..<index])
        return (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed)) as? String
    }

    /// Past one value of any kind, stopping at the `,`, `}` or `]` that ends it.
    private mutating func skipValue() {
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case Self.quote:
                _ = string()
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 { return }
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 0 { return }
            default:
                break
            }
            index += 1
        }
    }
}
