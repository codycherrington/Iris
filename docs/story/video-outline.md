# Iris — video outline (draft)

**Status:** beat sheet seeded at inception 2026-08-07. Revise as the build unfolds.

## Cold open (0:00–0:20)
Subagent tree animating in Liquid Glass, glass panels merging. No narration. Hard cut to a
plain terminal scrolling text. Title.

## The stakes (0:20–1:30)
The tool at work: Claude Code in a GUI, persona wizard, two sidebars. Useful, plain.
Then the honest framing — the terminal is *already good*. A GUI has to earn its place.
State the rule on screen: **if it's slower than the terminal, delete it.**

## The wrong turn (1:30–3:00)
Walk through the first recommendation: use Electron, you know the stack, Swift is a cost.
Then the pushback, on screen: *"I don't know a single programmer worried about languages
anymore."* Establish that every assumption is about to flip.

## Constraint one: it has to run on the subscription (3:00–5:00)
The Agent SDK is TS/Python only. Its docs say use API keys. Show the line.
Then the reversal: the "fallback" for other languages is the only path that runs on a
subscription. Show `apiKeySource: "none"` on screen — the proof.

## The spike (5:00–8:00)
**The heart of the video.** Half a day, throwaway, kill criterion written down first.
Show the harness running, NDJSON scrolling. Land on the table. Then the twist: the alarming
4.98 s first turn decomposes into ~3.5 s of one-time startup plus a fast turn. Same number,
opposite conclusion.

## Constraint two: the feature I thought would be hardest (8:00–10:00)
Expected a local MCP server and a deadlock risk. Show the actual result JSON with
`permission_denials[].tool_input` carrying the full file content. Cut to the diff UI it
enables. "The hardest planned feature became one of the easiest."

## Reverse-engineering the protocol (10:00–12:00)
Three undocumented events. On a subscription a quota gauge beats a cost meter. Show
`rate_limit_event` and the gauge it drives; `thinking_tokens` and the progress indicator.
Fixtures as both tests and documentation.

## Fast, and it still felt broken (12:00–14:30)
**The best non-visual beat in the video. Do not cut this for time.**

Set it up honestly: the gate I said was non-negotiable, I skipped. Phase 3 glass work went in
on top of an ungated Phase 2. Show the audit finding it.

Then run the gate. Split screen, terminal and Iris, same prompt, timer visible. Land the
number on screen: **dispatch 43 ms**, against 7–20 ms headless and a 100 ms threshold. The
whole glass UI cost tens of milliseconds. Beat.

Then cut to me using it and saying *"it felt like a stall for a minute."*

Reveal the cause on screen — `send()` sets `isBusy` and appends nothing, so 11.5 seconds of
TTFT showed a blank transcript. Hold on the empty screen for the real duration if the edit can
stand it; the discomfort *is* the point.

Line to land: **"A pure benchmark would have passed and shipped a UI that reads as hung."**

## The feature the protocol deleted (14:30–16:30)
Chasing "show something during those 11 seconds." Show the live capture scrolling. Then the
payload, big on screen:

```json
{"type":"thinking_delta","thinking":"","estimated_tokens":50}
{"type":"thinking","thinking":"","signature":"CAIS4QYKhwEIEBgCKkDL…"}
```

It tells you reasoning happened. It hands you a 1164-character signature over it. It never
gives you the text. Verified twice — live capture and day-old fixtures.

So the collapsible "view reasoning" panel I'd designed was a box that opens on nothing. Show
the three iterations as a quick montage — placeholder bubble → three stacked bubbles →
delete the thinking bubble entirely, reasoning becomes one line in the header:
`● Iris  thinking  50 tokens`, past-tensing to *thought*. **Most build videos add a feature on
discovery. This one removed one and got better.**

## Glass (16:30–19:30)
The API-hunting anecdote — wrong framework, wrong arch, two empty greps. Then what
`glassEffectID` + `glassEffectUnion` actually do. Build the morph on screen. This is the
visual payoff; give it room and shoot it well.

Then the correction, which is more interesting than the demo: `GlassEffectContainer(spacing:)`
fuses **every** sibling pair within that distance. It is not a gap. Show the bug — the tool
chip welded to the answer bubble with a glass tail between them — and the fix, `26 → 0`. Show
three tool chips fused into one unreadable blob by `glassEffectUnion`, the thing I'd pitched
as the payoff of the entire vocabulary. Rule on screen: **fuse things that are one control,
never things you have to count.**

