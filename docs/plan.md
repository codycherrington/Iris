# Native macOS Agent Workbench — SwiftUI + Liquid Glass

## Context

Cody has a tool at work: a macOS desktop app that wraps Claude Code in a GUI. First launch runs a
persona wizard (name, personality, role/boss context). After that you get a Claude Code session
flanked by two customizable sidebars — notes, prompt improver, SQL reviewer, bug checker, a file-path
picker, and more. He wants his own version, but visually far beyond it: SwiftUI, real macOS 26 Liquid
Glass, slick animations, crisp and futuristic.

Three constraints, stated by Cody, that drive every decision below:

1. **Subscription only.** No API-key billing. This is a hard requirement.
2. **Maximum customization.** Hand-coding the chat surface is a feature, not a cost.
3. **It must not be slower or clunkier than the terminal.** He'd rather abandon it than use a
   worse tool daily. So performance is a gate, not a polish item.

### Environment (verified, not assumed)

| Fact | Value |
|---|---|
| macOS | 26.5 (Tahoe) |
| Xcode | 26.5 installed, active SDK = macOS 26.5 |
| Liquid Glass | Available, `macOS 26.0+` |
| `claude` CLI | v2.1.226 at `~/.local/bin/claude` |
| Swift | 6.0.3 |

Confirmed present in `SwiftUICore.swiftinterface` (arm64e-apple-macos):

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition) -> some View
struct GlassEffectContainer<Content: View>: View
// plus .buttonStyle(.glass) / .glassProminent
```

`glassEffectID` + `glassEffectUnion` inside a `GlassEffectContainer` are what produce the fluid
merge/split morphing — that's the animation vocabulary for this app, not decoration.

## Approach

**SwiftUI app driving `claude` as a persistent subprocess over newline-delimited JSON.**

The Claude Agent SDK is TypeScript/Python only — there is no Swift binding. The documented path for
other languages is to run the CLI as a subprocess. That turns out to be the *better* option here,
because it's the one that satisfies constraint #1:

- `--bare` mode "doesn't use your subscription login" and requires `ANTHROPIC_API_KEY`.
- **Non-bare `claude -p` reads OAuth credentials → rides the existing subscription.**

Non-bare also loads the full interactive context: hooks, skills, plugins, MCP servers, memory,
`CLAUDE.md`. So `ledger-tasks`, `dev-scaffolder`, `git-workflow`, and `youtube-transcript` work
inside the app on day one, for free. No Node runtime, no sidecar, single native binary.

Verified from `claude --help`:

- `--input-format stream-json` — *"realtime streaming input"*
- `--output-format stream-json` — *"realtime streaming"*
- `--replay-user-messages` — only valid with both of the above; echoes user messages back for ack
- `--include-partial-messages` — token-level `text_delta` events
- `--session-id <uuid>`, `--resume`, `--fork-session`

Both directions stream over one long-lived process. **No per-turn spawn cost** — this is the single
most important fact for constraint #3.

```
┌──────────────────────────────────────────────┐
│ SwiftUI (macOS 26)                            │
│  LeftRail │ ChatTranscript │ RightPanel       │
│                  ▲                            │
│                  │ @Observable SessionModel   │
│                  ▼                            │
│  AgentBridge (actor) — Process + 3 pipes,     │
│                        NDJSON codec            │
└──────────┬───────────────────────────────────┘
      stdin│ stream-json (user turns)
     stdout│ stream-json (events)
           ▼
  claude -p --input-format stream-json
            --output-format stream-json
            --verbose --include-partial-messages
            --session-id <uuid>
