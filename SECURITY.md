# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through **Security → Report a
vulnerability** in the project’s GitHub repository. Include affected versions,
impact, reproduction steps, and any suggested mitigation.

If private vulnerability reporting is not available, do not publish sensitive
details in an issue. Email `spaceamoeba_t@gmail.com` and ask to establish a
secure reporting channel before sending sensitive details.

The maintainers will acknowledge a report, investigate it, coordinate a fix when
needed, and agree on disclosure timing with the reporter. Please allow a
reasonable remediation period before public disclosure.

## Supported versions

TapQ has not published its first stable release. Security fixes target the latest
published prerelease and the latest commit on the default branch. Historical releases,
older prereleases, local snapshots, and modified distributions are not guaranteed to
receive fixes.

## What TapQ sends, and where

`tapq-kernel` is a local process. It opens no listening socket of any kind: a host reads its
status lines on standard output and stops it by closing standard input.

- **Microphone audio** streams to OpenAI's Realtime API for transcription for as long as
  `tapq-kernel run` runs. Listening is open, and everything TapQ hears counts as the user's.
- **TapQ's sentences**, including the agents' requests and replies as TapQ reads them, are
  voiced by an output-only OpenAI Realtime session. That session takes no tool calls, and
  nothing it hears can start a response.
- **Text-model calls** go to OpenAI's Responses API: the user's transcribed words with both
  agents' state (routing), a reply over the summary threshold (summaries), the shell command
  in a permission request (its description), the agent's recent steps (status), and
  conversation titles and openings (naming and choosing a conversation).
- Every one of these runs on `TAPQ_OPENAI_API_KEY`, or on the endpoints named by
  `--realtime-endpoint` and `--openai-base-url`. TapQ calls no other service.

## The agents

Claude Code and Codex run as child processes, each in its own process group, in the folder
named by `--workspace`, on their own accounts. They are started without any `TAPQ_*`
variable; Codex also without `OPENAI_API_KEY`, since it authenticates from its own login.
With `--subscription claude`, Claude Code also loses `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN`, and the start is refused unless `claude auth status` reports a
subscription login: TapQ never falls back to a key the user asked it not to use.

## Approvals

- An approval, a denial or an answer counts only for a request the user heard in full, read
  word for word. A request the voice could not read word for word twice is declined, and the
  agent is told to ask in simpler terms.
- A shell command is asked with a text model's description of what it does. The description
  is the model's, and the user approves that description: a hostile or mistaken model can
  misdescribe a command. Use `--permission-mode manual` or keep risky work out of a voice
  session when that matters.
- `bypassPermissions` is refused: it would answer requests inside the CLI, where the user
  never hears them.
- With `--auto-mode`, Claude Code's own classifier and Codex's `auto_review` reviewer
  approve what they judge safe without asking. Off by default.
- Nothing TapQ composes on its own can approve anything.

## Local files

Each folder's state lives in `~/Library/Application Support/TapQ/runtime/kernel/<hash>/`,
created `0700`:

- `journal.jsonl`: what the user said to each agent, verbatim, and what came of it.
- The agents' session ids, so a restart can resume their conversations.
- `diagnostics.log`: lifecycle events, tool names, request ids and paths, and the text of
  the requests the agents made. Debug detail reaches standard error only with `TAPQ_DEBUG=1`.

`tapq-kernel clear --workspace <folder>` deletes the directory. The agents' own transcripts
stay where each agent keeps them.
