# Testing Ingot

Ingot tests the immediate-mode boundary directly: explicit application state and
synthetic input go in; bounded frame output and state transitions come out.
Assertions define the invariants, deterministic seeds make failures
reproducible, and sanitizers catch memory and concurrency errors around them.

This guide describes the commands. [Tiger Style](TIGER_STYLE.md) defines the
safety policy behind them, and [Why immediate mode](immediate-mode.md) explains
why the architecture is well suited to this approach.

## Standard checks

Run the package tests:

```sh
bash scripts/test.sh
```

This runs `odin test` for `gfx`, `ui`, `term`, `prefs`, and `net`, then
type-checks `sys`. Extra Odin flags pass through to each test command:

```sh
bash scripts/test.sh -define:ODIN_TEST_THREADS=1
```

Run the strict project gate:

```sh
bash scripts/check.sh
```

It checks every package with Odin's vet, strict-style, and shadowing diagnostics
and checks formatting when `odinfmt` is available.

Validate the browser target with:

```sh
bash scripts/check-web.sh
```

This compiles the web examples and runs the dependency-free JavaScript tests for
the semantic DOM overlay.

## Deterministic fuzzing

The fuzz harnesses use deterministic pseudo-random input. Passing a seed
replays the same path:

```sh
fuzz/run.sh net
fuzz/run.sh net 12345
fuzz/run.sh net 12345 100000
```

Headless targets build with debug information and AddressSanitizer by default.
Harnesses use `mem.Tracking_Allocator` where applicable so leaks and invalid
ownership transitions fail the run.

| Target | Surface exercised |
|---|---|
| `net` | Simulated HTTP transport plus HTTP and WebSocket parsers |
| `ui` | Parsers, widget math, wrapping, and accessibility semantics |
| `term` | Input bytes, libvterm, and scripted PTY pump/resize/EOF behavior |
| `interact` | Real widgets under synthetic input and routing/focus invariants |
| `input` | Text edits, caret, selection, undo, mentions, wrapping, and spell state |
| `wsreconn` | Real worker synchronization with a seed-scripted socket transport |
| `tsan` | WebSocket, HTTP worker-pool, and accessibility-queue concurrency |
| `gfx-frame` | Windowed GPU resource lifetime under strict WebGPU validation |
| `all` | Every headless harness plus the TSan phase |
| `soak` | Repeated `all` rounds with fresh, reported seeds |

Use `SAN=none`, `SAN=address`, or `SAN=thread` to select instrumentation where a
target supports it. AddressSanitizer and ThreadSanitizer run in separate
binaries because they cannot be combined.

## Why the UI harnesses are effective

`interact` drives production buttons, checkboxes, sliders, dropdowns, modals,
and context menus through the compile-gated synthetic input seam. It checks
routing, focus, latches, and semantic output under generated event orderings.
The harness does not need to manipulate a retained widget tree: caller state,
input, and frame output are already the system's natural boundary.

`input` drives the private text-edit state machine at 200,000 operations. The
normal package test runs the same class of checks at a smaller count for fast
feedback.

`ui` checks layout and semantic-buffer invariants as bounded data. Accessibility
is generated alongside drawing, so tests can validate roles, labels, focus
links, and bounds without launching assistive technology.

## Concurrency testing

`wsreconn` keeps the production worker thread, mutexes, atomics, condition
variable, queue, and reconnect loop. Only socket I/O is replaced by a scripted
transport that can produce dial failures, handshake faults, fragmented or
invalid frames, closes, cuts, and timeouts.

The `tsan` phase separately covers:

- WebSocket reconnect and message ownership.
- The native eight-worker HTTP fetch pool.
- The accessibility action queue's producer/drain boundary.

Terminal and PTY code are intentionally single-threaded, so TSan does not add
coverage there.

## GPU lifetime validation

Run the windowed resource-lifecycle harness after changing GPU resource
ownership or submission lifetime:

```sh
fuzz/run.sh gfx-frame
```

It opens a real window and interleaves font-atlas resets, texture and render
target unloads, UI rescaling, and window resizes inside live frames. It builds
with `INGOT_GPU_STRICT`, making any WebGPU validation message abort the run.
Because it needs a display, it is intentionally excluded from `all` and `soak`.

The gallery smoke test exercises the same class through real event handlers:

```sh
bash scripts/smoke-gallery.sh
```

## Scope and limits

- The fuzz suite currently runs locally rather than in CI.
- Prebuilt wgpu-native and AccessKit libraries are outside Odin-side ASan/TSan
  instrumentation.
- The GPU harness uses strict WebGPU validation to cover lifetime failures that
  a headless allocator cannot observe.
- Regular builds retain Odin bounds checks; do not disable them.
- A passing fuzz run is evidence, not proof. Preserve exact seeds and assertions
  so every discovered failure becomes a permanent regression test.