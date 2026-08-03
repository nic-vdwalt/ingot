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

`ODIN_VERSION` is the canonical compiler pin. Install that exact Odin revision,
including its bundled `odinfmt`, then place both executables on `PATH`. The
repository `.odinfmt.json` pins formatting behavior. `scripts/test.sh` requires
Python 3 for process supervision, and `scripts/check-web.sh` additionally
requires Node with `node --test`. `bash scripts/check.sh` checks `odin version`
before compilation and fails when the compiler differs, the code does not match
the pinned formatter, or `odinfmt` is unavailable.

Verify the tools before running the gate:

```sh
python3 scripts/check-toolchain.py
odinfmt -help
```

On a native Linux host, verify native dependencies and build the pinned
architecture-matched libvterm archive before the standard gates:

```sh
bash scripts/check-linux-dependencies.sh
bash scripts/check-linux.sh
```

Set `INGOT_LINUX_RUNTIME=1` on a Linux host with `xvfb-run` and a Vulkan driver
to include gallery and view-builder windowed smoke tests. The Linux gate is
local and native; no macOS-to-Linux cross toolchain is supplied. AccessKit is
validated on Linux amd64 and intentionally unavailable on Linux arm64 until a
verified arm64 artifact exists.

## Standard checks

Run the package tests:

```sh
bash scripts/test.sh
```

This runs `odin test` for `gfx`, `ui`, `ui_gfx`, `libvterm`, `term`, `prefs`,
and `net`, runs the native loopback WSS/TLS matrix, then type-checks packages
without tests. The matrix uses repository-only test PKI and Python's standard
library to verify trusted, untrusted, wrong-host, upgrade, framing, and teardown
behavior without Internet access. Extra Odin flags pass through
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

It checks every package with Odin's vet, strict-style, and shadowing diagnostics,
runs the graphics-context ownership guard, builds every consumer fixture, and
requires every tracked Odin source file to match `odinfmt`. The ownership guard
uses `scripts/gfx_context_baseline.json` to reject growth in direct singleton
references per procedure. Measure the current inventory with:

```sh
python3 scripts/check_gfx_context.py --measure .
```

Reductions require removing stale baseline entries; intentional compatibility
facade additions require an explicit reviewed baseline update.

Validate the browser target with:

```sh
bash scripts/check-web.sh
```

This compiles the gallery, Breakout, and default web demo, then runs the
dependency-free JavaScript lifecycle and semantic DOM tests. These tests do not
launch a browser; see `production-readiness.md` for the real browser, operating-
system, PTY, GPU, networking, and accessibility matrix.

The ordinary `term` run enables `INGOT_PTY_SIM=true`. It validates terminal pump
behavior without spawning a shell. Real Unix PTY and Windows ConPTY validation is
a separate platform integration gate.

Windows uses `scripts/test.ps1` and `scripts/check.ps1`. Validation runs use
`scripts/validation-evidence.py` to emit bounded, redacted JSON and logs matching
`docs/validation/schema.json`. `scripts/validation-matrix.py` generates status
rows from committed evidence and leaves targets without evidence as Not recorded.

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

## Why deterministic simulation fits Ingot

Deterministic simulation testing runs the real system against generated input
under a recorded seed, replacing only the sources of nondeterminism. It is
effective in proportion to four properties, and Ingot's architecture supplies
all four rather than acquiring them through test scaffolding.

**The system's natural boundary is already a function.** An immediate-mode
frame consumes explicit caller state and one input snapshot, and produces
bounded paint, semantic, and platform output plus a state transition. A harness
does not have to construct, serialize, or repair a hidden widget tree to reach
an interesting state, and it does not have to reach through a private object
graph to observe the result. The boundary that the architecture already exposes
is the boundary the simulation drives. A retained-tree toolkit must invent that
seam; Ingot only has to call the public procedure.

