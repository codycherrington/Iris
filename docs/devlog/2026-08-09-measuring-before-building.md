# 2026-08-09 — Measuring before building, and the crash that 35 green tests couldn't see

*One commit: `5d3947b`, "Add OneShotQuery for cost-capped sidebar tool calls." The session
opened with a question about voice, spent its middle measuring something the plan had already
decided, and found out the plan's reasoning was half wrong. Then the runner it produced turned
out to contain a guaranteed crash that the entire test suite was structurally incapable of
detecting.*

## First, a thing that isn't happening

Cody asked whether a third-party lifelike voice mode was feasible. It was researched and then
**deferred** — too compute-heavy for this machine, *"maybe on another computer."* Not a roadmap
item, no phase, no card.

The finding worth keeping is architectural: **realtime speech-to-speech models are the brain,
not a microphone.** OpenAI Realtime, Gemini Live and ElevenLabs Agents each own the whole
conversation loop, so adopting one means *replacing the `claude` CLI* — and with it subscription
auth, skills, hooks, MCP, the persistent bridge. Only a cascaded pipeline (STT → the existing
`send()` → sentence-chunked TTS) leaves Iris's architecture standing. That also rules out
ElevenLabs' official Swift SDK, which is an Agents SDK and owns the LLM. STT itself would be
free and on-device — macOS 26's `SpeechAnalyzer` is right there in the installed SDK, and
published benchmarks put it at 2.12% WER clean / 4.56% noisy against Whisper Small's 3.74% /
7.95%, about 3× faster. TTS is where it falls down: independently measured time-to-first-audio
is 188–288 ms across Cartesia Sonic-3 and ElevenLabs Turbo/Flash v2.5, versus vendor claims of
40–90 ms — usable, but 2–7× the advertised figure, which is worth noting on a day otherwise
spent on the difference between a claimed cost and a measured one. The only local option,
Kokoro-82M at 13–70× realtime on the ANE, is prosodically flat and so misses the "lifelike" bar
outright. (All third-party published numbers; none reproduced here.)

The two hard parts are specific to Iris and would be true of any implementation: the output
stream is full of code blocks and tool calls that must not be read aloud (that needs a separate
*speech view* of the transcript, a second rendering of the event stream rather than a regex over
the visual one), and the ~11 s TTFT that the breathing-name animation covers fine visually would
be eleven seconds of silence. Also two build-level blockers nobody would notice until the day
they tried: no `NSMicrophoneUsageDescription` in the Makefile's `INFO_PLIST`, and `make app`
assembles an **unsigned** bundle, so mic TCC grants would likely re-prompt on every rebuild.

Filed as `docs/research/voice-mode-feasibility.md`, marked considered-and-deferred. That's the
last it's mentioned here.

## The actual work started with a measurement, and the measurement changed the plan

Phase 4's sidebar tools were fully specified back at inception. `docs/plan.md` says:

> Sidebar tools run as **separate short-lived `claude -p` calls with `--json-schema`** for
> structured results, so they never consume the main session's context.

Before writing a line of the runner, that premise got checked with live CLI calls against
claude 2.1.226. Same trivial prompt both times — `Rate this prompt: 'make it better'`, a
six-word instruction asking about a three-word prompt, against a three-field schema.

**Default `claude -p` with a schema:**

| | |
|---|---|
| `duration_ms` | **32,517** |
| cache-creation tokens | **18,854** |
| `total_cost_usd` | **$0.237** |
| model | **opus-5**, silently |
| output tokens | 1,932 |

Nineteen thousand tokens of cache creation, and nineteen hundred Opus output tokens, to rate a
three-word prompt. An internal Haiku call fired alongside it too (526 in / 14 out).

**Stripped launch** — `--model haiku --tools "" --system-prompt <short>
--exclude-dynamic-system-prompt-sections --setting-sources "" --strict-mcp-config
--disable-slash-commands --no-session-persistence`:

