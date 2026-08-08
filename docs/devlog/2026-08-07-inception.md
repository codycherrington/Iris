# 2026-08-07 — Inception, and a spike that changed the plan twice

## Where this came from

Cody has a tool at work: a macOS desktop app that wraps Claude Code in a GUI. Launch it and
it runs a persona wizard — name your assistant, set its personality, tell it your role and
who your boss is. After that you get a Claude Code session flanked by two customizable
sidebars: notes, a prompt improver, a SQL reviewer, a bug checker, a button that copies a
file path out of your directory tree.

He wanted his own, but visually far past it. The brief, more or less verbatim: *run wild with
the customization, make it look really clean and futuristic, SwiftUI with Liquid Glass, crisp
and professional, slick animations.*

## The first framing was wrong

The obvious fork looked like **SwiftUI vs. Electron**, and the first pass at it leaned
Electron hard. The reasoning: Ledger already ships on Electron 43 + React 19 + Tailwind 4, the
whole build and packaging pipeline exists, and across thirty projects there was not one line
of Swift. Electron windows can also use genuine `NSVisualEffectView` vibrancy, so the blur
would be real system material rather than a CSS fake — maybe 85% of the way to Liquid Glass.

Cody pushed back, and he was right:

> I have coded in swift at work, no worries there. Also, I don't know a single programmer
> worried about languages anymore.

That deleted the entire premise of the recommendation. The language was never the cost. Worth
recording because it's a recurring failure mode: weighting "unfamiliar language" as a real
obstacle in 2026, when the actual costs were elsewhere.

## What the actual costs were

Two constraints turned out to decide everything, and neither was about syntax.

**1. Subscription only.** Cody: *"This can only use my subscription I'd rather not use an API
that costs money."*

The Claude Agent SDK is TypeScript and Python only — there's no Swift binding. That initially
read as a point against SwiftUI. But the SDK's own documentation says: *"Unless previously
approved, Anthropic does not allow third party developers to offer claude.ai login... Use the
API key authentication methods."* So the SDK path leads to per-token billing.

Meanwhile the documented escape hatch for other languages — run the CLI as a subprocess —
turned out to be the *only* path that satisfies the constraint. From the headless docs, on
`--bare` mode: *"bare mode doesn't use your subscription login"* and *"In bare mode, Claude
Code never reads OAuth credentials or the system keychain."* Which means **non-bare `claude -p`
does** read them.

So the constraint that looked like it ruled SwiftUI out actually ruled *Electron + SDK* out.

**2. Don't be slower than the terminal.** Cody: *"if this ends up being noticeably slow and
clunky interfering with my use of AI as opposed to sticking with the terminal interface, I'm
ok with that."* Which is to say: he'd rather abandon it than use a worse tool every day.

That made performance a gate rather than a polish item, and it's why Phase 0 exists with an
explicit kill criterion instead of jumping straight to building something pretty.

## Xcode, and checking before claiming

Early exploration found macOS 26.5 (Tahoe) but **no Xcode** — only Command Line Tools pinned
to the macOS 15.2 SDK. `glassEffect` simply wasn't there. Cody installed Xcode mid-conversation,
after which:

```
xcrun --show-sdk-version          → 26.5
swift --version                   → 6.3.3, target arm64-apple-macosx26.0
```

