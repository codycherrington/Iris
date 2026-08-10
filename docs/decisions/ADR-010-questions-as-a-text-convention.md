# ADR-010 — Iris asks questions through a text convention, not a tool

**Date:** 2026-08-09 · **Status:** accepted · **Commit:** `c428a81`

## Context

Cody asked for a UI for when Iris needs a decision from him — the multiple-choice card shape,
rather than a paragraph of "A) … B) … C) …" he has to answer by retyping a letter.

The obvious implementation was to hook Claude Code's own `AskUserQuestion` tool: it already
carries a question, labelled options and a multi-select flag, and rendering its `tool_use` block
natively would have been a few hours' work with no protocol invention at all.

**It isn't available in print mode.** A `claude -p` session reports 67 tools in `system/init`
and `AskUserQuestion` is not among them. Verified against 2.1.226 rather than assumed — the
non-MCP list is:

```
Task, Bash, CronCreate, CronDelete, CronList, DesignSync, Edit, EnterWorktree, ExitWorktree,
ListAgents, ListMcpResourcesTool, LSP, Monitor, NotebookEdit, PushNotification, Read,
ReadMcpResourceDirTool, ReadMcpResourceTool, RemoteTrigger, ReportFindings, ScheduleWakeup,
SendMessage, Skill, TaskCreate, TaskGet, TaskList, TaskOutput, TaskStop, TaskUpdate,
ToolSearch, WebFetch, WebSearch, Write
```

That absence is structural, not an oversight. Interactive prompting is a property of the
interactive TTY: a tool that blocks a turn waiting on a human has nowhere to block in a mode
whose contract is "print the answer and exit". No flag turns it on.

## Decision

**Questions travel inside the assistant's own text, as a fenced block the app extracts and
replaces with real controls. Answers go back as ordinary user turns.**

The convention is taught through `--append-system-prompt`, appended alongside the persona:

````
```iris:question
{"question": "…", "options": [{"label": "…", "description": "…"}], "multiSelect": false}
```
````

`QuestionProtocol.split` returns `(text, question, isPending)` — the message with the block
removed, the parsed question, and whether an opening fence has arrived without its closing one.
That third value exists because the block streams in one delta at a time and half-formed JSON
must not scroll through the transcript.

`AgentQuestion` and `QuestionProtocol` live in **AgentKit**, not the UI target. They are pure
parsing, and the Iris target is `@MainActor` SwiftUI that the test target cannot import —
SwiftPM won't make an executable target a test dependency. Putting them in the package is what
makes the 8 tests possible.

## Alternatives considered

**Hook `AskUserQuestion`.** Rejected on availability, not preference. If a future CLI exposes it
to print mode, this ADR should be revisited — a real tool call is strictly better than a
cooperative convention.

**A local MCP server exposing an ask-the-user tool.** Would give a genuine tool call the model
could invoke. Rejected as disproportionate: it reintroduces exactly the sidecar process that
ADR-002 chose the CLI-subprocess design to avoid, for one UI affordance. Also unproven — the
same `--permission-prompt-tool` mechanism the plan flags as Phase 5's least-verified piece.

**Heuristically parse markdown option lists** (`A) …`, `- [ ] …`, numbered lists). Rejected. It
guesses, and it guesses on ordinary prose — every numbered list in an answer becomes a candidate
question. A convention the model opts into is unambiguous; a heuristic applied to text that
wasn't meant as a question is a permanent source of false positives.

**Answer over a side channel** rather than as a user turn. Rejected: the transcript would no
longer contain the answer, so reopening or resuming the session would show a question with no
reply. Sending the label as a normal message keeps the conversation literally true.

## Consequences

- **Cooperative, not enforced.** If the model writes prose instead, nothing breaks — the question
  renders as text and Cody types an answer, exactly as before. The failure mode is the old
  behaviour, which is the right floor for an opt-in protocol.
- **Malformed payloads stay visible.** A block that fails to decode is deliberately left in the
  rendered text rather than swallowed. A question that silently vanishes is far worse to diagnose
  than one that renders as ugly JSON.
- **The prompt is load-bearing and untestable from here.** `testSystemPromptTeachesTheFenceThe
  ParserLooksFor` pins that the prompt and parser agree on the fence string, but nothing can pin
  that the model *obeys*. Behaviour was verified once against a live session (the captured
  response is the test fixture) and could drift with any model change.
- **Prompt discipline matters more than the parser.** The instructions deliberately narrow when to
  use it — 2–4 options, real decision points only, never rhetorical questions. A model that
  reaches for a picker every turn is worse than one that never does: the card's value is that it
  *means* something, and that signal dies if it fires constantly.
- **The prompt tells the model not to offer an "other" option.** The composer is always right
  there, so a synthesized escape hatch would be a worse version of the thing already on screen.
- Old questions go inert once the conversation moves on (`isAnswerable` is true only for the last
  message while idle). Clicking a question from ten turns ago would answer a turn that no longer
  exists.

## Postscript: the bug this shape exposed

`AgentQuestion` decodes by hand rather than by synthesis, because **Swift's synthesized
`Decodable` ignores default values** — a payload omitting `multiSelect` threw, and the question
vanished with no visible reason. Caught by a test written for the optional-field case, not by
luck. See `ADR-003` for the same permissive-decoding principle applied to the wire protocol; this
is that rule reaching a second decoder.