| | |
|---|---|
| `duration_ms` | **6,567** |
| cache-creation tokens | **0** |
| `total_cost_usd` | **$0.0043** |
| model | haiku only |

**≈55× cheaper. ≈5× faster. Identical work.**

### The correction

The plan's rationale was *half* wrong, and the half it got wrong is the interesting one.

"Never consumes the main session's context" is **true**. And it is precisely **why the call is
expensive**. A one-shot inherits nothing — no warm cache, no loaded system prompt — so it
rebuilds all of it, every press. The property the plan cited as the reason sidebar tools are
cheap is the exact mechanism that makes them expensive.

> Isolation is not cheapness. The thing that gives you the first takes away the second unless
> you strip the launch on purpose.

Worth being blunt about the counterfactual: nothing would have caught this later. It doesn't
throw, it doesn't warn, and it doesn't fail a test. It ships as a sidebar you press twice and
then quietly stop using, and the reason is a number nobody looked at. The plan's sentence was
perfectly reasonable when it was written; it was reasoning, and it went unchecked for two days
because it *sounded* like a measurement.

`docs/plan.md` is now annotated rather than rewritten — the original claim stays visible with
the correction attached, because "we believed X, here's what we measured" is worth more than a
tidy plan that was never wrong.

### And then: does this even run on the subscription?

Cody's question, and the right one, since the whole architecture rests on ADR-002. Verified:
one-shot `-p` calls report `apiKeySource: "none"`, same as the persistent session — fixture
line 1. Same auth path, nothing billed.

Which reframes the entire cost discussion. `total_cost_usd` is a **client-side estimate at API
rates**; on subscription auth it is not a bill and never was. The scarce resource is **quota** —
and `rate_limit_event` fires on one-shot runs too, reporting the same five-hour window as the
conversation:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1786267200,
 "rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false}}
```

So the real risk isn't dollars. **A chatty sidebar can rate-limit the main session.** They draw
from one pool. And the Phase 5 cost/quota meter has to count sidebar usage or it lies — which is
why `OneShotUsage` is *returned* to the caller rather than logged and dropped.

## What `--json-schema` actually does

Captured as `AgentKit/Tests/AgentKitTests/Fixtures/oneshot_structured.ndjson`, 22 lines, a real
stripped run. The good news first: it decodes through the **existing** session decoder with zero
`.unrecognized` events. A one-shot run isn't a different protocol, it's the same protocol that
stops after one exchange.

The flag is a **forced tool call underneath**. A tool named `StructuredOutput` gets injected and
the model calls it:

```json
{"type":"tool_use","id":"toolu_01YBPNfM49dfUAgaMm2aJkcr","name":"StructuredOutput",
 "input":{"score":15,"issues":["Extremely vague and lacks context - 'it' is undefined", …],
          "rewrite":"Please review and improve the following …"},
 "caller":{"type":"direct"}}