Good place for the cursor-following aurora too: the backdrop leans toward the pointer, 34 pt
max, long spring. Plus the two gotchas — `onContinuousHover` never fires because the backdrop
is under everything, and `window.acceptsMouseMovedEvents` is off by default so the fix does
nothing until you find it.

## The persona that edits itself (19:30–21:30)
**Strongest standalone clip in the project — also cut this as a short.**

The wizard, three steps, ending on the generated system prompt shown verbatim. Explain why
that screen exists: the persona has to be *actual config*, and showing the text is what proves
it. Then the choice — a readable JSON file in Application Support, not `UserDefaults`.

Then do it live on camera: **ask Iris to change its own persona.** Split screen, the agent's
edit on one side and `persona.json` changing on the other. Restart, ask it who it is, get the
new answer back.

The idea underneath, said plainly: the app doesn't own the persona and hand it to the agent —
it's a shared document with two authors, one of whom is the subject. Then the honest cost: it
broke the store's cached copy, and a running session still needs a restart because the system
prompt is a launch argument.

## My own plan was wrong and a measurement caught it (new — place after "the persona")
*(2026-08-09. Budget ~2:30. Callback structure with the spike section; if runtime is tight this
compresses to 90 s and still works, because the payoff is a single sentence.)*

Open on the sentence from my own design doc, on screen, highlighted:

> "…so they never consume the main session's context."

Say plainly that I wrote that, believed it, and never checked it. Then run the two calls, side
by side, on camera — same six-word prompt, one default, one stripped. Land the table:

| | default | stripped |
|---|---|---|
| duration | **32.5 s** | 6.6 s |
| cache-creation tokens | **18,854** | **0** |
| model | **opus-5** (I never asked for that) | haiku |

Beat. Then the line the section exists for:

> **"That sentence is true. And it's exactly why it's expensive. It inherits nothing — so it
> rebuilds everything. Isolation isn't cheapness."**

Then the twist, because the fix isn't the ending: *does this even run on my subscription?*
Show `apiKeySource: "none"`. So the dollar figure was never a bill — it's an estimate. **The
real currency is quota, out of the same pool as the conversation.** A chatty sidebar can rate-
limit the thing you're talking to. The number I'd been optimizing was a proxy for a worse one.

Close on the plan file, annotated rather than rewritten: *"we believed X, here's what we
measured."*

## 35 green tests and a guaranteed crash (new — place immediately after the above)
*(2026-08-09. Budget ~1:30. Fast, technical, satisfying. This is the strongest testing argument
in the video and it needs almost no B-roll — the terminal output carries it.)*

Show the property. It's a plain `Int32`. Nothing about it looks dangerous.

Then the crash, full screen, unedited:

```
*** -[NSConcreteTask terminationStatus]: task still running
Abort trap: 6
```

Explain in one line: it raises an **Objective-C** exception, **Swift cannot catch those**, the
app doesn't throw — it dies. And it lived in the *timeout* handler, which is by definition the
moment the process hasn't exited yet. So every timeout was a crash. **100%. Not flaky.**

Cut to the test suite: **35 out of 35, green**, the whole time.

> "It wasn't a bad test suite. It replays captured JSON through a decoder. There's no process,
> so there's no process lifecycle, so there's no state where this can fail. It was measuring
> something else entirely and had no way to know."

How it was found: I added a `--timeout` flag to the probe *on purpose*, to fire a real deadline
at a real process. Show that command running and dying.

Rule on screen: **fixtures test the protocol; only a process tests the process.**

Optional 15-second tag if the edit has room, because it's a nice bit of type design: the fix
made the error case `noResult(exitCode: Int32?)`. The `?` is the API finally admitting there's a
state where the exit code doesn't exist yet.

## The verdict (21:30–23:30)
Head-to-head against the terminal — the numbers are in now (43 ms, gate passed 2026-08-08).
Did it become the daily driver? **Answer honestly.** TODO — still open.

## Outro
Lessons, repo link. Note it's an independent project, not an Anthropic product.

## Notes
- Highest-value B-roll is the glass morph and the subagent tree — capture generously.
- Resist making it a tutorial. The story is the reversals, not the API calls.
- Runtime is drifting past 20 minutes. If it has to be cut, cut *Glass* down and keep
  **"fast but felt broken"** and **"the persona that edits itself"** — those two are the
  beats nobody else has.
