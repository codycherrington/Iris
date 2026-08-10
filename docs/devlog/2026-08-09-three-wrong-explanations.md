# 2026-08-09 (evening) — Three wrong explanations, and the day Iris became an app

*Six commits, `f6251e2` through `3a48e41`, 17:43 to 19:34. A separate file from
[`2026-08-09-measuring-before-building.md`](2026-08-09-measuring-before-building.md), which
covers the same date and closes at `63d6b70` — see [the note on why](#why-this-is-a-separate-file)
at the end. That entry was about cost and architecture. This one is about the app becoming
usable: buttons you can actually hit, a model picker, an auth indicator that answers at launch,
questions rendered as controls, a composer that owns its own text view, slash commands that
stop vanishing, and an icon in the Dock.*

The through-line is narrower than "measure first", which was the previous entry's. Here it is
specifically this:

> **Three times in one evening, something was measured and the measurement contradicted the
> obvious explanation.** Not "we had no number and got one" — we had a confident causal story
> each time, and each story was wrong.

1. The send arrow looked off-centre. The correction that had been applied to fix it was
   *causing* the problem, and the glyph underneath measures at exactly `(0.000, 0.000)`.
2. The arrow was *still* off after that fix, but only before typing. The obvious culprit — a
   scaled glyph landing off the pixel grid — moves it by 0.062 pt. The real cause was that
   `.scaleEffect` and `.glassEffect` don't scale about the same point.
3. The status chip said "checking…" forever. The obvious fix was to wait longer for
   `system/init`. Holding a session open for eight seconds proved it emits **nothing at all**
   until a turn happens, which sent us looking for a different instrument entirely — and found
   an undocumented one.

A fourth thing happened that isn't a measurement but belongs with them: the obvious way to ask
the user a question was Claude Code's own `AskUserQuestion` tool, and it isn't reachable from
print mode. Checked rather than assumed, which is why an evening wasn't spent wiring up a tool
that isn't there.

---

## Zero — closing out part two's loose ends (`f6251e2`)

The previous entry ended with a numbered list of loose ends written down rather than fixed.
Five of six are now closed, in the first commit of this batch. Worth recording that the list
worked: nothing here was rediscovered, it was picked up off a page.

**The 15/10.** The prompt improver's schema said `{"type":"integer","description":"1-10 quality
of the prompt"}` and the committed fixture contains `"score":15`. A description is a request;
`minimum`/`maximum` are the constraint. Both are now set:

```json
{"score":{"type":"integer","minimum":1,"maximum":10,
 "description":"Quality of the prompt, 1 (unusable) to 10 (needs nothing)"}}
```

The interesting part is what was *added alongside* the fix rather than instead of it.
`clampedScore` renders the safe number, and `scoreOutOfRange` puts a small amber "model said 15"
badge next to it when the model ignores the bounds. The reasoning, from the source:

> a schema that stops holding should be visible, not silently corrected.

A clamp on its own converts a broken constraint into a plausible-looking number, which is the
same failure as the green 15/10 wearing better clothes.

**Escalation off Haiku is now tinted red on its own.** `UsageFootnote` previously coloured the
model name only when `didPayColdStart` was true. Those are two independent failures — a call can
escalate off Haiku without paying a cold start — so an escalation was merely *visible* rather
than flagged, which is precisely the failure the footnote exists to catch.

**`Finding.id` was derived from its own content** (`"\(severity)-\(location ?? "")-\(issue)"`),
so two genuinely identical findings — the same issue at two call sites, neither carrying a
location — collided in the `ForEach` and one silently vanished. Now a per-instance `UUID` that is
never decoded, with `CodingKeys` excluding it.

**Duration used integer division**, rendering 9,900 ms as "9s". Now `String(format: "%.1fs", …)`.

**`Tok.Fusion.sidebar`** exists, so the sidebar's fusion-at-zero is a token with the reason
attached rather than a literal `0`.

Still open from that list: the registry's unknown-id filtering is untested. It is the one piece
of `Iris`-target logic that is pure and injectable, and it stays a real gap.

---

## One — "I have to click this three or four times" (`faafd5b`)

Cody, on the sidebar toggle:

> I have to do the same clicking 3 or 4 times before it opens for the side bar button. May be
> app wide.

It was app-wide, and it was two separate defects compounding — which is why it felt so much
worse than either one is.

**Defect one: almost no hit area.** A `.buttonStyle(.plain)` button whose label is an `Image` is
hit-testable only where the glyph's *ink* actually is. `.frame(width: 22, height: 22)` sizes the
layout box; it does not make the empty corners clickable. So a chevron nominally 22 pt across was
a target roughly 8 pt across **with holes in it** — the gaps between strokes aren't clickable
either.

**Defect two: no pressed state.** `.plain` renders no feedback whatsoever on macOS. A click that
landed looked identical to a click that missed.

Either alone is annoying. Together they produce a specific and much worse experience: you cannot
tell a near-miss from a dead control, so the rational response to a missed click is to click
again, and the button acquires a reputation. This is the interaction-design equivalent of the
empty-screen stall from 2026-08-08 — the system was working, and the absence of feedback made
"working" indistinguishable from "broken".

The fix is one type, `GlassControlStyle` in `DesignTokens.swift`, and the load-bearing detail is
*where* the `contentShape` goes:

```swift
func makeBody(configuration: Configuration) -> some View {
    configuration.label
        .contentShape(shape)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
        .opacity(pressOpacity(configuration.isPressed))
        .animation(Tok.Motion.resolved(Tok.Motion.press, reduceMotion: reduceMotion),
                   value: configuration.isPressed)
}
```

Inside the style, `contentShape` binds to the label's frame rather than to the glyph. Applied
outside at the call site — which is what `SendButton` was doing, `.buttonStyle(.plain)` followed
by `.contentShape(.circle)` — it is fighting the same ambiguity.

Three variants, so the shape matches what the control actually is: `.glassCircle` (send button,
icon buttons), `.glassChip` (status-bar chips), `.glassRow` (picker rows, list items). Every
`.buttonStyle(.plain)` in the live views is gone.

Two details worth keeping:

- Press feedback is **scale plus opacity**, and opacity is the part that survives Reduce Motion.
  A reduced-motion path that removes the feedback entirely reintroduces defect two for the users
  most likely to be helped by it.
- `Tok.Motion.press` is a 0.16 s spring, deliberately faster than `Tok.Motion.touch`. Press
  response has to read as the control reacting, not as an animation playing afterwards.

---

## Two — model and effort, and the honest half-answer (`faafd5b`)

The session now runs **Sonnet 5 at medium effort** by default, and the status-bar chip opens a
picker for both. `AgentConfiguration` gained `model: String?` and `effort: Effort?`, where
`Effort` is `low | medium | high | xhigh | max` — the CLI's own vocabulary, not invented levels.

The flag pair was verified live before anything was built on it:

```
claude -p "say ok" --model sonnet --effort medium
→ system/init reports "model": "claude-sonnet-5"
```

Both are **launch arguments**, so changing either restarts the session and clears the transcript
— the same constraint the persona has (ADR-007). The picker's footer says so in plain text
rather than putting a confirmation dialog in front of every change.

The model choices are aliases (`sonnet`, `opus`, `haiku`, `fable`), not pinned ids, so a new
Sonnet doesn't strand the app on an old one. `SessionSettings` persists to `UserDefaults` rather
than to a JSON file — a deliberate split from the persona, and the reasoning is in the source:

> the persona is deliberately *inspectable config* the agent itself can read and edit (ADR-007),
> whereas this is an app preference with no reason to be in the agent's reach.

### The half-answer that came out of this

The chip used to read `starting… —` until the first message. Model and effort come from the
*configuration*, so they are knowable at launch — that half was fixed here by splitting
`SessionStats.model` (what `system/init` reported it actually ran) from
`stats.configuredModel` / `configuredEffort` (what we asked for).

Keeping both is not redundancy. When they disagree, a warning triangle appears:

```swift
private var modelDrift: String? {
    guard stats.connection == .ready, stats.model != "—" else { return nil }
    let reported = ModelChoice.label(forReportedModel: stats.model)
    guard reported != stats.configuredModel else { return nil }
    return "Configured \(stats.configuredModel), but the session reported \(stats.model)."
}
```

Silent disagreement between what you selected and what actually ran is exactly the class of thing
this app exists to surface — it is the same failure as the sidebar's silent opus-5 escalation
from part one, one layer up.

Auth was left hedged at `checking…`, because claiming subscription before there is evidence is
the one thing that indicator must never do. That honesty is what made the next commit necessary.

---

## Three — pre-flight auth, and an undocumented CLI surface (`4d17996`)

### First: prove the obvious explanation is the real one

`checking…` persisted until the first message because `system/init` is emitted **per turn**, not
at process start. That was already in `CLAUDE.md` as a Phase 0 gotcha. But "per turn" and "not at
launch" are not the same claim, and the second one is the one that mattered — so it was tested
directly: a persistent session was held open for **eight seconds with no input**, and it emitted
**nothing at all**. No init, no status, no keepalive. The stream is silent until you speak.

That closed off "wait a bit longer" as a fix and sent the search elsewhere.

### `claude auth status --json`

It answers the same question from **local credentials, with no model call** — no tokens, no
quota, nothing billed — which is what makes it safe to run on every launch. A one-shot `claude -p`
would not be.

Two observed payloads (claude 2.1.226, 2026-08-09). Logged in on a subscription:

```json
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
 "email":"…","orgId":"…","subscriptionType":"pro"}
```

And the same command with a fake `ANTHROPIC_API_KEY` in the environment:

```json
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
 "apiKeySource":"ANTHROPIC_API_KEY","email":null,"orgId":null,"subscriptionType":null}
```

Three things in that pair, and the third is the one that makes this usable:

1. **`authMethod` stays `"claude.ai"` even with a key present.** The field that looks like it
   answers the question does not answer the question. Anything keying off `authMethod` would
   report subscription auth while every token went through a key.
2. **Every subscription field goes null** when a key is in play — `email`, `orgId`,
   `subscriptionType`.
3. **`apiKeySource` appears, under the same name and with the same semantics as
   `system/init.apiKeySource`.** That is what makes this a *pre-flight check of the same
   invariant* rather than a different, optimistic guess. Iris's hard rule has always been
   `apiKeySource == "none"`; this asks the same question earlier.

Full write-up with the field table: `docs/research/claude-auth-status.md`.

### What the probe is careful about

**It scrubs the environment exactly as `AgentBridge` does** — `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` both removed before launch. Without that it would report a key the session
is never going to see and warn about a problem that doesn't exist. The probe's job is to report
what *the session* will see, not what the shell exports.

**It does not replace the per-turn assertion in `AgentBridge.observe`**, which stays
authoritative. The distinction, written into the source:

> this reports what the install is configured to do, and `system/init` reports what the session
> actually did.

And the ordering is handled rather than assumed — a probe result arriving after init has already
answered is discarded:

```swift
guard let status = try? await AuthProbe.check() else { return }
// Don't overwrite a real answer. `system/init` is authoritative, and on a fast
// first turn it can land before this returns.
guard stats.connection == .starting else { return }
```

A probe failure is silent by design: the indicator falls back to `checking…` until the first
turn, which is exactly the old behaviour and no worse than it was.

### The number

**~0.25 s invoked directly in a shell. ~1.2 s through `Process`.**

That ~1 s gap is the same spawn overhead the sidebar's one-shot calls pay, measured in part one
as roughly 2 s on a heavier launch. It is fast enough to fire detached at launch and let the
indicator fill in a moment later; it is not fast enough to block startup on, and the code doesn't
(`Task { [weak self] in await self?.probeAuth() }`).

`iris-cli` prints the same probe at startup with its timing, so the harness shows the auth state
before you type anything.

Three tests added, pinning the field that decides it — including that a **missing** `apiKeySource`
and an explicit **null** are read identically, because the CLI omits the key entirely on the
subscription path and emits it as null elsewhere.

### One real bug fixed on the way

`changeDirectory` did `stats = SessionStats()`, which wiped `configuredModel` and
`configuredEffort` back to `—`. Those are launch arguments and survive a directory change. Now
`resetStats()` clears the per-session telemetry and re-derives the configured fields.

---

## Four — questions as a text convention, because the tool isn't there (`c428a81`)

Cody asked for a UI for when Iris asks a question back — real buttons instead of a paragraph of
"A) … B) …".

The obvious design was to hook Claude Code's own **`AskUserQuestion`** tool. It is not available
here: a `claude -p` session's `system/init` lists its tools, and `AskUserQuestion` is not among
them. Checked against 2.1.226 rather than assumed.

The repo's own captured fixtures corroborate this independently and are worth citing over the
live check, because they're committed and re-readable. All four full-session fixtures
(`transcript.ndjson`, `perms.ndjson`, `perm_default.ndjson`, `skills.ndjson`), captured
2026-08-07 on the same CLI version, report **69** tools — 33 non-MCP plus 36 MCP — and
`AskUserQuestion` appears in none of them. The live session on 2026-08-09 reported 67; the count
tracks whatever MCP servers happen to be connected, so **the count is incidental and the absence
is the finding.**

Non-MCP tool list, verbatim from `transcript.ndjson`:

```
Task, Bash, CronCreate, CronDelete, CronList, DesignSync, Edit, EnterWorktree, ExitWorktree,
ListAgents, ListMcpResourcesTool, LSP, Monitor, NotebookEdit, PushNotification, Read,
ReadMcpResourceDirTool, ReadMcpResourceTool, RemoteTrigger, ReportFindings, ScheduleWakeup,
SendMessage, Skill, TaskCreate, TaskGet, TaskList, TaskOutput, TaskStop, TaskUpdate,
ToolSearch, WebFetch, WebSearch, Write
```

**Interactive prompting is a property of the interactive TTY.** Print mode has nowhere to put a
blocking question, so it doesn't offer one.

### The convention

Questions travel the only channel that exists — the assistant's own text — as a fenced block,
taught via `--append-system-prompt` alongside the persona:

````
```iris:question
{"question": "Which should I use?", "options": [{"label": "Option A",
"description": "One line on what this means or costs."}, {"label": "Option B",
"description": "The tradeoff against A."}], "multiSelect": false}
```
````

`QuestionProtocol.split` pulls it back out and returns `(text, question, isPending)`. Answers go
back as **ordinary user turns** — the chosen label, exactly what the user would have typed. No
side channel, so the transcript stays honest and reads correctly on resume or reopen.

The prompt is deliberately narrow about when to use it — two to four options, only at genuine
decision points, no "something else" option because the user can always just type. A model that
reaches for a picker every turn is worse than one that never does: the whole value of the card is
that it means *this is a real decision*, and that signal dies if it fires on rhetorical questions.

This is a **cooperative protocol, not an enforced one**. If the model writes prose instead,
nothing breaks. If the JSON is malformed, the raw block is deliberately left visible rather than
swallowed — a question that silently vanishes is far worse to debug than one that renders as ugly
JSON. Recorded as **ADR-010**.

### Verified end to end before the UI existed

Prompt, against a live session:

> I want to add caching to my API. Should I use Redis or in-memory? Ask me to choose.

The model produced a sentence of prose and then a well-formed block. That exact response is now
the fixture in `QuestionProtocolTests` — including the leading prose, because the prompt permits
it and the parser therefore has to keep it.

### Where it lives, and why that's the interesting bit

`AgentQuestion` and `QuestionProtocol` are in **AgentKit**, not the `Iris` target. They're pure
parsing with no UI in them, and AgentKit is the target the test suite can see — the `Iris` target
is `@MainActor` SwiftUI and SwiftPM won't let an executable target be a test dependency. That
placement is the entire reason there are **8 tests** here when the sidebar work in part two shipped
with zero.

The rule that generalises: *if a piece of logic is worth testing, the placement decision is the
testability decision.* Splitting text is not UI, so it doesn't live with the UI.

### A test caught a real bug: synthesized `Decodable` ignores default values

```swift
public var multiSelect: Bool = false
```

That reads like "defaults to false when absent". It does not. Swift's synthesized `init(from:)`
calls `decode(_:forKey:)` for any non-optional property regardless of its default, so a payload
omitting `multiSelect` **throws** — and the throw is caught by `split`'s `try?`, so the question
doesn't fail loudly, it just doesn't appear. No error, no log, no card.

Hand-written now, using `decodeIfPresent`:

```swift
public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    question = try container.decode(String.self, forKey: .question)
    options = try container.decode([Option].self, forKey: .options)
    multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
}
```

Which is the same permissive-decoding rule the stream-json decoder has followed since Phase 1,
applied to a payload that comes from a model rather than from the CLI. Model output drifts at
least as much as an undocumented protocol does.

### …and the same bug is still in the repo, three files away

Found while writing this entry. `SidebarLayout` gained a field in the same commit:

```swift
struct SidebarLayout: Codable, Equatable, Sendable {
    var enabled: [String]
    /// Decoded with a default so layouts written before this field existed still open.
    var isVisible: Bool = true
```

That comment states the belief the commit *disproved* two files earlier. A `sidebar.json` written
by any build up to `63d6b70` has no `isVisible` key, so decoding throws, and the registry's
`stored ?? .default` swallows it:

```swift
let stored = (try? Data(contentsOf: Self.fileURL))
    .flatMap { try? JSONDecoder().decode(SidebarLayout.self, from: $0) }
…
let source = stored ?? .default
```

The consequence is not a crash — it is a silent reset to `["notes", "prompt-improver"]`. Anyone
who had rearranged their panel loses the arrangement once, on first launch of this build, with no
message. Low severity, self-healing after the next change, and a genuinely good illustration of
how a lesson can be learned and written down in one file while the same mistake ships in another
in the same commit. Left as a **loose end**, not patched here — this pass is documentation only.

---

## Five — the composer and the send arrow (`c428a81`, `3a48e41`)

Cody:

> the text in the text box is a little high in the chat bar. Align it correctly, not just by
> adjusting pixels, but the correct way. Same for the send arrow.

"Not just by adjusting pixels" turned out to be the whole assignment, and both halves failed in
the same way for different reasons.

### The composer: two invisible insets

`TextEditor` hides the two values that decide where the first glyph lands:

- `NSTextView.textContainerInset`
- `NSTextContainer.lineFragmentPadding` — **5 pt by default**

Neither is reachable through SwiftUI. So the composer had accumulated two numbers tuned by eye to
cancel insets nobody could see: `.frame(minHeight: 20)` on the editor, and
`.padding(.leading, 7)` on the placeholder overlay to keep it off the caret.

`ComposerTextView` wraps `NSTextView` directly and zeroes both:

```swift
textView.textContainerInset = .zero
textView.textContainer?.lineFragmentPadding = 0
```

Two things fall out, and neither is a tuned number:

**The placeholder needs no offset at all.** It now shares an origin with the first glyph *by
construction*, because both are drawn in the same coordinate space at the same font. The
`.padding(.leading, 7)` is gone, not replaced with a better 7.

**Height comes from the typeface.** One line, straight from the font metrics:

```swift
static func lineHeight(for font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
}
```

At 13.5 pt that is about 16 pt — so the old `minHeight: 20` was roughly **4 pt taller than a
line**. And because `NSTextView` lays text out from the top, all 4 pt of slack fell *underneath*
the text. That is exactly, mechanically, why it looked high. The symptom was vertical
mis-centring; the cause was a height that had nothing to do with the font.

Live height is `min(max(usedRect.height, lineHeight), maxHeight)`, floored at one line because an
empty text view lays out to **zero**, not to one line — without the floor the composer collapses
when you clear it.

Two implementation details that cost real time and are worth the next person's five seconds:

- `updateNSView` only assigns `textView.string` when it actually differs. Assigning it collapses
  the selection, so writing it every update pass fights the caret on every keystroke.
- Submit is handled in `keyDown`, not `doCommandBy(_:)`, because the delegate callback carries no
  modifier flags — there is no way to tell ⌘↵ from ↵ inside it, and plain ↵ has to keep inserting
  a newline.

Recorded as **ADR-011**.

### The send arrow: three measurements, two of them wrong

`docs/research/sf-symbol-glyph-centering.md` already existed from 2026-08-08. It concluded that
`arrow.up`'s ink sits off-centre in its own design box, and that the fix was
`.offset(x: -1, y: -1)` — while admitting in its own heading that this was **"not a real fix"**:
an eyeballed correction against a screenshot, valid for one glyph at one size and weight.

Measuring it produced a worse verdict than the note's own disclaimer.

**Attempt 1 — rasterize `NSImage(systemSymbolName:)`.** Reported every symbol at roughly a
quarter of the box off-centre. Which is nonsense, and was caught immediately because `stop.fill`
is a symmetric filled square and *must* measure zero. The bug: drawing at point size into a
2×-pixel bitmap, so the glyph filled the bottom-left quadrant. **Having a case whose correct
answer is known in advance is what made this a five-minute detour instead of a wrong conclusion.**

**Attempt 2 — fix the draw rect.** Now `arrow.up` reported `(+0.25, 0)` and `stop.fill` reported
exactly `(0, 0)` — matching the research note's symmetric-contrast case, and looking like a clean
confirmation of the note's story. It was still the wrong question. `Image(systemName:)` does not
draw an image. It lays a glyph out on a **text baseline** inside a line box built from the font's
ascender and descender. Measuring the image asks about a box SwiftUI never uses.

**Attempt 3 — rasterize the actual SwiftUI view** with `ImageRenderer` at 4× scale, scan the
alpha channel for the ink's bounding box, compare its centre against the frame's:

```swift
let renderer = ImageRenderer(content: content)
renderer.scale = 4          // a quarter-point of asymmetry is still a whole pixel to find
```

Result: **`arrow.up` in a 42 pt frame measures exactly `(0.000, 0.000)`.** Every symbol in the app
lands within ±0.125 pt of dead centre.

> The `-1, -1` was not correcting an off-centre glyph. It was **creating** one — pushing a
> perfectly centred arrow up and left by a full point.

The research note's premise, its fix, and its takeaway were all wrong, and the note is honest
enough that its own hedge ("check against a screenshot rather than assuming") is what kept the
error alive: checking against a screenshot is how the offset got there.

`SymbolInk` keeps the measurement rather than hardcoding the zero, with a threshold:

```swift
/// Below this, a correction is measurement noise rather than a real asymmetry, and
/// applying it would only push the glyph onto a fractional pixel and blur it.
private static let threshold: CGFloat = 0.25
```

Sub-quarter-point offsets are snapped to zero. Applying one would land the stroke off the pixel
grid, so a "more accurate" offset renders *worse*. Results are cached per
(name, size, weight, side).

### Then it was still wrong, and for a completely different reason

After all that, Cody reported the arrow was still off — **but only before typing**.

Both states were screenshotted and measured directly with PIL: find the white glyph, scan outward
to the glass circle's edge, compare centres.

| state | circle diameter | arrow offset from circle centre |
|---|---|---|
| empty, `.scaleEffect(0.9)` | 36 pt | **+1.75 pt right, +2.25 pt down** |
| with text, scale 1.0 | 39 pt | +0.00, +0.50 pt |

First hypothesis: scaling a 42 pt button by 0.9 gives 37.8 pt, and a glyph inside a fractional
frame lands off the pixel grid. Plausible, testable, and **wrong** — rendering the glyph alone
under the same 0.9 scale moves it by **0.062 pt**, two orders of magnitude short of 2.25 pt.

So the glyph isn't what moves. The arrow and the glass circle simply **don't scale about the same
point**: `.scaleEffect` sat outside `.glassEffect` in the modifier chain, and the two transforms
resolve against different geometry. The content slides within the shape.

The fix expresses the idle size as a **frame** change instead of a transform:

```swift
private var side: CGFloat { hasText || isBusy ? 42 : 38 }
```

38 → 42, both whole points, animated on `value: side`. Content and glass stay in one geometry;
the resting sizes stay on the pixel grid. `CenteredSymbol` measures for whichever side is in use,
and both measure exactly zero.

**The general finding, which is Liquid Glass and not SF Symbols:** `.scaleEffect` applied around
a `.glassEffect` decouples the content from the glass shape. Animate the frame, not the
transform, when a glass control changes size. Filed into
`docs/research/liquid-glass-api.md`; `sf-symbol-glyph-centering.md` has been rewritten to record
that its own conclusion was refuted, rather than being quietly deleted.

Three explanations, in order: *the glyph is asymmetric* (false), *the scale knocks it off the
pixel grid* (false, by two orders of magnitude), *the glass and the content don't share a
transform origin* (true). Every one of them was obvious at the time.

---

## Six — the sidebar opens by default (`c428a81`)

`SidebarLayout` gained `isVisible`, persisted with the rest of the layout, and the rail is out on
first run. The reasoning, from the source: the tools are the reason this app isn't a terminal, so
hiding them on first launch buries the feature behind a shortcut nobody has been told about.

(The decode-default bug in that same field is written up in section four.)

---

## Seven — slash commands stop vanishing (`0a557f0`)

Cody asked whether Claude Code slash commands work in Iris. Both kinds were tested through a live
bridge on 2.1.226 rather than reasoned about.

**Skill and plugin commands work untouched.**

```
/git-workflow what is the branch naming convention?
→ expands to its prompt, reaches the model, answers from real skill content
→ ttft 1914ms · dispatch 41ms
```

Nothing to intercept — the CLI expands them into a prompt before the model ever sees them, and
that expansion happens in print mode too.

**Built-in CLI commands are silently swallowed.**

```
/context
→ ttft 0ms · dispatch 0ms · $0.0000 · no content whatsoever
```

Recognised by the CLI, never sent to the model, nothing emitted. They are features of the
interactive TTY — `/context`, `/cost`, `/status` render into a terminal that print mode doesn't
have. In Iris this read as a message sent to a dead session: you type, the turn completes, and
nothing at all happens.

Note that ttft `0ms` / dispatch `0ms` / `$0.0000` is a genuinely useful signature. The CLI is not
failing; it is succeeding at consuming the input.

### Handled two ways, and only one of them is a list

**`/clear`, `/model`, `/effort` are handled locally** and never reach the CLI, because Iris has
real equivalents for all three — `/clear` restarts the session and empties the transcript,
`/model` and `/effort` drive the same `applySettings` path as the picker.

**Everything else is caught by behaviour, not by a hardcoded list of built-ins:**

```swift
/// Detected by behaviour rather than by a hardcoded list of built-ins: any `/command`
/// that completes having emitted no text, no tool call and no reasoning was consumed by
/// the CLI. That stays correct as the CLI's command set changes.
```

It hooks the existing empty-turn cleanup: the session already removed a trailing assistant
message with no text, no tool calls and no thinking. If the turn that produced that emptiness
started with `/`, it was a swallowed command, and Iris says so. The message names the distinction
rather than just apologising:

> `/context` is an interactive Claude Code command — it doesn't run in a print-mode session, so
> nothing happened. Skill commands like `/git-workflow` do work here.

Enumerating the CLI's built-ins would be correct today and wrong at the next release. Recognising
*the shape of the failure* stays correct as the command set changes. Recorded as **ADR-012**.

### A new message role

`ChatMessage.Role` gained `.note` — Iris speaking as the app rather than as the agent. Rendered
as a quiet centred line with an `info.circle`, **deliberately not in glass**:

> anything wearing a message bubble reads as something Iris said, and these aren't.

That is the same principle as the auth indicator refusing to claim subscription before it has
evidence: the UI must not attribute words to the model that the model didn't produce.

---

## Eight — an icon, and a real install (`3a48e41`)

The icon is the concentric-ring mark from `GlassEmptyState` — the thing above Iris's name on an
empty transcript — **generated from the design tokens** by `tools/make-icon.swift`, not exported
from a screenshot.

The argument, which generalises past icons: the motif's source is three numbers in
`DesignTokens.swift`. A PNG cropped out of a running window is a 312-pixel-wide *copy* of those
numbers. It goes soft the moment it is scaled to 1024, and it goes stale — silently — the moment
the palette changes. The script renders each of the ten iconset sizes natively via `ImageRenderer`,
so `make icon` regenerates a correct icon after any palette change.

One size-specific detail: stroke width is `max(outer * 0.038, 1)`, floored at a full point, so
16 pt and 32 pt still show three distinct rings instead of a grey smudge. A stroke that reads
correctly at window scale disappears in a Dock icon.

Verified: the 1024 output shows three symmetric rings in the app's colour order (agent cyan, ice
white, deeper cyan-teal — `Tok.Palette.spectrum`, same sequence as the window).