```

then a synthetic `tool_result` — `"Structured output provided successfully"` — comes back. So a
successful run reports **`num_turns: 2`** and **`stop_reason: "tool_use"`**, not `end_turn`.
Anything asserting on `end_turn` reports false failures. The tool also appears in
`system/init.tools` as `["StructuredOutput"]` *despite* `--tools ""` — the empty list removes
the built-ins, and `--json-schema` adds its own back.

The payload lands in two places:

```json
"structured_output":{"score":15,"issues":[…],"rewrite":"…"},
"result":"{\"score\":15,\"issues\":[…],\"rewrite\":\"…\"}"
```

`structured_output` is already parsed. `result` is the same thing mirrored as a string. Decode
the former — `result` is the assistant's *text* channel, and the mirroring is incidental. There's
a test whose entire job is to keep the typed path pointed at the real field even though both
parse identically today.

**Three smaller things fell out of the fixture, all recorded in
`docs/research/stream-json-protocol.md`:**

- **`rate_limit_event` ordering is not stable.** The Phase 0 notes said it arrives *before*
  `system/init`. On this one-shot run, `system/init` is line 1 and `rate_limit_event` is line 2.
  Same CLI version. The protocol note now says "arrives early" and nothing more precise.
- **`modelUsage` and `usage` disagree, and `usage` undercounts.** 956/542 top-level against
  1482/556 in the breakdown — a difference of exactly 526 in / 14 out, the same hidden internal
  call seen on the Opus run. A quota meter must read `modelUsage`.
- **`duration_api_ms` (8738) exceeds `duration_ms` (7755)** on this run. So the two fields are
  not nested the way the names imply; don't subtract them to derive client overhead. Filed as an
  open question rather than explained away.

## Nine seconds is the number that matters for the UI

Live end-to-end through the Swift API: **wall clock 9.25 s against a self-reported `duration_ms`
of ~7.2 s.** The ~2 s gap is process spawn, which the CLI doesn't count because its clock starts
after it's already running.

So a sidebar click lands around **nine seconds**. Every tool needs a pending state from version
one.

That is the second time this project has learned the same lesson by a different route. Phase 2's
gate measured 43 ms of dispatch and Cody said it *"felt like a stall for a minute"* — because
11.5 s of TTFT showed an empty transcript. Now: a runner whose own timing says 7 s while the
human waits 9. **Both times the honest number was the one the instrument wasn't reporting.**

## The bug: a crash the test suite could not have found

This one deserves the space.

`Process.terminationStatus` is, in Swift's view, a non-throwing non-optional `Int32`. Nothing in
the signature hints at danger. But it's backed by `NSConcreteTask`, and reading it before the
process exits raises an **Objective-C exception**:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: '*** -[NSConcreteTask terminationStatus]: task still running'
```

**Swift cannot catch Objective-C exceptions.** No `do`/`catch` helps. The app dies:
`Abort trap: 6`.

Where it landed: `runRaw` races the CLI against a deadline. When the deadline wins, the code
terminates the child and builds an error describing what happened — and what happened naturally
includes the exit code. But a timeout is *by definition* the state where the process hasn't
exited, and `terminate()` only sends SIGTERM and returns.

**Every one-shot timeout would have crashed Iris.** Not intermittently — the read was in the
timeout path itself, so it was 100% reproducible the moment a deadline fired.

The fix is three lines:

```swift
private func exitedStatus(_ process: Process) -> Int32? {
    process.isRunning ? nil : process.terminationStatus
}
```

and that optional propagates outward into the error type, which is the part worth noticing:

```swift
/// The process stopped without ever emitting a `result`. `exitCode` is nil when the
/// process was still running — `Process.terminationStatus` cannot be read before exit.
case noResult(exitCode: Int32?)
```

The `?` isn't defensive style. It's the API admitting there are states where the exit code
doesn't exist yet — the exact fact `terminationStatus` hides behind a total-looking type.

### Why the tests were green the whole time

**35/35 passing, throughout.** They're fixture tests: captured NDJSON replayed through the
decoder. No process, so no process lifecycle, so no state in which `terminationStatus` is
unreadable. The suite wasn't weak — it was measuring a different thing entirely and had no way
to know.

It surfaced only because a `--timeout` flag was added to the `iris-cli` probe
(`make harness ARGS="-s --timeout 1"`) specifically to fire a real deadline at a real child.

> Fixture tests verify what the protocol *says*. They can't verify anything about the
> *process* — spawn failure, pipe deadlock, SIGTERM timing, exit-code availability. Failure
> paths involving a subprocess need a real subprocess, and the cheapest way to get one is a
> harness flag that forces the failure on demand.

There's already a second instance of the same category sitting in this repo, unremarked until
now: stderr is drained-and-discarded in both `AgentBridge` and `OneShotQuery` **not** because
anything reads it, but because an unread pipe deadlocks the child once its buffer fills. Also
invisible to fixtures. Written up as `docs/research/process-termination-status-trap.md` with a
checklist for the next `Process` use.

## What shipped

`AgentKit/Sources/AgentKit/OneShotQuery.swift` — 278 lines:

