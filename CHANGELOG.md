# Changelog

All notable changes to Ingot are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Ingot uses `0.x` versioning: patch releases preserve documented public source
compatibility, while minor releases may break it. See the
[versioning policy](docs/compatibility.md#versioning-policy).

## Unreleased

### Added

- `gfx.renderer_peak_usage` and `Paint_List.peak_count` / `peak_text_len`:
  always-on high-water marks for the batch and paint buffers, reported by the
  gallery smoke run. Unlike `Renderer_Stats` these are not gated behind a
  build flag, because they are the evidence the fixed capacities are sized
  from - a bound nobody can measure is a guess.
- `Grid` (`grid_begin` / `grid_next` / `grid_end`): a bounded single-pass
  cell grid with exact column division, replacing per-cell x/y arithmetic.
- `Main_Align` justification (`Start` / `Center` / `End` / `Space_Between`)
  for declared flex runs, on `flex_begin`, `flex_row_begin`, and
  `flex_column_begin`.
- `end` now returns the consumed content extent, and `ROOT_EXTENT_OPEN`
  names the root height for a `Ui` inside a scrolling pane, removing the
  magic-height and end-of-section pad arithmetic from call sites.
- Semantic styling variants: `label` accepts `Text_Role` + `Ink`, and
  `status_pill`, `progress_bar`, `progress_bar_animated`, and `kv_row`
  accept `Ink` values (with muted-key / emphasized-value defaults for
  `kv_row`) instead of raw theme colors.
- `combobox`: a searchable dropdown with a filter text field, keyboard
  navigation, and a bounded overlay popup.
- `date_picker`: an ISO-date field with a calendar popup, plus pure
  `calendar_*` helpers (leap years, Zeller weekday, parse/format).
- `table_header` / `table_tracks` / `Table_Sort`: sortable table headers that
  share flex tracks with caller-drawn rows.
- `tab_bar`: a focusable tab strip with an accent underline.
- `toast_push` / `toasts_draw`: a bounded timed notification queue drawn on
  the overlay layer.
- `confirm_dialog`: a modal preset with Cancel / Confirm for destructive
  actions.
- A web form backend (`ui_runtime_set_web_form_backend`) so text inputs and
  submit buttons mirror into real browser form controls again; the graphics
  adapter installs it automatically.
- Surface design tokens (`ui/tokens.odin`): `Surface`, `Visual_State`,
  `Radius`, `Border`, `Elevation`, and `Tint`, resolved by `surface_colors`,
  `radius_ratio`, `radius_pixels`, `radius_segments`, `border_pixels`,
  `elevation_offset`, `tint_alpha`, and `color_tinted`. These are the missing
  peer of `Text_Role`/`Ink` (type and text color) and `Space` (spacing):
  nothing previously named what a *filled region* meant, so each widget
  answered independently and the answers drifted apart.
- `draw_surface`: one fill + border + shadow entry point for a token-styled
  region, so two widgets cannot disagree about the same surface class.
- Paper materials (`ui/material.odin`): `draw_shadow_hard`, `draw_rule_lines`,
  `draw_margin_rule`, `draw_dot_grid`, `dot_grid_fits`,
  `draw_highlight_swipe`, `draw_scribble_fill`, `draw_tape_strip`, and
  `draw_dog_ear`, each bounded by a named constant derived from the paint
  budget.
- `THEME_PAPER` and `THEME_PAPER_NIGHT` (`theme_paper` / `theme_paper_night`):
  warm ink-on-paper palettes. Both clear full WCAG AA (4.5:1) across every
  reading ink and surface, which the existing dark and light palettes do not.
- `Theme.surface_pressed`, `fg_on_accent`, `caption_hover`, `caption_pressed`,
  `caption_close_hover`, `caption_close_pressed`, `spell_error`, `paper_rule`,
  `paper_margin`, `highlighter`, `tape_color`, `ink_faded`, and `substrate`.
- `theme_ink`: the pure half of `text_ink`, so contrast can be audited without
  a live frame.
- `PAINT_COMMANDS_PEAK_4K` and `PAINT_COMMANDS_HEADROOM`: the measured 4K
  command peak and the room left over, so new per-frame decoration is bounded
  against real headroom rather than against the raw capacity.
- Gallery: a `Theme` section rendering the whole token system, including a
  Surface x Visual_State matrix driven by explicit state rather than by
  pointer position. Hover and pressed were previously unobservable in any
  screenshot, which is how two state defects shipped.
- `draw_hand_underline`: the doubled, unequal stroke pair a person makes when
  underlining by hand. A single straight rule under a heading reads as a
  border - the eye takes it as the top edge of whatever follows.
- `space_pixels`: the frame-level spacing resolver. The explicit tier owns its
  own geometry and has no `Ui` to ask, so it previously had to re-declare the
  spacing scale locally; `space_px` now delegates here so there is one table.
- Gallery: the theme control cycles Dark, Light, Paper and Paper Night instead
  of toggling a boolean, so both paper palettes are reachable. Before this the
  paper materials had no callers at all - the aesthetic existed in the library
  but could not be seen from any application.
- Gallery: the `Theme` section is laid out as a ruled page - substrate rules
  behind the content, a margin rule with the measurements hung beside it as
  annotations, and hand-drawn heading underlines. `Selected` renders as a
  highlighter swipe and `Pressed` as a scribble, so the materials are
  exercised on every frame rather than only in tests.

### Changed

- **Breaking:** `ui_gfx.App_Config.clear_color` is removed. The window
  background is now derived from the active theme by `ui_gfx.app_clear_color`.
  The field was a stored *copy* of `theme.bg_app`, and every theme switch had
  to remember to update it; `chart_demo` did not, so switching it to the light
  palette left a dark window. Applications should delete their `clear_color`
  assignment - the window now follows the theme automatically. Because every
  call site uses named-field literals, removing the field is a compile error
  rather than a silent behaviour change.
- Caption buttons, the spellcheck squiggle, and the split-drop hint read their
  colors from the palette instead of from file-local constants. The caption
  constants were a 15-alpha and a 10-alpha white wash, which is invisible on
  the high-contrast palette's pure black title bar.
- Disabled controls resolve to `fg_disabled` everywhere. `button_at` used
  `fg_muted_dim` while menus used `fg_disabled`, so a disabled button and a
  disabled menu item rendered in different colors in the same frame.
  `fg_muted_dim` is now `Ink.Muted` only.
- Gallery smoke runs theme *combinations* rather than four mutually exclusive
  steps, so high contrast with reduced motion is exercised.

### Fixed

- Dropdown, date-picker, and checkbox borders were passing an unscaled `1`
  where their own popups scaled correctly, so at 2x DPI a field's border was
  one physical pixel and its popup's was two. All borders now resolve through
  `border_pixels`.
- `THEME_HIGH_CONTRAST.button_pressed` was pure white, identical to
  `button_hover`, so a pressed high-contrast button gave no feedback
  distinguishable from hover.

## [0.1.1] - 2026-07-28

### Added

- `ui_gfx.Session` as the canonical owner for custom frame loops, with accessors
  for runtime, frame, input, output, and user-scale updates.
- Snapshot-backed viewport, time, DPI, FPS, and monitor-refresh frame queries.
- Balanced Canvas UI scopes for translated, clipped, renderer-independent paint.
- `gfx.FocusWindow` and the corresponding explicit-context window-focus API.
- A gallery header, theme-synchronized background, and redraws after theme
  changes.

### Changed

- `scripts/check_assertions.py` recognises `assert_contextless` as an
  assertion. `\bassert\b` never matches inside it, so every
  `proc "contextless"` - which is what a platform event callback must be -
  could only ever reach the gate as baseline debt, or be "fixed" by moving its
  contract to a caller that cannot enforce it.

- **Paint capacities right-sized from measurement.** `PAINT_COMMAND_CAP` is
  now `8192` (was `32768`) and `PAINT_TEXT_CAP` is `32768` (was `262144`),
  both overridable via `-define:INGOT_PAINT_COMMAND_CAP` /
  `INGOT_PAINT_TEXT_CAP`. These are inline arrays and `Ui_Output` holds two of
  them, so the old values reserved 8.4 MiB per app permanently. The gallery
  smoke run - every section including the 1000-button stress grid - peaks at
  2,046 commands and 7,138 text bytes at 3840x2160, so the new caps keep ~4x
  headroom over the heaviest measured frame while cutting `Ui_Output` to
  1.97 MiB. Overflow remains graceful and counted (`dropped_commands`,
  `dropped_text_bytes`); a consumer with heavier frames can raise either cap.
  Net effect on the web demo: initial wasm memory drops from 20.8 MB to
  12.5 MB.
- `gfx.BATCH_MAX_VERTICES` / `BATCH_MAX_INDICES` are now `#config`
  overridable. Their defaults are **unchanged**: the same measurement shows
  4K already reaching 41% of the vertex capacity, so these are correctly
  sized for desktop and only a target with a known-small framebuffer should
  lower them.
- `ui_gfx.App` now delegates UI lifecycle ownership to `Session`.
- Direct `ui_gfx.Adapter` lifecycle calls are classified as backend-only, and
  consumer checks enforce the documented UI API layers.
- UI focus uses stable widget IDs, facade APIs use rectangle bounds consistently,
  and facade scaling ownership is explicit.
- Chart and dropdown frame allocations are bounded.
- Gallery rendering receives its UI frame explicitly.
- `App_Session_Config`, `App_Session`, and `app_session_*` remain available
  through `v0.2.x` and are removed in `v0.3.0`.

### Fixed

- Web: every edge-driven key was dropped. The browser backend kept its own
  copy of the key/char/wheel staging buffer, named identically to the shared
  one in `Input`, and published it straight into `Input.pressed` / `released`
  / `repeat` from `platform_poll_events`; `_input_publish_staged` then
  assigned over the result later in the same `input_poll` and erased it.
  Typed characters kept working because they travel in the char ring, so the
  fault read as flaky input rather than a dead code path while Enter,
  Backspace, Delete, Tab and the arrow keys did nothing. The duplicate buffer
  is gone: the DOM entry points now stage into `g.inp` through the same
  `_stage_key` / `_stage_char` the GLFW callbacks use, leaving one staging
  buffer and one publisher, and `_input_publish_staged` asserts on entry that
  nothing published ahead of it so the ordering contract cannot rot again.
  Only the browser's live platform-query state (key held, cursor position,
  button held, hover) and the touch-tap button edges remain web-local.
