# 2026-08-09 — Measuring before building, and the crash that 35 green tests couldn't see

*Three commits across one long day. **Part one** (`5d3947b`, `cdb0e09`, committed in the small
hours) opened with a question about voice, spent its middle measuring something the plan had
already decided, and found out the plan's reasoning was half wrong — then the runner it produced
turned out to contain a guaranteed crash that the entire test suite was structurally incapable of
detecting. **Part two** (`63d6b70`, that afternoon) spent the number part one had measured: the
sidebar tool system, four tools, and a UI shaped almost entirely by the fact that a click costs
nine seconds.*

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

## Repo state (part one, at `cdb0e09`)

- Branch `dev`, HEAD `5d3947b`. `make test`: **35/35**, 0 failures.
- `CLAUDE.md` gained a "Sidebar tools launch stripped, on Haiku" hard rule, the `--json-schema`
  protocol note, and a new **AppKit / Foundation gotchas** section for the `terminationStatus`
  trap.
- `README.md`'s test count was still saying 24 until this pass; corrected to 35.

## Still to build in Phase 4 (written at `cdb0e09`; part two closes most of it)

The runner exists; **nothing uses it yet.** Still open: the `SidebarTool` protocol + registry,
the four tools themselves (notes, prompt improver, SQL reviewer, bug checker), plus the file
path picker and the project switcher. The prompt-improver schema does at least exist in
`iris-cli/main.swift` as `PromptCritique`, which is where the fixture came from.

## The shape of the first half, for whoever writes this up later

Both of today's findings are the same finding wearing different clothes:

- The plan's cost claim was **reasoning that looked like a measurement**, and stayed unchallenged
  until someone ran the two calls side by side.
- The test suite was **green in a dimension it couldn't observe**, and stayed that way until
  someone fired a real deadline at a real process.

In both cases the artifact — a plan, a test suite — was giving a confident answer to a question
it had never actually been asked.

---

# Part two — the sidebar, and what nine seconds does to a design

*Commit `63d6b70`, "Add the sidebar tool system and its four tools." 17:33, same day. Two new
files (`SidebarTool.swift`, 394 lines; `SidebarViews.swift`, 494 lines) plus 70 lines of change
in `GlassContentView.swift`. This is the largest remaining Phase 4 item and it closes.*

The morning built a runner nothing used. The afternoon used it. The interesting part isn't the
four tools — it's that the single most influential input to the design was a **latency
measurement**, not a feature list. Nine seconds per click is long enough that it stopped being a
performance footnote and started dictating what the components are.

## The protocol is class-bound, and that's the load-bearing decision

`SidebarTool` is declared `AnyObject`:

```swift
@MainActor
protocol SidebarTool: AnyObject, Identifiable {
    var id: String { get }
    …
    var usesModel: Bool { get }
    func makeView() -> AnyView
}
```

The obvious Swift instinct is a struct — a tool is a description of a tool, descriptions are
values. That instinct is wrong here for a reason that only shows up once you try to *hide* one.
Every tool holds live state: draft text mid-typing, the last result, an in-flight `Task`. Those
have to survive being collapsed, reordered, or removed from the panel and added back. A struct
would have pushed all of that into some external store keyed by tool id — which is the same
state, in a worse place, with an id-to-state mapping to keep honest by hand.

So the registry instantiates all four **once at launch** and keeps them alive whether or not
they're visible:

```swift
all = tools ?? [
    NotesTool(),
    PromptImproverTool(),
    ReviewTool.sqlReviewer(),
    ReviewTool.bugChecker(),
]
```

Hiding a tool removes its id from the layout. It does not throw away the note you were halfway
through writing. That's the whole argument, and it's written into the file as a comment so the
next person doesn't "clean it up" into a struct.

Recorded as **ADR-009**, with the alternatives that lost.

## Layout is a file, again

`SidebarRegistry` persists `{"enabled": [...]}` to
`~/Library/Application Support/Iris/sidebar.json`, deliberately mirroring `PersonaStore`: plain
pretty-printed JSON with sorted keys, atomic write, failure logged and swallowed rather than
surfaced.

