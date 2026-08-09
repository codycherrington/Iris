# `@Observable` view state: `@Bindable` is for writing, not for observing

**Found:** 2026-08-09, building the sidebar tool system (`63d6b70`).
**Applies to:** Swift 6 / macOS 26, the `Observation` module (`@Observable`), not the older
`ObservableObject` / `@Published` world.

## The mistake

The shared body for model-backed sidebar tools needs two things: a two-way binding to the tool's
`draft` text, and read access to its `OneShotRunner`'s phase. The first cut bundled both into one
object so the view had a single thing to observe:

```swift
// WRONG — reconstructed on every body evaluation
struct OneShotToolBody<Output: StructuredOutput>: View {
    @Bindable var box: RunnerBox<Output>   // pairs `draft` binding + runner

    var body: some View {
        let box = RunnerBox(draft: …, runner: …)   // new object, every frame
        …
    }
}
```

The box was **constructed inside `body`**. Every evaluation produced a new instance, so the
identity that `@Observable`'s dependency tracking attaches to never survived a frame.

## Why that is the wrong shape

`@Observable` tracks at the granularity of *a property read on a specific instance*. Reading
`runner.phase` inside `withObservationTracking`'s implicit scope (which is what SwiftUI's `body`
evaluation is) registers a dependency on **that instance's** `phase`. Invalidation is delivered
to whoever registered.

A wrapper built fresh in `body` is a new instance each time. Nothing outside the current frame
holds it, and the dependency it registers is on an object that is about to be discarded. The
wrapper is not observed *state* — it's a temporary view of state, allocated per frame, doing the
work of a `struct` while costing an allocation and defeating the mechanism it exists to feed.

`@Bindable` compounds the confusion. It exists to produce **bindings** — `$box.draft` — for
two-way writes into an `@Observable`. It is not what makes a type observable, and it is not
required to *read* one. This is a habit imported from `ObservableObject`, where
`@ObservedObject` / `@StateObject` really were the subscription mechanism. Under `Observation`
they are not: the tracking is in the property access itself.

## The fix

Two plain stored properties, no wrapper:

```swift
struct OneShotToolBody<Output: StructuredOutput, Result: View>: View {
    @Binding var draft: String
    /// A plain `let`, not `@Bindable`: nothing here writes to the runner's properties, and
    /// `@Observable` tracks reads through a stored reference just fine.
    let runner: OneShotRunner<Output>
    …
}
```

`runner.isRunning` and `switch runner.phase` in `body` register dependencies on the long-lived
runner the tool owns. The view invalidates when the phase changes, and only then.

`@Bindable` is still used where it earns its keep — `NotesToolView` writes back into the tool:

```swift
struct NotesToolView: View {
    @Bindable var tool: NotesTool
    var body: some View {
        TextEditor(text: $tool.text)   // this is why @Bindable is here
    }
}
```

## Rules of thumb

- **Reading an `@Observable` needs nothing.** Any stored reference — `let`, a plain property, an
  `@Environment` value — tracks correctly.
- **`@Bindable` is only for `$` bindings**, i.e. when the view *writes* a property back.
- **Never construct an observed object inside `body`.** If a view needs a composite of several
  observables, make it a `struct` of references or pass them separately; do not allocate a class
  per frame to hold them.
- **`@State` for ownership, a plain `let` for a reference to something owned elsewhere.** In Iris
  the tools are owned by `SidebarRegistry` for the lifetime of the app, so views take references.
- Corollary: if wrapping something in `@Bindable` "makes it start updating", the real fix is
  usually that the reference was unstable, not that the wrapper was missing.

## Related shapes in this repo

- `GlassContentView` holds `@State private var registry = SidebarRegistry.shared` — `@State` on a
  reference to a singleton is how a SwiftUI view keeps a stable reference to an `@Observable` for
  the view's lifetime.
- `SidebarPanel` takes `@Bindable var registry` because the picker writes through it
  (`registry.enable(_:)` mutates `layout`).
- The class-bound `SidebarTool` protocol (ADR-009) exists for a related but distinct reason: tools
  need stable identity so their *state* survives being hidden. Stable identity happens to be
  exactly what `@Observable` tracking wants too.