- **`StructuredOutput`** — a `Decodable` type paired with a **hand-written** `jsonSchema` string
  literal. Swift has no JSON Schema reflection, and the literal is what the model actually sees,
  so keeping it beside the properties makes drift visible in review. Schemas need
  `additionalProperties: false` and every field in `required`; the CLI is stricter about the
  schema than about your `Decodable`, so a missing `required` entry shows up as a silently
  absent field rather than an error.
- **`OneShotConfiguration`** — the point of the whole type. Every default is the cheap one:
  haiku, no tools, no setting sources, `--system-prompt` replacing rather than appending, 60 s
  deadline, subscription assertion on.
- **`OneShotUsage`** — with `didPayColdStart` as a first-class signal.
- **`OneShotQuery.run` / `.runRaw`.**

`RunResult` gained `structuredOutputJSON`, `usage` and `decodeStructuredOutput(_:)`.
`AgentError` gained `timedOut`, `noStructuredOutput`, `runFailed`, and
`noResult(exitCode: Int32?)` — the optional existing precisely because of the trap above.

**Deliberately not part of `AgentBridge`**, and that's ADR-008. The bridge exists to keep *one*
process alive across turns because per-turn startup would break the perf gate. This does the
opposite on purpose. The two configurations are opposite on every axis that matters — model,
tools, setting sources, session persistence, lifetime — and merging them would mean one surface
serving two contradictory sets of defaults, with nothing structural to stop a future "cleanup"
from reintroducing an 18,854-token cold start on every press. Two types make the wrong thing
require typing. The reuse cost is real and accepted: pipe setup, readability handlers, the
stderr drain and the API-key scrub are duplicated.

One deliberate inconsistency: the runner uses `--output-format stream-json` even though it never
streams and `json` would give an identical result line. It does that purely so `system/init` is
visible and the `apiKeySource == "none"` assertion runs on sidebar calls too. A cheaper call
isn't a reason for a weaker auth check.

### The tests are cost guards, not correctness tests

11 new, **35 total, all passing** (`make test`, verified). The three that matter aren't checking
that anything decodes:

- `testStrippedLaunchPaysNoColdStart` — cache creation must be exactly 0.
- `testOneShotRunsOnHaikuOnly` — exactly one model billed, and its name contains "haiku".
- `testArgumentsStripEverythingThatCostsTokens` — asserts every flag individually, including
  that `--append-system-prompt` is **absent**. Its docstring says why it exists: *"so nobody
  trims the list to make the command line tidier."*

That last one is the unusual one. It's a test whose purpose is to defend a decision from a
future person's good intentions — the flag list looks like clutter, and the cost of tidying it
is invisible until the sidebar is slow.

`make harness ARGS="-s"` runs the same check live and **exits 1** if cache creation comes back
non-zero. `ARGS="-s --timeout N"` fires the deadline.

## Repo state

- Branch `dev`, HEAD `5d3947b`. `make test`: **35/35**, 0 failures.
- `CLAUDE.md` gained a "Sidebar tools launch stripped, on Haiku" hard rule, the `--json-schema`
  protocol note, and a new **AppKit / Foundation gotchas** section for the `terminationStatus`
  trap.
- `README.md`'s test count was still saying 24 until this pass; corrected to 35.

## Still to build in Phase 4

The runner exists; **nothing uses it yet.** Still open: the `SidebarTool` protocol + registry,
the four tools themselves (notes, prompt improver, SQL reviewer, bug checker), plus the file
path picker and the project switcher. The prompt-improver schema does at least exist in
`iris-cli/main.swift` as `PromptCritique`, which is where the fixture came from.

## The shape of the day, for whoever writes this up later

Both of today's findings are the same finding wearing different clothes:

- The plan's cost claim was **reasoning that looked like a measurement**, and stayed unchallenged
  until someone ran the two calls side by side.
- The test suite was **green in a dimension it couldn't observe**, and stayed that way until
  someone fired a real deadline at a real process.

In both cases the artifact — a plan, a test suite — was giving a confident answer to a question
it had never actually been asked.
