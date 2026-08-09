# Lifelike voice mode — considered 2026-08-09, deferred

**Status: not planned.** Cody asked whether a third-party lifelike voice mode was feasible,
then deferred it as too compute-heavy for this machine — *"maybe on another computer."* This
note exists so the research isn't re-done from zero, **not** because voice is on the roadmap.
Nothing below is a commitment; no phase, plan entry, or board card follows from it.

## The finding worth keeping

**Speech-to-speech realtime models are the brain, not a microphone.** OpenAI Realtime, Gemini
Live and ElevenLabs Agents each own the conversation loop: audio in, audio out, with their own
model reasoning in the middle. Wiring one into Iris would mean **replacing the `claude` CLI**,
which deletes the entire architecture — subscription auth (ADR-002), skills, hooks, MCP, the
persistent bridge, all of it.

So the only shape compatible with Iris is a **cascaded pipeline** that leaves the agent loop
untouched:

```
mic → STT → SessionModel.send()  →  existing stream-json turn  →  sentence-chunked TTS → speakers
```

The corollary is that **ElevenLabs' official Swift SDK is the wrong product** even though it's
the obvious first hit: it is an *Agents* SDK (LiveKit/WebRTC transport, and it owns the LLM).
Any cascaded design would use a plain TTS endpoint, not that SDK.

## STT is the solved half — and it's free

macOS 26 ships `SpeechAnalyzer` / `SpeechTranscriber`, on-device. Confirmed present in the
installed SDK —

```swift
// MacOSX26.5.sdk/…/Speech.framework/…/arm64e-apple-macos.swiftinterface:205
@available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *)
@available(watchOS, unavailable)
final public actor SpeechAnalyzer : Swift.Sendable
```

It is also *good*, not merely present. Published comparisons against Whisper Small:

| | word error rate, clean | WER, noisy |
|---|---|---|
| `SpeechTranscriber` (macOS 26) | **2.12%** | **4.56%** |
| Whisper Small | 3.74% | 7.95% |

…at roughly **3× the speed**, on-device, with no key and no network. If voice is ever revisited,
STT is not the part to spend research on.

> ⚠️ Every number in this section and the next is a **published third-party figure**, not
> something Iris measured. Nothing here has been reproduced on this machine. Treat them as
> "worth this much research time later", not as evidence.

## TTS is the unsolved half, and vendor latency claims don't survive measurement

The cascaded pipeline's whole viability rests on time-to-first-audio. Independent measurement
(Coval's TTS latency benchmark) against what the vendors advertise:

| Engine | measured P50 time-to-first-audio | vendor claim |
|---|---|---|
| Cartesia Sonic-3 | **~188 ms** | 40–90 ms |
| ElevenLabs Turbo v2.5 | **~264 ms** | 40–90 ms |
| ElevenLabs Flash v2.5 | **~288 ms** | 40–90 ms |

**Every one is 2–7× the marketing figure.** They are all still usable for a cascaded pipeline —
~200–300 ms after a sentence boundary is fine — but the gap is the point: if voice is ever
scoped off a vendor's latency page, the plan will be wrong by a factor of several. Measure first.
That is the same lesson the sidebar-cost work landed the same day
(`docs/research/one-shot-cost-model.md`), which is why it's recorded here rather than left in a
chat log.

The local option does not clear the bar Cody actually set. **Kokoro-82M** runs on the ANE at
**13–70× realtime** — comfortably fast enough, no network, no cost — but it is prosodically
flat. The request was for something *lifelike*, and flat-but-instant isn't that. So the cascade
would need a cloud TTS leg, which reintroduces a network dependency and a per-character bill
into a project whose defining constraint is subscription-only, no API keys (ADR-002). That
tension is arguably the strongest argument for the deferral, over and above the compute cost.

## The two hard parts are Iris-specific

Both are consequences of what Iris's output stream actually contains, so they'd be true of any
implementation:

1. **The transcript is not speakable.** The stream is full of code blocks, file paths, diffs and
   tool calls that must not be read aloud. This needs a **separate "speech view" of the
   transcript**, distinct from the visual one — a real second rendering of the same event
   stream, not a regex over the display text.
2. **The silence problem.** The ~11 s TTFT measured at the Phase 2 gate is covered fine
   *visually* by the breathing-name animation (`docs/runs/2026-08-08-phase2-perf-gate.md`).
   Eleven seconds of audio silence is intolerable. Voice would need its own filler behaviour,
   which is a design problem, not an integration one.

## Two blockers in the build, if this is ever revisited

- **No `NSMicrophoneUsageDescription` in the Makefile's `INFO_PLIST`.** Without it the app
  cannot request mic access at all.
- **The bundle is unsigned** — `make app` assembles `Iris.app` by hand with no `codesign` step.
  TCC keys mic grants to code signature, so a grant would likely re-prompt on **every rebuild**,
  which makes iterating on voice miserable long before the audio works.

Neither is hard to fix; both are invisible until the first time you try.