```swift
} catch {
    NSLog("Iris: failed to persist sidebar layout — \(error)")
}
```

A layout that won't save is a nuisance; blocking someone from rearranging their panel this
session because a write failed is worse than the nuisance. Same call as ADR-007 made for the
persona, for the same reason — and the same second-author property comes free: `sidebar.json` is
a real file at a real path, so the agent's own file tools can reach it too.

One defensive detail that took thirty seconds to write and prevents a bad class of bug:

```swift
let known = Set(all.map(\.id))
layout = SidebarLayout(
    enabled: (stored ?? .default).enabled.filter(known.contains))
```

Unknown ids are dropped at load. A layout file written by a build that had five tools must not
strand a panel in a build that has four. The comment in the source says "rather than rendering a
hole", which is the visible symptom; the real reason is that stored config outlives the binary
that wrote it, and this app writes config to disk on purpose.

Default layout is notes + prompt improver enabled, the two review tools available in the picker:

```swift
static let `default` = SidebarLayout(enabled: ["notes", "prompt-improver"])
```

Notes first because it costs nothing; prompt improver second because it's the one most likely to
be worth its nine seconds.

## Notes was built first specifically because it's boring

This was a deliberate sequencing choice and it paid off immediately. `NotesTool` makes **no model
call at all**. Building it first proved the protocol, the registry, the persistence, the card
chrome, the picker and the ⌘⌥S toggle with **zero** of the ~9 s latency in the loop. Every bug
found while building it was a bug in the panel, unambiguously, because there was nothing else it
could be.

Its one non-obvious piece is the debounce:

```swift
var text: String {
    didSet { schedulePersist() }
}
```

`didSet` fires per keystroke, and writing a file per keystroke is pointless churn for a
scratchpad. 500 ms after typing stops, via a cancel-and-replace `Task`. (Notes lives in its own
`notes.txt`, not inside `sidebar.json` — layout and content are different lifetimes.)

## Two tools, one class

The SQL reviewer and the bug checker are the same class twice:

```swift
static func sqlReviewer() -> ReviewTool { … }
static func bugChecker() -> ReviewTool { … }
```

They differ in id, title, SF Symbol, tint, blurb, placeholder and system prompt. They do not
differ in *behaviour*, and — the part that actually justified merging them — they don't differ in
the shape of an answer. Both produce a ranked list of "here, this, fix it", so both decode into
one `FindingList`. Two classes would have been two copies of the same fifteen lines distinguished
by one string.

Both briefs end on the same instruction, and it's the most opinionated line in the commit:

> *"If the query is fine, say so with an empty findings list rather than inventing nits."*
> *"An empty findings list is a valid answer."*

A review tool with nothing to say is under enormous pressure to find something, because a tool
that returns nothing looks broken. So the empty case is licensed in the prompt **and** given a
first-class render — a green check and "Nothing worth flagging" — rather than falling through to
an empty `ForEach`. Cheap to build, and it's the difference between a reviewer you trust and one
you learn to ignore.

The bug checker's brief carries the same idea in a stricter form: *"Every finding needs a
concrete failure case — if you can't describe input that breaks it, leave it out."*

## Nine seconds is a design input, not a performance note

This is the part worth writing up.

Part one measured **9.25 s wall clock against a self-reported `duration_ms` of ~7.2 s** — about
7 s of model time plus ~2 s of process spawn the CLI's clock never sees. Every decision below
falls out of that one number.

**The pending state names what it's waiting on.** Not a spinner:

```swift
HStack(spacing: 5) {
    ProgressView().controlSize(.mini)
    Text("haiku · separate process")
}
```

At 300 ms a spinner means "working". At nine seconds a bare spinner means "hung", and the user's
next move is to wonder whether they've wedged the conversation. So the label says two things at
once: it's the cheap model (this isn't going to be *worse* than nine seconds) and it's a separate
process (your conversation is fine). A Cancel button sits beside it for the whole duration,
because nine seconds is long enough to change your mind.

