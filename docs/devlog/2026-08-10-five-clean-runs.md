# 2026-08-10 — Five clean runs, and a bar that refuses to guess

*One commit. Five changes asked for in a single message: Return sends, a usage bar under the
composer, one Tools button instead of two, a rendering bug shown in a screenshot, and window
dragging that had quietly eaten text selection.*

The through-line this time is what happens when you **can't** reproduce a bug, and what
happens when the number a feature needs **doesn't exist**. Both came up in the same batch, and
they pull in opposite directions: one says ship a repair for something you never saw fail,
the other says refuse to ship a feature you could easily fake.

---

## The bug that wouldn't reproduce

Cody's screenshot showed the prompt improver's Rewrite panel rendering this:

```
three changes:\n\n**1. Input keybindings:**\n- Return key sends the message (call the
existing send function).\n- Label it \"Tokens used: X / Y\" where X is current tokens…
```

Literal `\n`, and literal `\"`. Both, together. That pairing is diagnostic: it's exactly what
a JSON string looks like *before* it's decoded, so the value reaching the view had a real
backslash in it, not a real newline.

Which shouldn't be possible. `--json-schema` output arrives in `result.structured_output`,
already parsed, and Iris runs it through `JSONDecoder` — a `\n` the model wrote correctly is a
newline by the time anything in the app sees it. The only way to get a backslash back out is
for the model to have escaped its own escapes: emitting `\\n` into the tool call.

So: reproduce it. Same model, same schema, same system prompt, same shape of prompt — five
runs, including two with Cody's exact text and three engineered to contain quotes, because a
model is likeliest to over-escape when the content it's escaping already has quotes in it.

```
run 1: literal-bsn=0 real-nl=16
run 2: literal-bsn=0 real-nl=17
run 3: literal-bsn=0 real-nl=0
run 4: literal-bsn=0 real-nl=0
run 5: literal-bsn=0 real-nl=15
```

Five clean runs. Never caught it.

That result changes what the fix should be, rather than closing the investigation. An
intermittent model behaviour can't be prompted away — you can ask for correct escaping and be
obeyed 95% of the time, which is exactly the current situation. But it *is* trivially
detectable after the fact, because a correctly-decoded multi-line string contains real control
characters. Escape sequences present, and the characters they stand for absent, is a
signature.

`String.repairingDoubleEscapedJSON` reverses exactly one layer, and only on that signature:

```swift
guard contains(#"\n"#) || contains(#"\t"#) || contains(#"\""#) else { return self }
guard !contains("\n"), !contains("\t") else { return self }
guard let data = "\"\(self)\"".data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data) else { return self }
return decoded
```

Re-parsing as a JSON string body rather than pattern-replacing is what makes it safe: `\n`,
`\t`, `\"` and `\\` all come back correct together, and anything that *isn't* valid at that
level — a bare quote, a dangling backslash — fails to parse and returns the original
untouched. Seven tests, including the two failure modes and one that pins the **known false
positive**: a single-line string that merely mentions `\n` gets rewritten. That's recorded as
a test rather than as a caveat in a comment, because it's a real trade and someone should be
able to reverse the decision by deleting a test that says so out loud.

Applied at decode, not at render, so the Copy button hands over repaired text too. The rewrite
is a thing you paste somewhere; shipping it with visible `\n` runs is shipping a broken
prompt.

---

## The number that doesn't exist

"Show usage percentage bar below the chat bar as well." Iris's own prompt improver, run on
that same message, had already flagged it: *"Vague success metric: 'usage percentage'
undefined."* Two readings — quota, or context — and they answer different questions.

Quota was the intuitive one, and `docs/plan.md` had recommended it back in Phase 0:
`rate_limit_event` is *"better than a cost meter — a real quota gauge with a reset
countdown."* Going back to the captured event to build it:

```json
{ "status": "allowed", "resetsAt": 1786167000, "rateLimitType": "five_hour",
  "overageStatus": "rejected", "isUsingOverage": false }
```

