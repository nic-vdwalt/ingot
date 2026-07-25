# Testing Ingot

Ingot tests the immediate-mode boundary directly: explicit application state and
synthetic input go in; bounded frame output and state transitions come out.
Assertions define the invariants, deterministic seeds make failures
reproducible, and sanitizers catch memory and concurrency errors around them.

This guide describes the commands. [Tiger Style](TIGER_STYLE.md) defines the
safety policy behind them, and [Why immediate mode](immediate-mode.md) explains
why the architecture is well suited to this approach.

## Contract-preserving refactors

Before changing behavior-sensitive internals, add characterization coverage for
its exported contract and record a green baseline. After each phase, run the
package tests, strict gate, web gate, deterministic fuzz targets, and the
windowed GPU lifecycle harness when rendering is touched. Build documented
downstream consumers against the local Ingot checkout using each consumer's own
instructions. Do not advance while a source, layout, ownership, timing, or visual
contract differs from the baseline.

## Toolchain

Ingot is checked with Odin `dev-2026-06:285f6d87b`. Install that exact Odin
revision and build `odinfmt` from the matching OLS checkout, then place both
executables on `PATH`. The repository `.odinfmt.json` pins formatting behavior.
`bash scripts/check.sh` fails when either the code does not match that formatter
or `odinfmt` is unavailable.

Verify the tools before running the gate:

```sh
odin version
odinfmt -help
```

## Standard checks

Run the package tests:

```sh
bash scripts/test.sh
```

This runs `odin test` for `gfx`, `ui`, `ui_gfx`, `libvterm`, `term`, `prefs`,
and `net`, then type-checks packages without tests. Extra Odin flags pass through
to each test command:

```sh
bash scripts/test.sh -define:ODIN_TEST_THREADS=1
```

Each package gets a 300-second wall-clock limit and a 16 MiB output budget. The
supervisor owns a separate process group, so timeout, excessive output, or an
`INT`, `TERM`, or `HUP` signal stops and reaps the generated test executable as
well as Odin. Successful output is not retained. A bounded failure log is saved
under `${TMPDIR:-/tmp}/ingot-test-failures` and its path is printed on failure.
Override the safeguards when an intentional long fuzz or soak run needs more:

```sh
INGOT_TEST_TIMEOUT_SECONDS=3600 \
INGOT_TEST_OUTPUT_LIMIT_BYTES=67108864 \
INGOT_TEST_FAILURE_LOG_DIR="$PWD/test-failures" \
bash scripts/test.sh -define:ODIN_TEST_THREADS=1
```

All limits must be positive integers. `ODIN_TEST_THREADS=1` controls test
concurrency only; it does not provide a timeout, output bound, or descendant
cleanup. Dedicated long-running fuzz targets should normally use `fuzz/run.sh`
rather than weakening the standard package-test limits.

Run the strict project gate:

```sh
bash scripts/check.sh
```

It checks every package with Odin's vet, strict-style, and shadowing diagnostics
and requires every tracked Odin source file to match `odinfmt`.

Validate the browser target with:

```sh
bash scripts/check-web.sh
```

This compiles the gallery, breakout, render fixture, idle demo, and default web
demo, then runs the dependency-free JavaScript lifecycle and semantic DOM tests.
These tests do not launch a browser; see `production-readiness.md` for the real
browser, operating-system, PTY, GPU, networking, and accessibility matrix.

The ordinary `term` run enables `INGOT_PTY_SIM=true`. It validates terminal pump
behavior without spawning a shell. Real Unix PTY and Windows ConPTY validation is
a separate platform integration gate.

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

### Frame scratch checks

Tests and fuzzers enable `INGOT_FRAME_SCRATCH_GUARD`. They exercise allocations
through `ui_frame_allocator`, generation rollover, and frame-end release. An
individual frame-memory free must panic with `individual free of frame memory`
and identify the offending source location.

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

`ui` checks layout, input snapshots, paint lists, and semantic-buffer invariants
as bounded data. Accessibility is generated alongside painting, so tests can
validate roles, labels, focus links, bounds, and paint ordering without a window,
GPU, or assistive technology. The boundary gate rejects any `ingot:gfx` import or
`rl.` reference under `ui`; backend integration is checked in `ui_gfx`.

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