**The picker labels which tools spend quota.** Every model-backed tool declares
`usesModel: true`, and the picker renders an amber "uses quota" chip next to it. That's the
morning's finding surfacing in the UI: sidebar calls draw from the *same five-hour pool* as the
conversation, so a chatty sidebar can rate-limit the thing you're actually talking to. That fact
belonged at the moment someone adds a tool, not in a doc nobody opens.

**Every result carries a usage footnote.** Model, total tokens, duration, and a cold-start
warning:

```swift
Text(usage.model.map(shortModel) ?? "?")
    .foregroundStyle(usage.didPayColdStart ? Tok.Palette.warn : .secondary)
```

This is the bit that pleases me most and it's worth being precise about *why*: the cost model
from part one is enforced by three tests and a live probe, all of which run when someone chooses
to run them. The footnote makes the same regression visible **in the app, to the user, on the
next click**. If a strip flag ever stops working, "cold start" appears in amber under a result
that took 30 seconds instead of 9. The sidebar reports on its own cost.

**A correction to how that was described to me:** the amber is keyed to `didPayColdStart`
(`cacheCreationTokens > 0`) *only*. A call that escalates off Haiku without paying a cold start
renders its model name in plain secondary text — legible, but not highlighted. Escalation is
*visible*, not *flagged*. Given `OneShotUsage.models` is already ranked heaviest-first and the
footnote prints only `models.first`, tinting on `model != "haiku"` would be a two-line change and
probably should happen. Filed below as a loose end rather than quietly written up as done.

## The refactor: a box that was rebuilt every frame

The first cut of the shared tool body took a `RunnerBox` — one `@Bindable` object pairing a
tool's `draft` binding with its `OneShotRunner`, so the view had a single thing to observe.

It was constructed **inside `body`**. Which means a fresh object on every evaluation, and
`@Observable`'s dependency tracking keyed to an identity that never survived a frame. That is
precisely the wrong shape: the whole point of `@Observable` is that reading a property through a
*stable* reference registers a dependency.

The replacement is duller and correct — a plain `@Binding` and a plain `let`:

```swift
@Binding var draft: String
/// A plain `let`, not `@Bindable`: nothing here writes to the runner's properties, and
/// `@Observable` tracks reads through a stored reference just fine.
let runner: OneShotRunner<Output>
```

The general rule, stated for the next time: **`@Bindable` is for writing, not for observing.**
Reading an `@Observable`'s properties through any stored reference already tracks. Wrapping
things in a box to "make them observable" is a habit carried over from `ObservableObject`, and
here it actively broke the mechanism it was imitating. Written up in
`docs/research/observable-state-in-swiftui.md`.

## The rail itself

Small things, in the order they'd be noticed:

- **⌘⌥S** is hosted by a hidden `Button` in a `.background` modifier — a keyboard shortcut with
  no visible control in the chrome. There's also a `sidebar.right` chip in the status bar that
  tints to `Tok.Palette.agent` when the rail is out, so the shortcut is discoverable.
- **The window's minimum width grows when the rail is out**, 640 → 940. The panel is a fixed
  320 pt, and 640 − 320 leaves a transcript too narrow for a code block. A minimum that ignores
  a permanent 320 pt tenant isn't a minimum.
- **The transition is `.move(edge: .trailing)` combined with opacity.** Opacity alone made the
  panel look like it materialised *on top of* the transcript rather than sliding in from the edge
  it lives on.
- **Fusion stays at 0 between stacked cards**, so tools read as separate panels instead of
  welding into one slab. Same lesson the transcript learned at `61a5b01` — *fuse things that are
  one control, never things you have to count*. (Loose end: the panel hardcodes
  `GlassEffectContainer(spacing: 0)` rather than adding a `Tok.Fusion.sidebar` token beside
  `transcript`, `composer` and `status`. Every other fusion decision in the app is a named token
  with a comment explaining why it's 0. This one isn't yet.)
- **The working directory arrives through the environment**, not captured per tool:

  ```swift
  /// Passed down rather than captured by each tool: the project switcher changes it at
  /// runtime, and a tool holding a stale copy would run against the wrong directory.
  var sidebarWorkingDirectory: URL
  ```

  Written before the project switcher exists, because the switcher is the *next* Phase 4 item and
  a tool holding a stale `cwd` is a silent wrong answer rather than an error.