```

### Why not the alternatives

- **Electron + TS Agent SDK** — typed SDK, `canUseTool` callbacks, his Ledger stack. Rejected: the
  SDK's documented auth guidance is API-key, which violates constraint #1, and CSS can only
  approximate Liquid Glass.
- **SwiftUI + Node sidecar** — real glass *and* typed SDK. Rejected: same auth problem, plus two
  runtimes to bundle and notarize for no gain over the direct CLI.

## Phases

Ordered by risk, not by visibility. Nothing is built on an unverified assumption.

### Phase 0 — Spike (throwaway, half a day) — **GO / NO-GO**

A shell script and a ~100-line Swift file. No app target, no UI, no repo.

1. Launch `claude -p --input-format stream-json --output-format stream-json --verbose
   --include-partial-messages` with `ANTHROPIC_API_KEY` **explicitly unset**. Confirm it
   authenticates via subscription.
2. Send 3+ user turns down one persistent stdin. Confirm the process stays alive across turns and
   holds context.
3. **Measure and write down:** time-to-first-token, tokens/sec, per-turn overhead. Compare against
   the same prompts in the terminal.
4. Invoke a skill (`/ledger-tasks ...`) to prove non-bare context loading.
5. Capture the raw NDJSON to `fixtures/transcript.ndjson`.

**Kill criterion — agreed in advance:** if TTFT is materially worse than the terminal and can't be
explained by a fixable cause, stop here. Report the numbers and abandon. The cost of finding out is
half a day, not three weeks.

The captured fixture becomes both the schema source of truth and the unit-test corpus, so Phase 0
output feeds Phase 1 directly.

### Phase 0 RESULTS — ✅ GO (completed 2026-08-07)

All five objectives met. Raw fixtures in `scratchpad/spike/fixtures/`.

**1. Subscription auth confirmed.** `system/init` reports **`apiKeySource: "none"`** with
`ANTHROPIC_API_KEY` unset. Constraint #1 satisfied, and there's a field we can assert on at runtime.

**2. Persistent multi-turn works.** One process, 3 turns, context retained (turn 2 correctly recalled
turn 1's answer). Exit 0.

**3. Performance — constraint #3 satisfied.** The CLI self-reports timing in `result`, so we don't
need to instrument:

| Turn | `ttft_ms` | `ttft_stream_ms` | `time_to_request_ms` |
|---|---|---|---|
| 1 | 1434 | 971 | 20 |
| 2 | 1334 | 761 | 15 |
| 3 | 2285 | 1548 | 7 |

**`time_to_request_ms` of 7–20 ms is the per-turn overhead of the persistent process — effectively
zero.** TTFT is dominated by the API round-trip, i.e. identical to the terminal. The ~3.5 s process
startup is paid **once per session**, not per turn. This is the whole ballgame for the design.

**4. Skills load.** Asked for its skill list, got back exactly: `dev-scaffolder, git-workflow,
ledger-tasks, project-inception, youtube-transcript`. Non-bare context loading confirmed.

**5. Permission behavior — Phase 5 de-risked, plan changed.** A `Write` under `permissionMode:
default` **does not hang**. It:
- emits `system/permission_denied` `{tool_name, tool_use_id, message}`
- returns a `tool_result` with `is_error: true`
- **completes the turn normally** (`subtype: success`, `stop_reason: end_turn`)
- and puts the **full tool input** in `result.permission_denials[]`:
  `{tool_name, tool_use_id, tool_input: {file_path, content}}`

Because we get the complete intended content, **the native approval + diff UI needs neither
`--permission-prompt-tool` nor a local MCP server.** Design: run in `default`, catch
`permission_denied`, render a diff sheet from `tool_input`, and on approve re-issue with the tool
allowlisted (or persist a rule to `.claude/settings.json`). Trade-off: this is *deny-then-retry*
rather than *pause-mid-turn*, costing one extra round trip. A cleaner mid-turn interception may exist
via `--permission-prompt-tool` and is still worth a later spike, but this fallback is shippable and
cannot deadlock the UI. `--permission-mode acceptEdits` auto-approves cleanly for the fast path.

**Undocumented events discovered — all useful, none in the public docs:**
- **`rate_limit_event`** → `{status, resetsAt, rateLimitType: "five_hour", overageStatus,
  isUsingOverage}`. For a subscription-based app this is *better than a cost meter* — a real
  quota gauge with a reset countdown. Arrives first, before `system/init`.
- **`system/thinking_tokens`** → `{estimated_tokens, estimated_tokens_delta}`, streamed live. Drives
  a genuine thinking-progress indicator instead of a spinner.
- **`system/status`**, and `system/permission_denied` (above).

**Schema notes for Phase 1:**
- Per-turn envelope: `system/init` → `system/status` → `stream_event`(message_start →
  content_block_start → content_block_delta ×N) → **`assistant`** → `content_block_stop` →
  `message_delta` → `message_stop` → `result/success`. Note the buffered `assistant` message arrives
  **before** `content_block_stop` — reconcile on that, not on block close.
- `system/init` repeats **per turn**, not once per process.
- **`total_cost_usd` is cumulative per session, not per turn** — diff consecutive `result`s for
  per-turn cost.
- `result.modelUsage` breaks down by model (saw `claude-opus-5` *and* `claude-haiku-4-5` in one
  session) and carries `contextWindow` + `maxOutputTokens` per model → enables a real context gauge.
- `mcp_servers[]` includes `status: "needs-auth"` → surface re-auth prompts in the UI.
- `parent_tool_use_id` confirmed present on `assistant`/`user` messages (`null` = main thread).

### Phase 1 — Headless core (`AgentKit` Swift package, no UI)

The part that has to be correct. Testable without launching an app.

- `AgentBridge` — an `actor` owning `Process` + stdin/stdout/stderr pipes. Backpressure-aware
  line reader; never blocks the main actor.
- `AgentEvent` — `Codable` enum over the observed message types:
  - `system`/`init` → model, tools, mcp_servers, plugins, `plugin_errors`, `mcp_server_errors`,
    `capabilities`
  - `system`/`api_retry` → attempt, max_retries, retry_delay_ms, error category
  - `assistant`, `user` → content blocks, **`parent_tool_use_id`** (null = main thread)
  - `stream_event` → `event.delta.text_delta` for token streaming
  - `result` → `total_cost_usd`, `session_id`, usage
  - **unknown types decode to a `.unrecognized(raw:)` case and are logged, never fatal** — the
    protocol will evolve
- Session lifecycle: start / send / interrupt (SIGTERM aborts the turn cleanly, exit 143) /
  resume via `--resume` / fork via `--fork-session`.
- Unit tests replay `fixtures/transcript.ndjson` through the decoder. No network, no subprocess.

Exit bar: a `swift run` CLI harness that holds a multi-turn conversation. Still no UI.

### Phase 2 — Minimal chat UI (deliberately ugly)

Plain SwiftUI. System colors. **No glass yet.**

- Streaming transcript, `@Observable` model, `.textSelection(.enabled)`
- Markdown + syntax-highlighted code blocks with copy buttons
- Composer: multiline, ⌘↵ send, Esc interrupt
- Tool calls as collapsed rows

Exit bar: **use it for a real task and compare against the terminal.** Constraint #3 is re-tested
here with a real UI attached, before any time goes into aesthetics. If it feels worse, the problem is
architectural and it's still cheap to fix.

### Phase 3 — Liquid Glass design system

Only now does it get beautiful.

- `NSWindow` styling: `titlebarAppearsTransparent`, full-size content view, hidden title
- One `GlassEffectContainer` per region; `.glassEffect(.regular.interactive(), in: .rect(cornerRadius:))`
- `@Namespace` + `.glassEffectID` / `.glassEffectUnion` for morphing — sidebars merging into the
  composer, tool cards coalescing into a result
- `.glassEffectTransition` for enter/exit
- Motion: spring animations only, `.matchedGeometryEffect` for continuity, honor
  `accessibilityReduceMotion`
- Dark/light + real vibrancy behind the transcript
- **Design tokens in one file** — spacing, radii, glass variants, timing curves — so it's tunable
  without hunting through views

### Phase 4 — The four requested features

- **Persona wizard** — first-launch flow; writes a real `CLAUDE.md` + `.claude/settings.json` in the
  target project, and passes `--append-system-prompt` per session. The persona must be *actual
  config*, not a stored string the app ignores.
  *(Partially built 2026-08-08, `6c5a663`. `--append-system-prompt` and an inspectable
  `persona.json` shipped; the `CLAUDE.md` / `.claude/settings.json` write was **deliberately
  declined** — it would clobber real files. See ADR-007 before filing this as a gap.)*
- **Sidebar tool system** — a `SidebarTool` protocol + registry. Each tool is a SwiftUI view plus an
  optional headless action. Rearrangeable, addable, removable. Ship: notes, prompt improver, SQL
  reviewer, bug checker. Sidebar tools run as **separate short-lived `claude -p` calls with
  `--json-schema`** for structured results, so they never consume the main session's context.
  *(Runner landed 2026-08-09: `AgentKit/OneShotQuery.swift` + 11 tests. The plan's premise —
  "never consume the main session's context" — held for **context** but not for **cost**: an
  unstripped one-shot call measured 18,854 cache-creation tokens / 32.5 s / opus-5, because it
  inherits nothing and so rebuilds everything. Stripped and pinned to Haiku it is 0 tokens /
  6.6 s / $0.004. `OneShotConfiguration` bakes those flags in as defaults. Add ~2 s of process
  spawn that `duration_ms` doesn't count — a sidebar click lands around 9 s, so every tool needs
  a pending state. Isolation and cheapness are separate properties and this plan conflated them;
  see **ADR-008** for why the runner is a separate type from `AgentBridge`, and
  `docs/research/one-shot-cost-model.md` for the measurements. Also settled: one-shot calls
  report `apiKeySource: "none"` — same subscription path, nothing billed — so the constraint is
  **quota**, drawn from the same five-hour pool as the conversation. Protocol + registry + the
  four tools are still to build.)*
- **File path picker** — `NSOpenPanel`, plus a fuzzy in-app finder; inject path into composer or copy.
- **Project switcher** — sets the subprocess `cwd`, tracks recents, shows git branch + dirty state.

### Phase 5 — Showpieces

- **Subagent tree + live activity timeline.** `parent_tool_use_id` is emitted at *every nesting
  depth*, so the full tree is reconstructable by following IDs. Requires `--forward-subagent-text`
  (or `CLAUDE_CODE_FORWARD_SUBAGENT_TEXT`) to get subagent text, v2.1.211+ — he's on 2.1.226. An
  animated live tree of spawned agents is the visual centerpiece and the data is already in the
  stream.
- **Session library + cost meter.** Searchable, resumable, forkable. `total_cost_usd` per session
  (a client-side estimate — label it as such in the UI).
  *(Amended 2026-08-09: on subscription auth nothing is billed, so the meter's real subject is
  **quota**, not dollars — `rate_limit_event`'s five-hour window. And it **must count sidebar
  one-shot usage**, which fires its own `rate_limit_event` against the same pool; a meter that
  reads only the main session under-reports and a chatty sidebar can rate-limit the
  conversation. Read `modelUsage`, not `usage` — the latter undercounts by a hidden internal
  call, measured at 526 in / 14 out on the one-shot fixture. `OneShotUsage` is returned to
  callers for exactly this.)*
- **Native permission + diff approval UI.** ⚠️ **Least-verified piece.** Routing approvals into a
  SwiftUI sheet needs `--permission-prompt-tool` backed by a local MCP server; that mechanism is not
  yet confirmed and needs its own spike. **v1 ships `--permission-mode acceptEdits` plus an explicit
  `--allowedTools` list** — good enough daily, and the fancy version lands only after it's proven.

## Critical files

Greenfield. Placement and scaffolding go through the **`dev-scaffolder`** skill (do not freestyle the
folder); **`project-inception`** covers plan → repo → docs → Ledger board, and **`git-workflow`**
governs branches and commits.

```
AgentKit/                       # Phase 1 — pure Swift package, no UI, unit tested
  AgentBridge.swift             # actor: Process + pipes + NDJSON framing
  AgentEvent.swift              # Codable enum, .unrecognized fallback
  SessionStore.swift            # persistence, resume/fork