### `make install`

Builds release, ad-hoc signs, and copies to `/Applications`. Verified running from there.

The signature deserves precision, because "signed" implies things that aren't true here:

- It is **ad-hoc** (`codesign --sign -`), **not a Developer ID**, and **not for distribution**.
- It exists so macOS has something stable to attach **TCC grants** to. An unsigned bundle has no
  stable identity, so permission grants don't stick to it.
- It **changes on every rebuild**, so permission prompts may recur after a re-install.
- Distribution to another machine would need a paid Apple Developer account and notarization.
  That is a real cost and it is not paid.

The target also quits a running copy before replacing the bundle (replacing it underneath a live
process leaves that process running against files that no longer exist) and re-registers with
Launch Services so Spotlight and the Dock pick up the new bundle immediately rather than at the
next rescan.

`Info.plist` gained `CFBundleIconFile` and **`NSMicrophoneUsageDescription`** — the latter was
flagged as a blocker in `docs/research/voice-mode-feasibility.md` and costs nothing to have in
place ahead of a feature that may never ship.

---

## State at `3a48e41`

- Branch `dev`. **`make test`: 48/48, 0 failures** (verified). Up from 37 at `63d6b70`: **+8**
  `QuestionProtocolTests`, **+3** auth-status tests in `OneShotQueryTests`.
