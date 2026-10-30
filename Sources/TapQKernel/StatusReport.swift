import Foundation

/// One line of the stdout status channel. `lastHeard` is the last utterance, named or routed.
public struct StatusReport: Sendable, Equatable, Codable {
    public struct Pending: Sendable, Equatable, Codable {
        public let id: String
        public let kind: PendingSummary.Kind
        public let prompt: String
        public let inputJSON: String?
        /// The shell command the request runs, whole: the prompt says what it does (ruling
        /// 2026-10-12), this is what runs. Absent for any other request.
        public let command: String?
        /// The prompt has been read to the user word for word: gate condition (b). From then
        /// on a yes, no or answer can count. False again when it is re-asked.
        public let played: Bool
        /// True while the shell command's description is on its way (ruling 2026-10-12): the
        /// prompt is then the command read whole, a fallback not yet asked, so a screen shows
        /// the command alone. Absent otherwise, so every other line is the line of before.
        public let describing: Bool?

        public init(id: String, kind: PendingSummary.Kind, prompt: String, inputJSON: String?,
                    command: String? = nil, played: Bool = false, describing: Bool = false) {
            self.id = id
            self.kind = kind
            self.prompt = prompt
            self.inputJSON = inputJSON
            self.command = command
            self.played = played
            self.describing = describing ? true : nil
        }

        public var isDescribing: Bool { describing == true }

        /// `played`, `command` and `describing` were added after v1's first lines; a line
        /// without them reads as not played, no command, and not being described.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = try container.decode(PendingSummary.Kind.self, forKey: .kind)
            prompt = try container.decode(String.self, forKey: .prompt)
            inputJSON = try container.decodeIfPresent(String.self, forKey: .inputJSON)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            played = try container.decodeIfPresent(Bool.self, forKey: .played) ?? false
            describing = try container.decodeIfPresent(Bool.self, forKey: .describing) == true ? true : nil
        }
    }

    /// How an agent failed while TapQ ran on (ruling 2026-10-12), and what TapQ said of it.
    public struct Failure: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            /// Its process ended on its own.
            case exited
            /// TapQ stopped it: it broke the delegate contract, or could not be reached.
            case lostTrack
            /// It never got going after the user's yes.
            case startFailed
        }

        public let kind: Kind
        /// The sentence TapQ spoke, whole.
        public let sentence: String

        public init(kind: Kind, sentence: String) {
            self.kind = kind
            self.sentence = sentence
        }
    }

    /// The conversations TapQ read out for an agent (2026-10-12), each with the number it was
    /// read with: the only numbers a switch takes.
    public struct Conversations: Sendable, Equatable, Codable {
        public struct Conversation: Sendable, Equatable, Codable {
            public let number: Int
            /// The name as read.
            public let title: String
            /// "today", "yesterday", "on Monday", …
            public let age: String
            /// The one the agent is in.
            public let current: Bool
            /// A process other than TapQ's had it open when TapQ last looked (2026-10-12); absent
            /// otherwise, so a line without it is the line of before.
            public let openElsewhere: Bool?

            public init(number: Int, title: String, age: String, current: Bool, openElsewhere: Bool? = nil) {
                self.number = number
                self.title = title
                self.age = age
                self.current = current
                self.openElsewhere = openElsewhere
            }
        }

        public let read: [Conversation]
        /// Listed but not read yet: "more conversations" reads the next of them.
        public let more: Int

        public init(read: [Conversation], more: Int) {
            self.read = read
            self.more = more
        }
    }

    public struct Agent: Sendable, Equatable, Codable {
        public let agent: AgentID
        public let phase: AgentPhase
        public let progress: String?
        /// Where the step `progress` names is, as the agent reported it (2026-10-19): running,
        /// waiting on the user, or ended. Absent when nothing can tell (the agent gave the step
        /// no id), with no `progress`, and in lines written before it.
        public let progressState: TurnSoFar.State?
        public let heldReply: Bool
        public let pending: [Pending]
        /// Its last failure: set while it is off after one, cleared when it starts again or the
        /// user says no to starting it. Absent otherwise, and in lines written before 2026-10-12.
        public let failure: Failure?
        /// Absent until some of its conversations were read out.
        public let conversations: Conversations?
        /// The held reply itself, whole as the agent wrote it (2026-10-22): what "read it all"
        /// reads, so a screen can show what the voice summarized. Present exactly while
        /// `heldReply`; absent in lines written before.
        public let reply: String?

        public init(agent: AgentID, phase: AgentPhase, progress: String?,
                    progressState: TurnSoFar.State? = nil, heldReply: Bool,
                    pending: [Pending], failure: Failure? = nil, conversations: Conversations? = nil,
                    reply: String? = nil) {
            self.agent = agent
            self.phase = phase
            self.progress = progress
            self.progressState = progressState
            self.heldReply = heldReply
            self.pending = pending
            self.failure = failure
            self.conversations = conversations
            self.reply = reply
        }
    }

    public struct LastHeard: Sendable, Equatable, Codable {
        /// The agent it was for: nil until the intent model has routed it (§4.2), and when it
        /// could not tell.
        public let agent: AgentID?
        public let text: String
        /// The `Intent` case name.
        public let action: String?

        public init(agent: AgentID?, text: String, action: String?) {
            self.agent = agent
            self.text = text
            self.action = action
        }
    }

    public var v = 1
    /// "ready" | "status".
    public var type: String
    public var speaking: Bool
    public var userSpeaking: Bool
    public var versionOverride: Bool
    public var agents: [Agent]
    public var lastHeard: LastHeard?

    /// `versionOverride` is a startup fact; the process's status writer stamps it.
    public init(type: String, speaking: Bool, userSpeaking: Bool, versionOverride: Bool = false,
                agents: [Agent], lastHeard: LastHeard?) {
        self.type = type
        self.speaking = speaking
        self.userSpeaking = userSpeaking
        self.versionOverride = versionOverride
        self.agents = agents
        self.lastHeard = lastHeard
    }
}