- Web: Enter is consumed on the hidden IME proxy, so it can no longer insert a
  newline into the `<textarea>` value the engine never reads.
- `text_input` boxes tall enough to show two or more lines now type a newline
  on Enter instead of submitting, matching every platform's text area. New
  `text_input_visible_lines` / `text_input_default_submit` expose the rule.
  One-line fields are unchanged, and Shift+Enter still types a newline there.
- Enter no longer both accepts a spelling suggestion and inserts a newline in
  the same frame.
- Pane paint commands are emitted in screen coordinates.
- Gallery clear and navigation colors follow the active theme.
- Web application state uses retained userdata across asynchronous startup.

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

- **`ingot:gfx`** - windowing, WebGPU batch rendering, shapes, textures, text,
  input, audio, gamepads, cameras, and a raylib/rlgl-shaped 2D API. Includes
  affine `Camera2D` transforms, per-pipeline blend modes, render targets, an
  opt-in GPU 3D pipeline, coalesced stream uploads, a lazily baked embedded
  default font, and independent multi-context support.
- **`ingot:ui`** - renderer-independent immediate-mode widgets, bounded
  single-pass flow layout, constrained flex sizing, paint output, input
  snapshots, accessibility semantics, themes, charts, markdown, a unified diff
  viewer, listboxes, overlays, and adaptive frame pacing.
- **`ingot:ui_gfx`** - adapter that captures `gfx` input, replays UI paint
  output, applies platform output, and hosts an `App_Session`.
- **`ingot:net`** - background HTTP and self-healing reconnecting WebSockets,
  including verified `wss://` with loopback TLS tests.
- **`ingot:prefs`, `ingot:sys`** - native settings files and web `localStorage`
  behind one API; URLs, native file dialogs, and platform integration.
- **`ingot:term`, `ingot:libvterm`, `ingot:pty`** - libvterm bindings with
  committed static libraries, PTY pumping, key translation, `forkpty` on Unix,
  and ConPTY on Windows.
- **`ingot:accesskit`** - AccessKit C API bindings with native static libraries;
  UI semantics bridge to native accessibility, and mirror to the DOM on web.
- **`ingot:testx`** - deterministic PRNG and inline snapshot helpers.
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

[Unreleased]: https://github.com/Nic-vdwalt/ingot/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Nic-vdwalt/ingot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Nic-vdwalt/ingot/releases/tag/v0.1.0
