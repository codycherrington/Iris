# ADR-009 — Sidebar tools are live objects in a registry, with a layout that persists

**Date:** 2026-08-09
**Status:** Accepted
**Commit:** `63d6b70`

## Context

`docs/plan.md`'s Phase 4 specifies the sidebar as a *system*, not a fixed panel:

> **Sidebar tool system** — a `SidebarTool` protocol + registry. Each tool is a SwiftUI view plus
> an optional headless action. Rearrangeable, addable, removable. Ship: notes, prompt improver,
> SQL reviewer, bug checker.

By the time this was built, three facts from earlier in the day constrained it (all in
`docs/research/one-shot-cost-model.md` and ADR-008):

1. **A model-backed tool call takes ~9 s end to end** — ~7.2 s self-reported `duration_ms` plus
   ~2 s of process spawn the CLI's own clock never sees. That is long enough to be a design
   input rather than a performance footnote.
2. **Sidebar calls draw on the same five-hour quota pool as the conversation.** `rate_limit_event`
   fires on one-shot runs too. A chatty sidebar can rate-limit the thing the user is talking to.
3. **Sidebar tools never touch the session.** `OneShotQuery` is a separate stripped process; a
   tool that needs the conversation's history or its file tools does not belong in the sidebar.

Fact 1 means a tool is not a stateless render of a result — it is a thing with a *lifecycle*:
draft text being typed, an in-flight `Task` that can be cancelled, a result that persists until
cleared. Fact 2 means the set of tools is a user-visible cost decision, so which ones are showing
has to be the user's choice and has to survive relaunch.

The specific question this ADR settles: **where does a tool's live state live, and who owns the
arrangement?**

## Decision

**A class-bound protocol, a registry that owns one long-lived instance of every tool, and a
layout persisted as plain JSON.**

```swift
@MainActor
protocol SidebarTool: AnyObject, Identifiable {
    var id: String { get }          // stable across launches; the layout file stores it
    var title: String { get }
    var symbol: String { get }
    var tint: Color { get }
    var blurb: String { get }       // shown in the picker
    var usesModel: Bool { get }     // renders the "uses quota" chip
    func makeView() -> AnyView
}
```

Three parts:

1. **Tools are reference types and hold their own state.** `@MainActor @Observable final class`,
   each owning its draft text, its `OneShotRunner`, and any tool-specific storage (`NotesTool`
   writes its own `notes.txt`).
2. **`SidebarRegistry` instantiates all of them once at launch and keeps them alive** whether or
   not they are visible. Hiding a tool removes its id from the layout; it does not deallocate the
   tool or discard its state.
3. **Layout — an ordered list of enabled ids — persists to
   `~/Library/Application Support/Iris/sidebar.json`**, mirroring `PersonaStore` (ADR-007):
   pretty-printed sorted-key JSON, atomic write, failure logged via `NSLog` and swallowed.
   Unknown ids are filtered out at load against the set of ids the running build actually has.

Model-backed tools share one `OneShotRunner<Output>` — a small `@Observable` state machine
(`idle / running / failed(String) / done(Output, OneShotUsage)`) wrapping a single `OneShotQuery`
call with cancellation. The runner constructs `OneShotConfiguration` with only `workingDirectory`
and `systemPrompt`, leaving every cost-related flag at its default, so
`OneShotConfiguration` remains the one place a model or strip flag is named.

The working directory reaches tools through a SwiftUI `EnvironmentKey`
(`\.sidebarWorkingDirectory`), not captured at construction, because the project switcher will
change it at runtime and a tool holding a stale `cwd` would silently run against the wrong
directory.

## Alternatives considered

**Struct tools with state held externally.** The idiomatic-Swift answer: a tool is a value
describing a tool, and its mutable state lives in a store keyed by tool id. Rejected because it
is the same state in a worse place. Every tool would need an entry in a heterogeneous state
dictionary, every view would need to look its state up by id, and nothing structural would keep
the two in sync — a renamed id or a tool added without a matching store entry fails at runtime,
not at compile time. The class-bound version makes "a tool and its state" a single object the
compiler already keeps together.