Workbench/                      # app target
  App.swift, WindowChrome.swift
  Chat/{TranscriptView,MessageBubble,Composer,ToolCallRow}.swift
  Glass/{DesignTokens,GlassPanel,MorphingContainer}.swift
  Sidebar/{SidebarTool,ToolRegistry,Tools/*}.swift
  Onboarding/PersonaWizard.swift
  Agents/SubagentTree.swift
fixtures/transcript.ndjson      # Phase 0 output → Phase 1 test corpus
docs/                           # per docs-as-deliverable
```

**Naming:** Anthropic's branding terms forbid third-party products called "Claude Code" or mimicking
its visual identity. "Powered by Claude" is permitted. Needs its own name — placeholder `Workbench`
above; pick the real one at scaffold time.

## Verification

- **Phase 0:** measured TTFT / tokens-sec / per-turn overhead vs. terminal, written down. Subscription
  auth confirmed with `ANTHROPIC_API_KEY` unset. A skill invoked successfully.
- **Phase 1:** `swift test` replays the fixture; `swift run` harness holds a multi-turn conversation.
  Malformed and unknown lines are handled without crashing.
- **Phase 2:** a real task completed in the app, timed against the terminal. This is the gate.
- **Phase 3:** visual check in light + dark; Reduce Motion honored; no dropped frames while streaming.
- **Phase 4:** persona wizard output actually changes agent behavior in a fresh session (verify by
  asking the agent who it is). Sidebar tools confirmed not to touch main-session context —
  **and** confirmed to pay no cold start: `cache_creation_input_tokens == 0` and exactly one
  model billed, both asserted by `OneShotQueryTests` and re-checkable live with
  `make harness ARGS="-s"` (which exits 1 on a regression). Context isolation alone is not the
  bar; it was never the expensive part.
- **Phase 5:** subagent tree matches a real fan-out run; approval flow spiked before being built.
- **Throughout:** `xcodebuild` clean; run the app after each phase rather than trusting tests alone.

## Risks

| Risk | Mitigation |
|---|---|
| Perceived latency worse than terminal | Phase 0 kill criterion; re-tested at Phase 2 before any polish |
| Stream-json schema is undocumented in places and may drift | Decode defensively, `.unrecognized` fallback, fixture-driven tests |
| Permission-approval routing unproven | Deferred to Phase 5 behind its own spike; v1 uses `--permission-mode` |
| Non-bare `-p` auth behavior changes | Verified in Phase 0, re-verified for one-shot calls 2026-08-09; if it regresses, the app degrades to spawn-per-turn `--resume`, not to API keys |
| Sidebar tools quietly burn the shared quota | Stripped launch is the *default* in `OneShotConfiguration`; three cost-regression tests plus a live probe that exits non-zero on a cold start (2026-08-09) |
| Failure paths that fixtures can't reach (subprocess lifecycle, pipe deadlock, exit codes) | Harness flags that force the failure against a real process — `make harness ARGS="-s --timeout N"`; see `docs/research/process-termination-status-trap.md` |
| Scope sprawl (this is a big surface) | Phases 0–2 are the actual product; 3–5 are independently shippable increments |
