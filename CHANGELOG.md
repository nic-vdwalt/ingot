# Changelog

All notable changes to Ingot are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Ingot uses `0.x` versioning: the leading zero means any release may break the
API. See [versioning policy](docs/compatibility.md#versioning-policy).

## Unreleased

### Added

- `ui_gfx.Session` as the canonical owner for custom frame loops, with accessors
  for runtime, frame, input, output, and user-scale updates.
- Snapshot-backed viewport, time, DPI, FPS, and monitor-refresh frame queries.
- Balanced Canvas UI scopes for translated, clipped, renderer-independent paint.

### Changed

- `ui_gfx.App` now delegates UI lifecycle ownership to `Session`.
- Direct `ui_gfx.Adapter` lifecycle calls are classified as backend-only.
- `App_Session` and `app_session_*` remain temporary source migration aliases.

### Migration

| Previous surface | Replacement |
|---|---|
| `App_Session` | `Session` |
| `app_session_init*` | `session_init*` |
| `app_session_begin_frame*` | `session_begin_frame*` |
| `app_session_end_frame*` | `session_end_frame*` |
| `app_session_destroy` | `session_destroy` |
| Separate runtime/frame/input/output/adapter values | One `Session` |
| Direct pane matrix and mouse-offset setup | `canvas_begin` / `canvas_end` |
| Backend time and viewport polling in views | `frame_*` snapshot queries |

## [0.1.0] - 2026-07-27

First public source release. Ingot is an immediate-mode application framework
for Odin, built on `vendor:wgpu`, targeting macOS/Metal, Windows/D3D12,
Linux/Vulkan, and browser WASM/WebGPU from one application source.

### What this release does and does not claim

This is a **source** release. No binaries, installers, or web bundles are
distributed; see [the binary and web release checklist](docs/oss-release-checklist.md).

Validated:

- The portable core builds and its package tests pass on macOS, Linux, and
  Windows in CI (`scripts/test.sh`, `scripts/check.sh`).
- Deterministic, seed-recorded fuzz harnesses cover UI wrapping, text input,
  interaction, HTTP/WebSocket parsing, terminal pumping, and frame lifetimes.
- ASan and TSan runs cover the Odin-side networking and concurrency paths.
- The web gate compiles the gallery, Breakout, and demo to WASM and runs
  dependency-free Node lifecycle and semantic tests (`scripts/check-web.sh`).
- A windowed GPU smoke test drives every UI scale, theme, and gallery section
  through real event handlers (`scripts/smoke-gallery.sh`).
- Media capture is byte-reproducible across runs (`scripts/capture-media.sh`).

Not validated:

- Every row of the release validation matrix in
  [production readiness](docs/production-readiness.md) is still `Not recorded`.
  There is no revision-pinned evidence for macOS/Metal, Linux/Vulkan,
  Windows/D3D12, real browsers, public-Internet TLS, GPU drivers, or assistive
  technology. Compile-only and Node-only results are not treated as validation.
- Simultaneous native multi-window rendering lacks Metal, Vulkan, and D3D12
  evidence.
- Linux desktop polish has not reached parity with macOS and Windows.
- Real PTY/ConPTY, native dialogs, and screen-reader behaviour need
  representative hardware.

### Added

- **`ingot:gfx`** — windowing, WebGPU batch rendering, shapes, textures, text,
  input, audio, gamepads, cameras, and a raylib/rlgl-shaped 2D API. Includes
  affine `Camera2D` transforms, per-pipeline blend modes, render targets, an
  opt-in GPU 3D pipeline, coalesced stream uploads, a lazily baked embedded
  default font, and independent multi-context support.
- **`ingot:ui`** — renderer-independent immediate-mode widgets, bounded
  single-pass flow layout, constrained flex sizing, paint output, input
  snapshots, accessibility semantics, themes, charts, markdown, a unified diff
  viewer, listboxes, overlays, and adaptive frame pacing.
- **`ingot:ui_gfx`** — adapter that captures `gfx` input, replays UI paint
  output, applies platform output, and hosts an `App_Session`.
- **`ingot:net`** — background HTTP and self-healing reconnecting WebSockets,
  including verified `wss://` with loopback TLS tests.
- **`ingot:prefs`, `ingot:sys`** — native settings files and web `localStorage`
  behind one API; URLs, native file dialogs, and platform integration.
- **`ingot:term`, `ingot:libvterm`, `ingot:pty`** — libvterm bindings with
  committed static libraries, PTY pumping, key translation, `forkpty` on Unix,
  and ConPTY on Windows.
- **`ingot:accesskit`** — AccessKit C API bindings with native static libraries;
  UI semantics bridge to native accessibility, and mirror to the DOM on web.
- **`ingot:testx`** — deterministic PRNG and inline snapshot helpers.
- Stable widget identity: scoped widget IDs, app-wide keyboard focus traversal,
  and focus scoping by active UI layer.
- Accessible high-contrast and reduced-motion themes.
- Event-driven idle rendering on native and web, with explicit redraw requests.
- IME support and cursor-based UI layout.
- `gfx.SaveRenderTexturePng` for deterministic GPU readback, plus a gallery
  capture harness and `scripts/capture-media.sh` that regenerate every README
  image reproducibly.
- `gfx.SetMousePosition` (raylib parity) and `ui.input_box_set_text`.
- Reproducible cross-framework widget benchmarks against pinned Dear ImGui and
  egui adapters, with a dated Apple M2 Max baseline.
- Cross-platform CI, a validation-evidence schema, and repository hygiene,
  assertion, style, and `gfx` context gates.

### Changed

- Reimplemented Ingot as a pure-Odin WebGPU framework on `vendor:wgpu`,
  replacing the earlier raylib-backed prototype, and unified the native and web
  targets behind one platform seam.
- Moved to explicit UI runtime and frame ownership, with backend-neutral frame
  interfaces and primary paint streamed to graphics adapters.

### Fixed

- Render-target scissor rects now honour the y-flipped render-target
  projection. Clipped content drawn inside a render target previously mirrored
  its position, which could hide short clip bands such as a text input's inner
  clip entirely.
- Text truncation now measures through the same path auto-layout uses. Layout
  measured via the runtime text backend while truncation measured via the legacy
  text system, so labels that fit exactly were cut with an ellipsis.
- `ui.spinner` honours `reduced_motion`, matching the caret's contract. It
  previously animated regardless and kept idle event-driven applications
  repainting forever.
- Prevented a libvterm UTF-8 decode buffer overflow.
- Validated `LoadFontFromMemory`'s caller-supplied buffer.

[0.1.0]: https://github.com/Nic-vdwalt/ingot/releases/tag/v0.1.0