- `make build` clean; app rebuilt, installed to `/Applications`, and running from there.
- **Cody considers the app ready for daily use.** That is the first time that's been true, and it
  is the answer the portfolio piece and the video have both been holding a TODO open for.

### Phase 4

| Item | State |
|---|---|
| Persona wizard | ✅ `6c5a663`, ADR-007 |
| Sidebar runner | ✅ `5d3947b` / `cdb0e09`, ADR-008 |
| Sidebar tool system + four tools | ✅ `63d6b70`, ADR-009 |
| File path picker | ⬜ |
| Project switcher | ⬜ |

Phase 5 (subagent tree, session library, diff-approval UI) not started.

Everything in this batch is off-plan — none of it is a Phase 4 line item. Buttons you can hit, a
model picker, an auth indicator, questions, slash commands and an icon are what the plan didn't
have because the plan was written before anyone used the thing. Worth saying plainly rather than
retrofitting them into a phase: **an evening of "make it usable" is not a detour from the plan,
it is the part a plan can't contain.**

### Loose ends

1. **`SidebarLayout.isVisible` has the exact `Decodable`-default bug this batch fixed
   elsewhere.** A pre-`c428a81` `sidebar.json` decodes to nil and silently resets the layout to
   the default. One hand-written `init(from:)` fixes it. (Section four.)