The Liquid Glass API surface was then confirmed by grepping the actual SDK rather than
trusting memory — and it wasn't where expected. `SwiftUI.swiftinterface` has only
`GlassButtonStyle` / `glassProminent`. The real API lives in **SwiftUICore**, under
`Versions/A/Modules`:

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
struct GlassEffectContainer<Content: View>: View
```

Available `macOS 26.0+`. The `glassEffectID` + `glassEffectUnion` pair inside a
`GlassEffectContainer` is what produces fluid merge/split morphing — so that's the animation
vocabulary for Iris, not just a blur treatment.

Two intermediate greps returned empty and nearly produced a wrong "Liquid Glass isn't fully
available" conclusion. The arch was `arm64e`, not `arm64`, and the framework path had a
`Versions/A` component. Worth remembering: an empty grep is not evidence of absence.

## The spike

Half a day, throwaway, in a scratch directory. Five objectives, an agreed kill criterion, and
no repo until it passed.

**Auth.** `system/init` reports `apiKeySource: "none"` with `ANTHROPIC_API_KEY` unset. Not
inference — a field we can assert on at runtime, which is now a hard rule in `CLAUDE.md`.

**Persistence and context.** Three turns down one process's stdin. Turn 2 asked what word it
had been told to reply with; it answered `PONG`. One process, real conversation.

**Performance.** The CLI reports its own timings in `result`, so no client instrumentation
was needed:

| Turn | `ttft_ms` | `ttft_stream_ms` | `time_to_request_ms` |
|---|---|---|---|
| 1 | 1434 | 971 | 20 |
| 2 | 1334 | 761 | 15 |
| 3 | 2285 | 1548 | 7 |

`time_to_request_ms` — per-turn dispatch overhead inside the persistent process — is **7–20 ms**.
Effectively zero. TTFT is dominated by the API round-trip, i.e. identical to the terminal.

The naive wall-clock measurement said 4.98 s for turn 1, which looked alarming until the
breakdown explained it: ~3.5 s of process startup, paid **once per session**, not per turn.
Turns 2 and 3 measured 0.77 s and 1.55 s. The whole architecture rests on that distinction.

**Skills.** Asked what custom skills it had. It answered: `dev-scaffolder, git-workflow,
ledger-tasks, project-inception, youtube-transcript` — exactly Cody's set. Non-bare context
loading confirmed, which means every skill, hook, MCP server and `CLAUDE.md` he already has
works inside Iris for free.

**Permissions — the part that changed the plan.** The plan flagged the native approval UI as
the least-verified piece, expecting it to need `--permission-prompt-tool` backed by a local
MCP server. The spike tested a `Write` under `permissionMode: default`, half-expecting a hang.

It doesn't hang. It emits `system/permission_denied`, returns a `tool_result` with
`is_error: true`, **completes the turn normally**, and puts this in the result:

```json
"permission_denials": [{
  "tool_name": "Write",
  "tool_use_id": "toolu_01Me9CB9xbzFRrVW5TbBxt9i",
  "tool_input": {"file_path": ".../out_default.txt", "content": "hello\n"}
}]
```

The full intended content comes back. So the diff-approval UI needs no MCP server at all:
catch the denial, render a diff from `tool_input`, approve, re-issue. It's deny-then-retry
rather than pause-mid-turn — one extra round trip — but it cannot deadlock the UI, which the
MCP approach might.

## Three undocumented events

None of these appear in the public docs. All three are useful:

- **`rate_limit_event`** — `{status, resetsAt, rateLimitType: "five_hour", overageStatus,
  isUsingOverage}`. On a subscription this is *better than a cost meter*: a real quota gauge
  with a reset countdown. Arrives first, before `system/init`.
- **`system/thinking_tokens`** — `{estimated_tokens, estimated_tokens_delta}`, streamed live.
  A thinking indicator with actual progress instead of a spinner.
- **`system/permission_denied`** — above.

Plus `result.modelUsage`, which breaks down per model and carries `contextWindow` and
`maxOutputTokens` — enough for a genuine context gauge. One three-turn session used *both*
`claude-opus-5` and `claude-haiku-4-5`.

## Protocol gotchas worth pinning

Each of these is now a test in `AgentEventDecodingTests`:

- `system/init` repeats **per turn**, not once per process.
- The buffered `assistant` message arrives **before** `content_block_stop`.
- `total_cost_usd` is **cumulative for the session**, not per turn.
- `parent_tool_use_id` is `null` on the main thread, set inside subagents at every nesting
  depth — following it reconstructs the whole tree, which is what the Phase 5 visualizer needs.

## Where it landed

Repo scaffolded at `Development/Projects/iris`. Because the whole Development tree is iCloud
Drive (`~/Documents` and the CloudDocs path share an inode — worth knowing), SwiftPM's scratch
path is redirected to `~/Library/Developer/Iris/agentkit-build` via the Makefile. That moved
176 MB of build artifacts out of the synced tree; a residual 64 KB of SourceKit-LSP index data
still lives in-repo, gitignored, and is small enough to ignore.

`AgentKit` decodes all five captured fixtures with 13 passing tests, including one asserting
subscription auth and one asserting per-turn overhead stays under 100 ms.

## Open

- `AgentBridge` — the actor wrapping `Process` and pipes. Next up.
- Whether `--permission-prompt-tool` offers true mid-turn pause. The deny-then-retry fallback
  is shippable, so this is an optimization, not a blocker.
- Naming: "Iris" — aperture, and the rainbow messenger. Refraction, which is what glass does.