A state, a deadline, two flags. **No percentage.** No `claude usage` subcommand either — the
CLI has thirteen subcommands and not one of them reports consumption. Building the bar Cody
asked for, from quota, would mean estimating against a limit the client is never told, and
drawing it as a confident fill.

Context is measured exactly, from the same `result` event, and got built instead. The full
reasoning is in [ADR-012](../decisions/ADR-012-context-not-quota.md); the
part worth repeating here is the denominator:

```swift
r.modelUsage[stats.model]?.contextWindow ?? r.modelUsage.values.compactMap(\.contextWindow).max()
```

`modelUsage` carries more than one model — the CLI makes its own small Haiku calls beside the
session's. Opus's window is 1,000,000, Haiku's is 200,000, and it's cumulative across the
session while the top-level `usage` block is per-turn. So the naive picks are all wrong in
different ways: `.first` is arbitrary, sorting by output tokens gets turn one wrong (the
cumulative Haiku entry, at 14 output tokens, outweighs Opus's 5), and `.max()` is right by
luck. The only defensible key is the model id `system/init` named.

The plan's Phase 0 note was annotated rather than deleted. It was a good call about a good
event; it just described a gauge that the payload can't support.

**And then the bar came out.** *"Have the context percentage be another little pill like the
others with just a percentage number, no bar or chart."* Right, and the argument for putting it
under the composer — it's the number that should change what you type next — survived exactly
as long as it took to see it on screen. A progress bar is a shape for a quantity you watch
move; it earns its width by making a *rate* legible. Context steps once per turn and then sits
still. What the bar actually added was a second row of chrome and a horizontal rule that read
as a divider.

It's a chip now, beside quota, with the tokens/window detail in the tooltip where every other
chip already keeps its detail. A **session** chip went in next to it from the same event:
cumulative tokens, with turns and the four-way in/out/cache-write/cache-read breakdown on
hover. Two things worth writing down about that one:

- `modelUsage` is **already session-cumulative**, so the totals are assigned, not accumulated.
  Adding to them would square the count by the third turn.
- Turns are counted client-side. `result.num_turns` describes the run that just finished — it's
  `2` for a forced-tool-call run — not the conversation.

The headline session number is mostly cache reads, and that's left as-is rather than netted
out. Every turn re-sends the whole conversation; it's cheaper, not free, and it draws on the
same pool as everything else.

### And then the number that didn't exist turned out to exist

*"Wrong session. That yellow bar in the screenshot. How much of my limit I've met before my
usage reset. That's what I want to see."* — with a photo of his own terminal status line:
`5h [████░░] 65% 2h 47m left · $77.80 · 7d 55%`.

Everything written above about quota is still true and was still the wrong conclusion. Print
mode has no percentage — re-verified live rather than trusted from the fixture, and the full
list of event types a `-p` session emits was enumerated to be sure. What it missed is that
**print mode is not the only way to ask.** The numbers are sitting in the JSON payload the CLI
pipes to a `statusLine` command:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 72, "resets_at": 1786342800 },
  "seven_day": { "used_percentage": 55.00000000000001, "resets_at": 1786413600 }
}
```

So `QuotaProbe` borrows the mechanism: a short interactive session under a pty, with
`statusLine` overridden to a script that dumps its stdin, killed the moment the payload
contains `rate_limits`. Three constraints, each found by hitting it:

- **`statusLine` is never invoked in print mode** (tested directly, not assumed).
- **Interactive needs a pty** — otherwise `script: tcgetattr/ioctl: Operation not supported on
  socket`. Hence `/usr/bin/script -q /dev/null`.
- **`rate_limits` is absent until the session has made an API call.** An idle session's payload
  has no such key. The numbers come from response headers, so the probe has to say one word and
  wait for a later render.

And a fourth that isn't about the mechanism: interactive sessions won't start in an untrusted
folder, and a trust prompt in an unattended pty is a hang. Iris reads
`~/.claude.json` → `projects[path].hasTrustDialogAccepted` to find a folder the user has
already trusted. It does not flip the flag and does not answer the prompt — trusting a
directory grants file access, and that decision isn't Iris's to make.

Cost, measured both ways:

| launch | cache creation | in / out | wall |
|---|---|---|---|
| interactive defaults | 7,555 | 10 / 166 | ~5 s |
| stripped, as shipped | **0** | 1,132 / 133 | ~4 s |

The flag interaction that makes the second row possible: **`--setting-sources ''` does not
disable `--settings`.** The status-line override survives while `CLAUDE.md`, skills, plugins and
MCP config are dropped. Tested, because if it had gone the other way the probe would pay 7.5k
tokens every reading.

**The lesson, and it's the sharper one of the day:** "the data isn't available" was really "the
data isn't available *through the interface I was already using*." Those are different claims,
and the first one had already been written into an ADR and the plan. Both now carry the
correction rather than a quiet edit. Refusing to *invent* a quota percentage was still right —
it's why the number on screen today is measured and costs a turn, rather than estimated and
free.

It spends what it measures, so: read at launch, then at most every 15 minutes, click the chip
to force a refresh, and the tooltip shows the reading's age rather than implying it's live.
`make harness ARGS="-q"` runs it standalone. Full write-up in
[`docs/research/quota-percentages.md`](../research/quota-percentages.md).

---

## Return sends, and the two things that breaks

`⌘↵` had been the send binding since Phase 2, chosen because plain Return had to keep
inserting newlines in a `TextEditor` with no way to distinguish the two. That constraint went
away with [ADR-011](../decisions/ADR-011-own-the-composer-text-view.md) — owning the
`NSTextView` means owning `keyDown`, where modifier flags are visible.

Two details that a naive swap gets wrong:

**Input methods.** During Japanese, Chinese or Korean composition, Return commits the
candidate. Sending there would fire a message containing half-composed text *and* swallow the
commit. `hasMarkedText()` is the documented way to ask whether a composition is in flight, and
it's checked before anything else.

**The numeric keypad's Enter is a different key code** (76, not 36). Someone who sends from
the keypad shouldn't silently get a newline instead.

`⇧↵` and `⌥↵` both insert the newline; `⌘↵` still sends, because it was documented and
costs nothing to keep. The send button itself is untouched, per the ask.

---

## One Tools button, and a window that stopped stealing drags

Two separate complaints with one shared cause: the chrome had grown by accretion.

The Tools toggle existed **twice** — once at the sidebar panel's top-right, which vanished
along with the panel it was closing, and once in the status bar, which is where you had to go
to bring it back. Two controls for one piece of state, neither of them where the other was.
There is now one, in a new title strip, pinned to the window's trailing edge — the same place
as the rail's trailing edge, so it reads as belonging to the panel while the panel is out and
doesn't move when it isn't.

### Three versions of "the button doesn't move"

The first version put it in the title strip and left it there. Opening the rail dropped it
37 pt, because the panel header is a row *below* the strip. Cody, with screenshots: *"see how
the button drops lower after I open the side bar?"*

The second version moved it deliberately — one view with two homes, carried between them by a
shared `matchedGeometryEffect` id, so it flew from the strip down beside the `+`. Smoother, and
still the wrong answer to the question. Cody again: *"almost like a menu bar button… the button
remains stationary, and the side bar opens right over it."*

The third version is the one that's right, and it's smaller than either. **The button is pinned
to the window's top-right corner as an overlay and belongs to no layout container at all.** Not
the transcript column, not the panel header. Nothing lays it out, so nothing can push it, and
there is no animation to get right because there is no movement to animate.

Everything else follows from that:

- The panel now reaches the very top of the window, so its header row occupies the same band
  the button already occupies. The title strip moved from the full-width VStack into the
  transcript column alone.
- The header **reserves** the button's footprint rather than laying it out —
  `Tok.Space.base + ToolsToggleButton.side + Tok.Space.tight` of trailing padding — so the `+`
  lands a normal row-gap to its left. Derived from the button's own size, not measured off a
  screenshot.
- The header is `.frame(height:)` at the band height, not `.padding(.vertical:)`. Padding makes
  a row's height depend on its tallest child, so the two centrelines would have agreed by
  coincidence and drifted the first time anything in either row changed size. One constant,
  `titleStripHeight`, is the drag band, the button's row, and the header's height — because the
  claim "it doesn't move" *is* the claim that those three are the same band.

The version I'd argued against — hoisting the header into the strip — turned out not to be the
alternative. That would have split the rail into two independently animated pieces. Taking the
button *out* of the layout instead leaves the rail as one piece and removes the animation
entirely.

**One trap on the way.** The transcript column's strip was first written as
`Color.clear.frame(height:).background(WindowDragStrip())`. `Color` is hit-testable in SwiftUI,
so it would have claimed the mouse-down before the `NSView` underneath ever saw it — silently
disabling the one view whose entire purpose is to receive that event. The representable sizes
itself directly instead.

The drag problem was `window.isMovableByWindowBackground = true`, set in Phase 3 to make a
titlebar-less window movable. It grants the *whole* window, and the decision is made before a
drag can be recognised as a text selection — so dragging across a message to select it moved
the window instead, every time, with no way for the text view to win. Cody: *"the window
doesn't seem to know when I'm highlighting or not."* It genuinely doesn't; the question is
never asked.

The fix is to scope the grant rather than fight it. AppKit asks the view under the pointer
whether a drag starting there should move the window, so answering `true` in exactly one small
`NSView` and nowhere else confines dragging to the strip:

```swift
private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
```

It sits *behind* the strip's contents, not over them, so the Tools button keeps its own clicks
and only the empty space around it drags.

---

## Deleting the field is cheaper than defending it

Later the same day, after using it: *"I don't want the tips. I just want it to return a better
prompt with a copy button. Remove the tips entirely, I don't want wasted tokens on it."*

The prompt improver had three output fields — a 1–10 score, a list of issues, and the rewrite —
and by then the score had accumulated four separate defences: `minimum`/`maximum` in the schema,
a `clampedScore` for display, a `scoreOutOfRange` badge for when the bounds didn't hold, and a
colour ramp. All of that existed because of the fixture containing `"score": 15`, which the panel
had rendered as a confident green **15/10**.

`PromptRewrite` has one property. The schema has one key. All four defences are gone, not
improved.

Measured on the two test prompts, old schema and prompt versus new, same model:

| prompt | output tokens | duration |
|---|---|---|
| "make the login page better…" | 795 → **544** | 9.5 s → **6.6 s** |
| "refactor the api…" | 1,084 → **663** | 12.4 s → **7.6 s** |

About a third off both, and the panel is more useful, because the thing you actually wanted was
never more than one scroll down. The system prompt still *names* the defect classes to fix —
that's what makes the rewrite good — it just forbids reporting them.

One cost, recorded in [`docs/story/assets.md`](../story/assets.md): the "green 15/10" screenshot
was on the asset list flagged **expiring**, and it expired unshot. The flag was right about the
mechanism and wrong about the deadline — it predicted the shot would vanish when the schema was
tightened, and it vanished when the field was deleted for an unrelated reason. The fixture is
committed, so the evidence survives; only the framing was lost.

## Not verified

The Tools button sits inside the band where a hidden titlebar still draws its traffic lights.
The evidence says clicks pass through — the old sidebar header buttons lived at that height
and worked once `GlassControlStyle` gave them a real hit area — but that's inference from a
neighbouring case, not a measurement of this one. Flagged to Cody rather than asserted, and
`⌘⌥S` still toggles the rail if it turns out to be dead.