2. `SidebarRegistry`'s unknown-id filtering is still untested — carried over from part two, and
   still the most testable piece of `Iris`-target logic.
3. The question protocol has no test that the *system prompt as sent* reaches the model intact
   through `--append-system-prompt` alongside the persona; the two are joined with `\n\n` and only
   the joining is exercised.
4. Ad-hoc signing changes identity on every `make install`, so TCC prompts recur. Fine for one
   machine; it is the thing to fix first if Iris is ever handed to anyone.

---

## The shape of the evening

Part one of the day ended on *the honest number was the one the instrument wasn't reporting.*
Part two on *a latency you can't remove becomes a design input.*

This one is a third thing, and it's less comfortable than either:

> **Measuring doesn't just fill in blanks — it overturns explanations you already had.** The
> arrow had a documented cause, a written-up fix and a research note. All three were wrong, and
> the note's own recommendation ("check it against a screenshot") is what kept them alive for a
> day.

The pattern repeated three times in ninety minutes with three different mechanisms:

- **The arrow.** A confident, plausible, written-down cause. Refuted by rendering it at 4× and
  looking at the alpha channel. Then the *replacement* explanation was refuted too, by a control
  measurement that came in 36× too small.
- **The auth chip.** The obvious fix was patience. Eight seconds of silence proved patience was
  not on the menu, which is what made the search widen far enough to find an undocumented
  command.
- **The buttons.** "This button is broken" had two causes, not one, and the second (no pressed
  state) is what turned the first (a small hit area) into a reputation.

The instrument that keeps working is the **control case** — `stop.fill` must measure zero, the
bare glyph must move if scaling is the culprit. Twice tonight a measurement was thrown out
because a known-answer case came back wrong, and both times the buggy measurement would otherwise
have confirmed a wrong story.

> A measurement that can only confirm you is not a measurement. Always include the case whose
> answer you already know.

---

## Why this is a separate file

`2026-08-09-measuring-before-building.md` covers the same calendar date and is already 662 lines
across two parts, ending on a written conclusion for the whole day. Appending a third part would
mean either stranding that conclusion mid-document or rewriting it.

More importantly the subject changes. That entry is about **cost and architecture** — what a
one-shot call costs, why the runner is a separate type, what nine seconds does to a component's
design. This batch is about the app becoming **usable**, and its findings are UI-mechanical and
CLI-surface findings rather than cost ones. Two entries with distinct spines read better than one
with three.

They cross-reference each other. Read in order: cost, then the sidebar, then this.
