# Troubleshooting

TapQ fails out loud: when the microphone, the voice connection or the journal fails,
`tapq-kernel` stops with exit status 70 and one line on standard error,
`tapq-kernel: fatal in <subsystem>: <reason>`. Nothing restarts on its own. When one agent
fails, that agent stops alone and TapQ says so; the other carries on. Start with the reason
line.

## It refuses to start

- **`TAPQ_OPENAI_API_KEY is not set`**: export the key in the shell that runs
  `tapq-kernel`.
- **`TapQ is already running for this workspace`**: another `tapq-kernel` holds that
  folder. Stop it first; each folder takes one kernel at a time.
- **An agent's version is refused**, such as "Claude Code 2.1.300 is not supported. TapQ
  supports 2.1.260 through 2.1.293.": install a supported version.
  `TAPQ_ALLOW_UNSUPPORTED_AGENT_VERSIONS=1` runs it anyway, with a warning on every start.
- **`'… --version' did not answer within 10 seconds`**: the agent's executable on `PATH`
  is broken, often an npm shim pointing at a removed Node. Run the same command yourself.
- **"Claude Code can't use your subscription"** with `--subscription claude`: sign in with
  the command the line names, or drop the flag. TapQ never falls back to an API key when
  you asked for the subscription.

## An agent "isn't installed"

TapQ finds `claude` and `codex` on the `PATH` of the shell that started it. If an agent works
in another terminal but not here, that shell's profile puts it on `PATH` and this one does
not. Codex also has to be signed in: run `codex login`.

## TapQ sent my words to the wrong agent

TapQ takes every sentence it hears as yours, and a text model decides which agent it is for
from the whole sentence: the name you say, the request you just heard, and who you spoke to
last. Say the agent's name at the start or the end to be sure. When a yes or a no could be
for either agent, TapQ asks which.

"Sorry, I missed that. Please say it again." means the routing call did not complete in
time; nothing was done.

## TapQ says "I'll ask again"

TapQ acts on a yes, a no or an answer only when you said it after TapQ finished reading the
request, and only when the request was read word for word. If you spoke too early, or the
voice changed the wording, TapQ reads it again. If it cannot read a request word for word
twice, it declines it ("I couldn't read Claude Code's request reliably, so I said no.") and
tells the agent to ask in simpler terms.

## TapQ hears other people

Listening is open for the whole run, and everything TapQ hears counts as yours. In a room
with other voices, use a headset or your earbuds' voice isolation.

## TapQ stopped

The subsystem in the reason line names the part that failed:

- **speech-input**: the microphone failed, delivered only silence, or the transcription
  connection dropped. Check the input device in System Settings › Sound, and that your
  terminal app has microphone access under Privacy & Security.
- **speech-output**: the voice connection dropped, or no output device could start.
- **intent**, **summarizer**, **describer**, **progress**, **titler** or **picker**: OpenAI
  refused a text-model call, usually an invalid key or no access to the model.
- **journal**: what TapQ kept for this folder is damaged. Run
  `tapq-kernel clear --workspace <folder>`, then start again.

## Logs

`diagnostics.log` sits in the folder's directory under
`~/Library/Application Support/TapQ/runtime/kernel/`. Warnings and errors also go to
standard error; `TAPQ_DEBUG=1` adds everything else.

## Sharing diagnostics safely

Review logs before sharing them. They contain file paths, tool names, request ids and the
text of requests the agents made. The journal in the same directory holds what you said to
the agents, verbatim: do not attach it to a public issue.
