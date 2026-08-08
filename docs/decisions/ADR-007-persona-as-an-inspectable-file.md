# ADR-007 — The persona is an inspectable file, and the agent is its second author

**Date:** 2026-08-08
**Status:** Accepted
**Commit:** `6c5a663`

## Context

`docs/plan.md` Phase 4 sets one hard requirement for the persona wizard: the persona must be
**actual config, not a stored string the app ignores**. The acceptance criterion is behavioural
— "verify by asking the agent who it is" — which rules out the common shape where a settings
screen collects preferences that then decorate the UI and never reach the model.

The mechanism for making it real was already available: `AgentConfiguration.appendSystemPrompt`
existed from Phase 1 and maps to the CLI's `--append-system-prompt`, applied at process launch.
The open question was where the persona *lives* between launches, and how visible it is.

The default answer for a Mac app is `UserDefaults`. It is one line of code, it is what the
platform expects, and it is completely opaque — the value ends up in a binary plist under a
hashed bundle identifier, where neither the user nor anything else can meaningfully read it.

## Decision

Persist the persona as pretty-printed, sorted-key JSON at
`~/Library/Application Support/Iris/persona.json`, and treat that file as the artifact — not
as an implementation detail of an in-memory object.

Three things follow from committing to that:

1. **The wizard's final step renders the generated system prompt verbatim on screen.** If the
   persona is real config, the person configuring it should see the exact text that will be
   sent. Showing it is what makes "this is config" legible rather than merely true.
2. **`PersonaStore.reload()` re-reads from disk before the wizard opens.** The file has a
   second author (below), and the launch-time in-memory copy would otherwise silently
   overwrite it on the next save.
3. **Applying a persona restarts the session.** `--append-system-prompt` is a process launch
   argument; there is no way to re-prompt a live process. `SessionModel.applyPersona` stops and
   restarts the bridge, and the UI says so ("Edit persona — restarts the session") rather than
   pretending the change is live.

## The emergent consequence: Iris can rewrite its own identity

This was not designed, and is the most interesting thing about the decision.

Because `persona.json` is a real file at a real path, it sits **within reach of the agent's own
file tools**. Iris has Read, Edit and Write. On 2026-08-08 Cody asked Iris to change its own
persona mid-conversation, and it worked — the agent opened the file, edited it, and the change
was there on the next launch.

That is a genuinely different relationship between an app and its configuration. The persona
isn't a value the app owns and the agent receives; it's a shared document with two authors, one
of whom is the subject. "Make yourself less formal" becomes a thing you can just say.

It also creates a real failure mode, which is what forced `reload()`: any cached copy of a file
the agent can write is a lost-update bug waiting to happen. Every future piece of Iris state
that lands in Application Support inherits this problem.

## Alternatives considered

- **`UserDefaults`.** The platform-default choice, one line of code, and the reason it was
  rejected is precisely that it works: it would have satisfied the letter of "persona reaches
  the model" while making the persona invisible, un-diffable, and unreachable by the agent. The
  self-editing capability above simply would not exist. Opacity was the cost, not the
  convenience.
- **A file inside the repo / working directory.** Rejected — this is machine state, not project
  state, and Iris's repo is in iCloud Drive (ADR-005 covers what iCloud does to files the app
  writes frequently). It would also follow the project switcher around once Phase 4 lands it,
  which is the wrong scope for "who is this assistant".
- **Writing `CLAUDE.md` + `.claude/settings.json` into the target project**, as `docs/plan.md`
  Phase 4 literally specifies. **Deliberately not implemented.** Iris opens in `$HOME` by
  default and its own repo has a carefully written `CLAUDE.md`; either target means a first-run
  wizard silently clobbering a real file the user cares about. The proposed replacement, not yet
  built, is an **opt-in export** that writes a marked block —
  `<!-- iris:persona -->` … `<!-- /iris:persona -->` — so it is idempotent, re-runnable, and
  leaves everything outside the markers untouched. Recorded here as an open deviation from the
  plan rather than quietly dropped.
- **Keeping the running session and injecting the persona per-turn** (prepending it to each
  user message instead of using `--append-system-prompt`). Rejected: it burns context on every
  turn, it is not the same mechanism the CLI treats as a system prompt, and it would make the
  persona a string the app pastes around — exactly the failure mode the phase requirement is
  aimed at. A restart is the honest implementation.

## Consequences

- **The persona is auditable.** `cat ~/Library/Application Support/Iris/persona.json` answers
  "what is this thing actually being told" with no app involvement. That matters more, not
  less, as personas get longer.
- **The agent can be asked to modify itself.** A capability worth keeping in mind for demos and
  for the video — it reads as a much bigger idea than the wizard that produced it.
- **Any cached read of an agent-writable file is a bug.** `reload()` fixes this for the wizard;
  the same discipline is required for every future file Iris keeps in Application Support.
  There is currently no file-watch — the reload happens on wizard open, not on change.
- **Persona changes cost a session restart**, which means losing conversation context. Fine for
  a first-run wizard; increasingly annoying if personas become something users switch between.
  If that becomes a real workflow, the answer is session forking (`--fork-session`, already an
  open question in `docs/research/stream-json-protocol.md`), not a hack to mutate a live
  process.
- **Failure to persist is swallowed deliberately** — it logs via `NSLog` and the app continues
  with the persona applied in memory for the session. A persona that can't be written to disk
  should not stop someone using the app.
- The plan's Phase 4 bullet about `CLAUDE.md` / `.claude/settings.json` is now **partially
  unimplemented by decision**, not by omission. Anyone auditing Phase 4 against the plan should
  read this ADR before filing it as a gap.