**Recreating tools on demand — instantiate when shown, drop when hidden.** Cheaper-looking, and
wrong at nine seconds. Collapsing a card, or hiding the rail with ⌘⌥S to read a wide code block,
would discard a half-written note and abandon an in-flight call the user is waiting on. The
failure is quiet and feels like data loss. Four small objects held for the lifetime of the app is
not a resource problem worth having this bug for.

**A single hardcoded panel — four fixed sections, no protocol, no registry.** Genuinely less
code, and the plan explicitly asked for rearrangeable/addable/removable so this would have been a
deviation. Beyond that: the quota facts make the tool set a *cost* decision, so "which of these
am I willing to have in front of me" has to be answerable by the user. A hardcoded panel also has
nowhere to put the fifth tool, and the fifth tool is the point of calling it a system.

**Tools sharing the main session** — route tool prompts through `AgentBridge` as extra turns.
Rejected up front, and it is the reason the sidebar exists at all. It would put every tool call
into the transcript and the main context window, pay the conversation's full context on every
click, and run on the conversation's model. That is the exact thing ADR-008's measurement rules
out: 18,854 cache-creation tokens and opus-5 for a prompt that costs 0 and haiku when isolated.
A tool that genuinely needs conversation history belongs *in* the conversation, not in the
sidebar.

**Two separate classes for the SQL reviewer and the bug checker.** They differ only in id, title,
symbol, tint, blurb, placeholder and system prompt — and crucially not in the shape of an answer:
both produce a ranked list of findings and decode into one `FindingList`. One `ReviewTool` class
with two static factories. If a third review brief appears it is one more factory, not one more
file.

**`UserDefaults` for the layout instead of a JSON file.** Same argument ADR-007 made for the
persona and rejected for the same reason: a hashed binary plist is a setting, a readable file at
a readable path is config. It also means the agent's own file tools can see and edit the layout,
which is a property this project keeps choosing deliberately.

## Consequences

**Good**

- Hiding, collapsing, reordering and re-adding a tool are all non-destructive. Half-written notes
  and in-flight calls survive all of them.
- Adding a tool is one class and one line in the registry's array. It appears in the picker with
  its blurb and its quota chip automatically.
- The layout file is inspectable, diffable, and editable by hand or by the agent.
- `OneShotRunner` is shared, so the pending state, cancellation, error rendering and usage
  footnote are written once and every model-backed tool gets the same behaviour — including the
  cold-start warning that makes an `OneShotConfiguration` regression visible in the UI rather
  than only in the test suite.
- Unknown-id filtering means a layout file can outlive the build that wrote it.

**Costs and risks accepted**

- **Every tool is retained for the app's lifetime.** Four small `@MainActor` objects; fine now,
  and a reason to be deliberate about what gets added later.
- **`makeView() -> AnyView` erases the view type**, which forfeits some SwiftUI diffing precision.
  The alternative — an associated view type — makes `any SidebarTool` unusable in a heterogeneous
  array, which is the entire registry. A sidebar of four small cards is not where view-identity
  performance will matter; if it ever does, this is the thing to revisit first.
- **Tool ids are database keys.** Renaming one orphans every stored layout that contains it. The
  protocol comment says so; there is no migration mechanism and none is planned until one is
  needed.
- **None of this is covered by tests.** The test target is the headless `AgentKit` package and
  everything here is `@MainActor` SwiftUI code in the `Iris` target. The registry's layout
  filtering is pure logic and already takes an injectable `tools:` parameter, so it is testable
  the day it is moved somewhere the test target can see it. Noted as a real gap.
- **Persistence failures are invisible to the user** by design. Consistent with `PersonaStore`;
  the tradeoff is that a permissions problem in Application Support silently stops layouts
  saving.

## See also

- ADR-007 — persona as an inspectable file (the persistence pattern this copies)
- ADR-008 — two execution modes, two types (why tools call `OneShotQuery`, not `AgentBridge`)
- `docs/research/one-shot-cost-model.md` — the ~9 s and quota measurements that shaped the UI
- `docs/research/observable-state-in-swiftui.md` — the `@Bindable` box that was rebuilt every
  frame, found while building this
