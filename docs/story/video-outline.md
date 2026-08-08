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

## Glass (12:00–15:00)
The API-hunting anecdote — wrong framework, wrong arch, two empty greps. Then what
`glassEffectID` + `glassEffectUnion` actually do. Build the morph on screen. This is the
visual payoff; give it room and shoot it well.

## The verdict (15:00–17:00)
Head-to-head against the terminal. Did it become the daily driver? **Answer honestly.**
TODO — cannot be written until Phase 2 ships.

## Outro
Lessons, repo link. Note it's an independent project, not an Anthropic product.

## Notes
- Highest-value B-roll is the glass morph and the subagent tree — capture generously.
- Resist making it a tutorial. The story is the reversals, not the API calls.
