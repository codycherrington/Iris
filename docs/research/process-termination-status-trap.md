# `Process.terminationStatus` aborts the app if the process is still running

Discovered 2026-08-09 while building `OneShotQuery` (commit `5d3947b`). Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`), macOS 26.5.1 (`25F80`), Foundation's `Process`. Nothing about it is
version-specific — `NSConcreteTask` has behaved this way for many years — but record the
toolchain anyway so a future reader can tell whether a fix has landed.

## The trap

`Process.terminationStatus` is a plain `Int32` property in Swift's eyes. It is not throwing, it
is not optional, and nothing in its signature warns you. But it is backed by
`NSConcreteTask`, and reading it before the process has exited raises an **Objective-C
exception**:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: '*** -[NSConcreteTask terminationStatus]: task still running'
```

**Swift cannot catch Objective-C exceptions.** There is no `do`/`catch` that helps. The process
aborts:

```
Abort trap: 6
```

So a property access that looks total is, in one particular state, an unconditional crash of
the whole application.

## Why it bit Iris specifically

`OneShotQuery.runRaw` races the CLI against a deadline in a `withThrowingTaskGroup`. When the
deadline wins, the code lands in its `catch` block, terminates the child, and builds an error
describing what happened — and *what happened* naturally includes the exit code.

But a timeout is by definition the state where the process **has not exited yet**. Terminating
it is asynchronous; `terminate()` sends SIGTERM and returns immediately. So the error-reporting
path read `terminationStatus` on a live process, every time.

**Every one-shot timeout would have crashed Iris in front of the user.** Not "sometimes" — the
crash was in the timeout path itself, so it was 100% reproducible the moment a deadline fired.

## The fix

One function, and the guard is the entire content of it
(`AgentKit/Sources/AgentKit/OneShotQuery.swift`):

```swift
private func exitedStatus(_ process: Process) -> Int32? {
    process.isRunning ? nil : process.terminationStatus
}
```

The return type has to be `Int32?`, and that optionality propagates into the error type:

```swift
/// The process stopped without ever emitting a `result`. `exitCode` is nil when the
/// process was still running — `Process.terminationStatus` cannot be read before exit.
case noResult(exitCode: Int32?)
```

That `?` is not defensive style. It is the API honestly admitting there are states in which the
exit code does not exist yet, which is exactly the information `terminationStatus` hides.

Note also that `isRunning` is a *check-then-act* race in principle — the process could exit
between the two reads. In this direction the race is benign (you get `nil` instead of a status
that just became available), but the reverse ordering would not be safe.

## Why the test suite didn't catch it

At the time this shipped, **35/35 tests passed** and had passed the whole way through. They
are fixture tests: they replay captured NDJSON through the decoder. There is no process, so
there is no process lifecycle, so there is no state in which `terminationStatus` is unreadable.

It surfaced only because a `--timeout` flag was added to the `iris-cli` probe
(`make harness ARGS="-s --timeout 1"`) specifically to fire a real deadline against a real
child process.

**The generalizable rule:** fixture tests verify what the protocol *says*. They cannot verify
anything about the *process* — spawn failure, partial writes, pipe deadlock, SIGTERM timing,
exit-code availability. Failure paths that involve a real subprocess need to be exercised
against a real subprocess, and the cheapest way to do that is to build a flag that forces the
failure on demand and keep it in the harness.

Iris has a second instance of the same category already: stderr is drained-and-discarded in
both `AgentBridge` and `OneShotQuery` **not** because anything reads it, but because leaving a
pipe unread deadlocks the child once its buffer fills. That, too, is invisible to fixtures.

## Checklist for any other `Process` use in this repo

- Never read `terminationStatus` without `isRunning == false` first.
- `terminate()` is asynchronous — returning from it does not mean the process is gone.
- Always drain both `standardOutput` and `standardError`, even if you throw one away.
- Clear `readabilityHandler`s in `terminationHandler`, or the handles leak.
- Any failure path you can't trigger from a fixture needs a harness flag that triggers it.