## One place decides the cost

Worth flagging because it's a structural choice, not a style one. `OneShotRunner` constructs its
configuration with exactly two arguments:

```swift
configuration: OneShotConfiguration(
    // Everything cost-related is a default on OneShotConfiguration — haiku,
    // no tools, no setting sources. Don't re-specify them here; the one
    // place they're decided is the type that measured them.
    workingDirectory: workingDirectory,
    systemPrompt: systemPrompt)
```

Three tools, one runner, and **zero** places outside `OneShotConfiguration` where a model or a
strip flag is named. Re-specifying `model: .haiku` at each call site would look more explicit and
would be strictly worse: it's three places to drift from the measurement, and the tests assert
against the configuration type, not against the call sites.

## A latent bug the fixture already predicted

The prompt improver's schema describes its score field as 1–10:

```json
{"score":{"type":"integer","description":"1-10 quality of the prompt"}}
```

That's a *description*, not a constraint — no `minimum`, no `maximum`. And the captured fixture
from part one, generated against the older schema which had no description at all, contains:

```json
"structured_output":{"score":15, …}
```

**Fifteen out of ten.** The model was asked for an integer and gave one. Meanwhile `scoreTint`
sends anything ≥ 7 to green, so a 15 renders as a confident green "15/10". Nothing crashes,
nothing is caught; the UI just states something absurd with total composure. The prose hint may
well fix it in practice — but the fixture is direct evidence that the unconstrained version
didn't, and the honest fix is `"minimum":1,"maximum":10` in the schema plus a clamp at render.
Not done in this commit. Listed as a loose end because "we shipped it and here's the evidence it
can misbehave" is worth more than a silent patch.

## State at `63d6b70`

- `make build` clean. **`make test`: 37/37, 0 failures** (verified — 13 of them
  `OneShotQueryTests`). Up from 35; the two added in `cdb0e09` cover `modelUsage` summing and
  heaviest-model ranking.
- App rebuilt and relaunched, running.
- **No new tests in this commit.** Everything added is `@MainActor` SwiftUI view and view-model
  code, and the test target is the headless `AgentKit` package. That's an honest gap rather than
  an oversight: `SidebarRegistry`'s layout filtering — load a layout containing an unknown id,
  assert it's dropped — is pure logic with an injectable `tools:` parameter already on the
  initialiser, and is testable today if the registry moves somewhere the test target can see it.

## Phase 4 after this

| Item | State |
|---|---|
| Persona wizard | ✅ `6c5a663`, ADR-007 (`CLAUDE.md` write deliberately declined) |
| Sidebar runner | ✅ `5d3947b` / `cdb0e09`, ADR-008 |
| Sidebar tool system + four tools | ✅ `63d6b70`, ADR-009 |
| File path picker | ⬜ |
| Project switcher | ⬜ |

Phase 5 not started.

## Loose ends, written down now rather than rediscovered

1. Escalation off Haiku is visible in the footnote but not tinted; only cold start is.
2. `score` has no `minimum`/`maximum` in the schema, and the fixture shows a 15.
3. `FindingList.Finding.id` is `"\(severity)-\(location ?? "")-\(issue)"` — two genuinely
   identical findings would collide in a `ForEach`.
4. `UsageFootnote` prints `ms / 1000` with integer division, so 9,250 ms reads as "9s".
5. No `Tok.Fusion.sidebar` token; the 0 is a literal.
6. `SidebarRegistry`'s unknown-id filtering is untested and is the one piece here that's
   straightforwardly testable.

## The shape of the whole day

Part one ended on: *the honest number was the one the instrument wasn't reporting.*

Part two is what you do once you have it. The nine seconds wasn't treated as a problem to
optimise away — it can't be, it's a process spawn plus a model round-trip — it was treated as a
**material property of the component**, and the design was drawn around it. The pending label,
the quota chip in the picker, the usage footnote, and even the decision to build the tool that
makes no model call first: every one of those exists because of a number measured before the
first line of UI was written.

> Measure first, and the measurement stops being a verdict on your design and starts being an
> input to it.