**Nondeterminism is confined to a few named seams.** Wall clock, sockets, the
PTY, the platform input queue, and the GPU are the only sources of surprise, and
each is isolated behind a compile-gated simulation seam - `INGOT_NET_SIM`,
`INGOT_WS_SIM`, `INGOT_INPUT_SIM`, `INGOT_PTY_SIM`. The seam replaces the edge,
not the logic: `wsreconn` keeps the production worker thread, mutexes, atomics,
condition variable, queue, and reconnect loop, and scripts only the transport.
What runs under simulation is therefore the code that ships, which is the
difference between a simulation and a mock.

**Bounded work makes state spaces enumerable and failures local.** Tiger Style
forbids recursion and requires a named upper bound on every loop, queue, and
pool. That makes a frame's work finite by construction, so a harness can assert
capacity rather than hope for it, exhaustion becomes a counted operating
condition instead of a crash, and a generated input cannot wander into an
unbounded state the developer never modeled.

**Assertions and derived data supply the oracles.** The hard part of fuzzing is
usually not generating input but recognizing wrong behavior. Ingot answers this
twice. Assertions sit at the boundaries they protect, so corrupt state fails
immediately at its origin rather than as a later symptom. And frame output is
plain, inspectable data - focus links, routing claims, semantic nodes, paint
batches, resource generations - so invariants can be checked as properties of
values instead of by rendering pixels and comparing them.

Where a property cannot be observed in-process, the harness substitutes a
stricter external observer rather than dropping the check: `INGOT_GPU_STRICT`
turns any WebGPU validation message into an abort, and
`INGOT_FRAME_SCRATCH_GUARD` turns a misuse of frame memory into a located panic. Sanitizers and the tracking
allocator play the same role for memory and concurrency errors, which have no
natural in-language oracle at all.

The consequence is that new subsystems should be designed to preserve these four
properties rather than tested afterward. `docs/3d-content-pipeline-plan.md`
applies that rule to a prospective asset and scene pipeline: import and cook are
pure byte-to-data transforms, the draw list is bounded plain data, and the
renderer-independent packages are forbidden from importing `ingot:gfx`, so
almost the whole pipeline is reachable by the harness described here without a
window.

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

The gallery smoke test exercises the same class through real event handlers. The
multi-context fixture alternates two native windows, closes one, and verifies the
other remains renderable:

```sh
bash scripts/smoke-gallery.sh
odin run examples/multi_context_fixture -collection:ingot=.
```

Native shell-close validation uses an application with a deliberately delayed
shutdown callback. On Windows, verify that the native window disappears as soon
as its close control is used. On macOS and Linux, verify normal window-manager
close behavior. On every native target, verify that cleanup completes before
`app_run` returns and that caller-owned graphics resources remain releasable
during shutdown. Repeat with event waiting enabled and with a one-frame-per-second
target to cover both GLFW event paths and close-frame pacing.

`scripts/capture-media.sh` is the third windowed tool outside `scripts/test.sh`.
It renders the gallery into a fixed 1600x1000 offscreen target and reads it back
with `gfx.SaveRenderTexturePng`, writing the committed stills in `docs/media/`
and the demo GIF/MP4 in `dist/media/`:

```sh
bash scripts/capture-media.sh
```

It is a media generator rather than an assertion harness, but it is a useful
regression signal: capture mode forces reduced motion, a fixed UI scale, and a
parked cursor, so two runs of the same revision produce byte-identical PNGs.
A diff in the output means rendering, layout, or theming changed.

## Scope and limits

- The fuzz suite currently runs locally rather than in CI.
- Prebuilt wgpu-native and AccessKit libraries are outside Odin-side ASan/TSan
  instrumentation.
- The GPU harness uses strict WebGPU validation to cover lifetime failures that
  a headless allocator cannot observe.
- Regular builds retain Odin bounds checks; do not disable them.
- A passing fuzz run is evidence, not proof. Preserve exact seeds and assertions
  so every discovered failure becomes a permanent regression test.