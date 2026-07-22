# ingot

**A pure-Odin, immediate-mode app engine on WebGPU — the same source runs natively and in the browser.**

ingot is a self-contained, immediate-mode game/app engine built on Odin's
bundled `vendor:wgpu`. One renderer targets **native** (macOS/Metal,
Windows/D3D12, Linux/Vulkan) **and the browser** (WASM + WebGPU) — no raylib,
no OpenGL, no external libraries to vendor.

Its public API deliberately mirrors raylib's shape (`Color`, `Vector2`,
`Rectangle`, `Font`, `Texture2D`, `Draw*`, `IsKey*`, …), so migrating an
existing Odin app is mechanical: swap `import rl "vendor:raylib"` for
`import rl "ingot:gfx"` and your `rl.*` call sites keep resolving.

---

## Highlights

- **Pure Odin + WebGPU.** Built on `vendor:wgpu` / `vendor:glfw` / `vendor:stb`,
  all of which ship with Odin. Zero external dependencies to vendor.
- **Native and web from one source.** Write `main()` once; it compiles to
  native and to WASM + WebGPU behind a small platform seam.
- **raylib-shaped API.** Drop-in type and procedure names ease migration and
  flatten the learning curve.
- **Immediate-mode all the way up.** Callers own their state and pass it in each
  frame — no hidden retained trees.
- **Batteries included.** Windowing, 2D batched rendering, textures, an
  stb_truetype glyph-atlas text stack, an immediate-mode widget toolkit, HiDPI
  handling, custom window chrome, frame pacing, a terminal stack, and settings
  persistence.
- **Crisp on every display.** Per-size glyph atlases rasterized at native
  resolution × DPI, integer-pixel layout, platform-correct scaling policy.

## Packages

| Package          | Role | Summary |
|------------------|------|---------|
| `ingot:gfx`      | graphics core (raylib) | window/context, 2D shapes, textures, text atlas, input, math, `Camera2D`/`Camera3D`, plus an `rlgl` shim |
| `ingot:ui`       | widget toolkit (raygui) | buttons, text input, checkbox/radio/slider, dropdown, modal, context menu, tooltip, panels, scroll panes, markdown, word wrap, theming, HiDPI scaling, keyboard focus rings, custom title bar & window chrome, frame pacing |
| `ingot:prefs`    | persistence | per-app settings storage — native settings file (`core:*`-only) + web `localStorage` backend, same `read`/`write` API |
| `ingot:net`      | networking | background HTTP GET `Fetcher` (native `core:net` + worker threads / web `fetch()`) with optional cache validator, and an RFC 6455 `WebSocket` client (native hand-rolled / web `WebSocket`) |
| `ingot:sys`      | system integration | `open_url` — launch the default browser (native `open`/`xdg-open`/`ShellExecuteW` / web `window.open`) |
| `ingot:term`     | terminal core | libvterm + PTY, per-frame pump, key→VT input translation (rendering is app-side) |
| `ingot:libvterm` | bindings | Odin bindings for libvterm 0.3.3, prebuilt static libs committed for macOS/Windows |
| `ingot:pty`      | PTY | `forkpty` on unix, ConPTY on Windows |

`ingot:ui` imports only `core:*` and `ingot:gfx`; `ingot:prefs`, `ingot:net`,
and `ingot:sys` are `core:*`-only. The web targets of `ingot:net`/`ingot:sys`/
`ingot:prefs` call JS bridges provided by `web/ingot_app.js` (merged into the
wasm imports by the app boot script — `window.ingotApp.{ws,http,store,open}Imports`).
The terminal stack ships prebuilt native libs, so consumers need **zero linker
flags**.

## Installation

Add ingot as a submodule and register it as a collection:

```sh
git submodule add <url> libs/ingot
odin build src -collection:ingot=libs/ingot
```

```odin
import rl    "ingot:gfx"    // the raylib-shaped graphics core
import ui    "ingot:ui"
import prefs "ingot:prefs"
import term  "ingot:term"
```

**Requirements**

- A recent Odin toolchain (`vendor:wgpu`, `vendor:glfw`, `vendor:stb` ship with it).
- The wgpu-native prebuilt lib under `<odin>/vendor/wgpu/lib/` (Odin's build
  error links the download if missing).
- For the web target: a WebGPU browser (Chrome/Edge 113+, Safari 18+).

## Quick start

```odin
when ODIN_OS == .Darwin {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI})
} else {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
}
rl.InitWindow(w, h, title)   // rl == ingot:gfx
ui.apply_platform_dpi()      // pass user_scale > 0 to override the OS default
ui.init_font()

for !rl.WindowShouldClose() {
    ui.dpi_refresh()         // re-rasterizes on monitor-move scale changes
    rl.BeginDrawing()
    rl.ClearBackground(ui.BG_PRIMARY)
    // ... draw ...
    rl.EndDrawing()
}
```

### Migrating a raylib app

Replace `import rl "vendor:raylib"` with `import rl "ingot:gfx"` (and
`import rlgl "vendor:raylib/rlgl"` with `import rlgl "ingot:gfx/rlgl"`). Because
`ingot:gfx` mirrors raylib's type and procedure names, the `rl.*` call sites
keep resolving.

## Recipes

### Widget gallery

`examples/gallery` is the imgui_demo.cpp equivalent: every widget (buttons,
inputs, panes, charts, markdown, layout, overlays) plus a 1000-button stress
tab and an F12 metrics overlay. Living documentation and copy-paste cookbook:

```sh
odin run examples/gallery -collection:ingot=.
# renderer counters in the F12 overlay need:
odin run examples/gallery -collection:ingot=. -define:INGOT_RENDER_STATS=true
```

### Overlay popups + input routing (occlusion)

Popups/tooltips record their draws on a one-frame **overlay layer** so they
paint above everything drawn later, and **claim** their rect with the input
router so clicks never leak through to the widgets underneath (claims occlude
on the next frame — bounded double buffer, no retained widget state):

```odin
ui.overlay_begin(rect, claim_input = true)   // claim_input=false for passive tooltips
ui.overlay_rounded(rect, 0.1, 6, ui.theme.bg_popup)
ui.overlay_text("Hello", x, y, ui.FONT_SIZE, ui.theme.fg_primary)
ui.overlay_end()
// replayed automatically by ui.apply_cursor() before rl.EndDrawing()
```

Modal panels call `ui.route_claim_all()` while open. Widgets built on
`ui.interact` (btn, scrollbar, collapsible_header, text inputs) consult the
claims automatically; custom widgets can call `ui.route_occluded(mouse)`.
`ui.interact(rect, &latch)` is the shared press/drag/release protocol —
caller-owned latch, one active drag at a time.

### Form controls, popups & keyboard focus

Checkbox, radio, slider, dropdown, tooltip, modal, and context menu are plain
calls with caller-owned state and `Rect_I32` geometry (the convention for all
new widgets — a rect plus a config/state struct, not positional scalar
soup). Every control takes an optional `ui.Focus_Opt{&focus, id}` linking it
to a `form_focus` cycler slot: Tab/Shift+Tab move focus (ids are 1-based),
a theme-colored ring marks the focused control, and Space/Enter activates it
(arrows adjust sliders; panes opt into PageUp/PageDown/Home/End scrolling via
`pane_begin(..., keyboard = true)`).

```odin
focus: int                     // 0 = nothing focused
dd: ui.Dropdown_State
modal: ui.Modal_State
menu: ui.Context_Menu_State
tip: ui.Tooltip_State

ui.form_focus_cycle(&focus, 3)  // Tab / Shift+Tab across 3 controls
ui.checkbox({x, y, w, 24}, "Enable", &enabled, {&focus, 1})
ui.slider({x, y2, w, 24}, &volume, 0, 100, 5, {&focus, 2})
ui.dropdown({x, y3, w, 28}, backends, &sel, &dd, sw, sh, {&focus, 3})
ui.tooltip(&tip, {x, y2, w, 24}, "hover hint", sw, sh)

if open_clicked do modal.open = true
if modal.open {
    body := ui.modal_begin(&modal, "Title", ui.sc(420), ui.sc(200), sw, sh)
    // ... draw inside body; Tab-cycle only modal widgets (focus trap) ...
    ui.modal_end(&modal) // Escape / click-outside sets modal.dismissed
}

if right_clicked do ui.context_menu_open(&menu, mx, my)
chosen := ui.context_menu(&menu, items, sw, sh) // -1 until a row is picked
```

The UI-scale settings panel is built on `modal_begin`/`modal_end`; the spell
menu popup rides the same overlay/routing layer. See `examples/gallery`
(Widgets + Overlay sections) for all of these live.

### Metrics/debug overlay

`ui.draw_debug_overlay(x, y)` renders FPS, frame time, flush counts **by
cause** (pipeline/texture/scissor/...), upload bytes, buffer churn, the text
measure cache, and overlay/router counters. Renderer counters are compile-
gated: build with `-define:INGOT_RENDER_STATS=true` (zero cost by default).

### Window chrome (backdrop + custom title bar)

A macOS vibrancy ("glass") backdrop, a Windows 11 Mica + dark title bar, and a
**frameless custom title bar on Windows** (drawn min/max/close buttons + drag
region). macOS/Linux keep their native title bar.

```odin
// macOS needs a transparent framebuffer for the vibrancy backdrop.
when ODIN_OS == .Darwin {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI, .WINDOW_TRANSPARENT})
} else {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
}
rl.InitWindow(w, h, title)

ui.apply_window_style()   // macOS: vibrancy / Windows: Mica + dark titlebar
ui.titlebar_init()        // Windows: strip native frame + install subclass

for !rl.WindowShouldClose() {
    header_h := ui.TAB_BAR_HEIGHT      // inset content below the header
    // ... draw content starting at y = header_h ...
    ui.draw_app_header(title, screen_w) // drawn last, on top of content

    busy := app_activity || ui.titlebar_consume_activity()
    ui.pacer_frame(&pacer, busy)
}
```

`draw_app_header(title, screen_w) -> header_h` draws the header strip, title,
hairline border, and (Windows) caption buttons, then publishes the non-client
layout so the strip drags the window. Off Windows the `titlebar_*` procedures
are no-ops. Dependencies stay within the Odin stdlib — no external linker flags.

### Frame pacing

`Frame_Pacer` matches the monitor refresh rate while there is input, animation,
or app-declared work, then drops to an idle FPS after a grace period. It uses
only non-consuming input queries, so it never steals events from the app.

```odin
pacer := ui.pacer_init(60, 15, 2.5)   // target fps, idle fps, grace seconds

for !rl.WindowShouldClose() {
    // ... update + draw ...
    rl.EndDrawing()

    busy := animating || work_in_flight   // app-side activity hints
    ui.pacer_frame(&pacer, busy)
}
```

Call `ui.pacer_note_activity(&pacer)` for activity the pacer can't observe
(e.g. data arriving on a background channel).

### Event-driven frames (power-save mode)

For tools/UI apps that don't need continuous rendering, the engine can idle
completely between events — no frame, no GPU submit, ~0% CPU while nothing
changes. The swapchain keeps the last image on screen; frames resume instantly
on input, OS damage (uncover/resize), or an explicit redraw request:

```odin
rl.InitWindow(640, 400, "my tool")
rl.EnableEventWaiting()               // or rl.SetFrameStrategy(.Event_Driven)

rl.run(frame)                          // both run() and manual loops idle
```

- `rl.RequestRedraw()` — schedule a frame now. Thread-safe: call it from net
  callbacks or workers when background data changes the UI.
- `rl.RequestRedrawIn(0.5)` — schedule a timed repaint (caret blink,
  delayed animations). The earliest pending deadline wins.
- `rl.DisableEventWaiting()` — back to continuous mode (the default; games
  should stay continuous).

After any activity a short settle burst (3 frames) runs so hover/release
visuals finish. `ingot:ui` widgets already request what they need: the
text-input caret blinks via `RequestRedrawIn`, and `spinner` /
`progress_bar_animated` keep frames coming while animating. On web the rAF
loop stays alive but skips idle frames; hidden tabs are suspended by the
browser for free. See `examples/idle_demo` and `docs/rendering.md`.

### Scroll panes

```odin
@(private = "file") my_pane: ui.Pane

ui.pane_reset(&my_pane)   // on view reset

// each frame:
y := ui.pane_begin(&my_pane, x, top, w, view_h)   // scissor on; y is scrolled origin
// ... draw content downward from y ...
ui.pane_end(&my_pane, x, top, w, view_h, y)       // measures content, draws scrollbar
```

### UI-scale settings modal + persistence

```odin
// open: seed selection from the current scale
app.settings_selected = ui.settings_scale_preset_index(app.ui_scale)

// each frame while open, after other panels:
res := ui.draw_scale_settings_panel(&app.settings_selected, app.ui_scale, w, h)
if res.applied {
    app.ui_scale = res.ui_scale            // 0 = auto
    ui.apply_platform_dpi(app.ui_scale)
    ui.reset_font_atlases()
    ui.invalidate_scale_caches()
    prefs.write("myapp", "prefs.json", encoded)
}
if res.dismissed { app.settings_open = false }
```

### Terminal

```odin
import term "ingot:term"

ts, ok := term.term_start(cols, rows, "/bin/zsh")

// each frame:
term.term_pump(&ts)              // drain PTY, feed libvterm
term.term_handle_input(&ts)      // raylib input → VT bytes
term.term_handle_input(&ts, {.W, .T})  // optionally skip chords the app owns

// draw ts's cell grid with ingot:ui text calls (rendering is app-side)
```

`term_start` takes optional `default_fg` / `default_bg` RGB params so the
palette matches the host app's theme.

### Self-healing WebSocket

`ingot:net`'s `WebSocket` client auto-reconnects by default. A background worker
runs dial → RFC 6455 handshake → receive loop, and **re-dials on every drop**
until `ws_close`, so a transient network blip recovers on its own. The live
socket also carries a recv read deadline + PING heartbeat, so a silent half-open
drop (Wi-Fi hand-off, VPN change, laptop sleep — no FIN/RST) is detected within
`WS_DEAD_AFTER` (~15 s) instead of hanging the worker forever.

```odin
import net "ingot:net"

sock := net.ws_init()
net.ws_start_connect(&sock, host, port, 9999)  // never blocks; retries internally

last_gen := 0
// each frame:
gen := net.ws_conn_gen(&sock)                  // ++ on each successful (re)handshake
if gen != last_gen && sock.state == .Connected {
    // A fresh connection is live — the previous server-side subscription (if
    // any) is gone. Re-establish app-level state here (e.g. resend a subscribe
    // message with your last-seen sequence so the server backfills the gap).
    resubscribe(&sock)
    last_gen = gen
}
for msg in net.ws_drain(&sock) { /* handle */ }
```

`sock.state` exposes `.Connecting` / `.Reconnecting` / `.Connected` /
`.Disconnected` for a connection-status UI. The library is protocol-agnostic —
it recovers the *transport*; re-establishing any app-level subscription is the
consumer's job, keyed off `ws_conn_gen`. Pass `auto_reconnect = false` semantics
via a one-shot caller if you need the legacy behaviour (worker exits on the
first drop).

## Web / WASM

Because the renderer is built on `vendor:wgpu`, the **whole engine** — the `gfx`
batch renderer, `ui` widgets, and the stb_truetype text atlas — runs in the
browser via WASM + WebGPU (`ODIN_OS == .JS`, canvas surface via
`SurfaceSourceCanvasHTMLSelector`).

```sh
bash build_web.sh                        # -> web/ingot_web.wasm (+ odin.js, wgpu.js)
(cd web && python3 -m http.server 8000)  # open http://localhost:8000
```

`web/demo.odin` drives the real engine from the *same source* that runs
natively (`InitWindow` → `run(frame)`, a baked font via `DrawTextEx`,
mouse + keyboard input).

### The platform seam (`when ODIN_OS == .JS`)

All OS-specific plumbing lives behind a small platform seam, so `gfx` carries no
windowing-backend import. Every `platform_*` proc has native and web
implementations selected by build tag:

| Concern | Native (`#+build !js`) | Web (`#+build js`) |
|---------|------------------------|--------------------|
| Window + surface | GLFW window → `glfwglue.GetSurface` | canvas → `SurfaceSourceCanvasHTMLSelector` |
| GPU init | synchronous busy-wait | async adapter→device callback |
| Frame loop | `run()` blocks in `for !WindowShouldClose()` | RAF drives exported `step(dt)` |
| Input | GLFW key/char/scroll callbacks | DOM events → staging buffer → same `Input` struct |
| Timing | `core:time` (monotonic) | `performance.now` |
| DPI / resize | GLFW content scale + framebuffer size | canvas CSS size × `devicePixelRatio` |

Consumer apps write `main()` once; the native GLFW path is unchanged and the web
path is purely additive.

## DPI & text readability

Text stays crisp via per-size glyph atlases rasterized at native size × DPI (no
downscaling blur), integer-pixel layout, and a platform-correct pairing of the
two scaling knobs:

| Platform      | .WINDOW_HIGHDPI | ui_scale                | font_dpi                |
|---------------|-----------------|-------------------------|-------------------------|
| macOS         | yes             | 1.0 (points)            | `GetWindowScaleDPI().x` |
| Windows/Linux | no              | `GetWindowScaleDPI().x` | 1.0                     |

macOS composites HiDPI itself, so scaling lives in the atlas (`font_dpi`) at
physical resolution. On Windows/Linux screen coordinates are already physical
pixels, so scaling lives in `ui_scale` and the atlas stays at 1.0 — setting both
would double-scale and blur.

## Roadmap

ingot already runs the full 2D UI + terminal stack on WebGPU across native
targets (macOS/Metal verified) and the web target. The roadmap below tracks the
remaining GPU-heavy and cross-platform work.

### Now (in progress)

- **On-device validation of the opt-in GPU 3D path.** Depth-tested indexed
  sphere meshes render through a separate pass without changing legacy
  `BeginMode3D`; Metal is verified, while D3D12/Vulkan and browser validation
  remain.
- **HDR bloom/tonemap consumer migration.** ingot now names and preserves its
  render-target Y-flip convention; openalloy's multipass galaxy chain can migrate
  independently without changing nvim render-texture behavior.

### Next

- **Indexed instancing** (`DrawVertexArrayElementsInstanced`) for 3D node bodies.
- **Transparent/additive GPU 3D pipelines** with explicit depth-read/write policy.
- **macOS transparent-window fallback compositing** if a device exposes only
  `Unpremultiplied`; premultiplied mode is already preferred when supported.

### Later

- **Web parity for the 3D / galaxy path**, whose wgpu features may lag on the JS
  backend.
- **Clipboard and drag-and-drop parity** on the web target.

### Recently shipped

- Event-driven frame scheduling (`SetFrameStrategy(.Event_Driven)` /
  `EnableEventWaiting`): idle apps render no frames at all — the native pump
  blocks in `glfw.WaitEventsTimeout`, the web `step()` early-outs under rAF —
  with `RequestRedraw` / `RequestRedrawIn` for background and timed repaints.
- Submission-tracked geometry streaming with unique vertex/index ranges replaces
  per-flush GPU buffer creation; universal indexed 2D batching cuts duplicated
  quad vertices, and dynamic uniform records preserve per-draw shader state.
- A deterministic renderer fixture, opt-in depth-tested GPU sphere pass, selected
  surface-alpha diagnostics, and additive generation-checked `Frame`/`draw_*`
  wrappers. Existing PascalCase, `rlgl`, RT orientation, and public layouts remain
  compatible.
- Full `ingot:ui` + text atlas running on the browser/WASM target via the
  platform seam.
- WebGPU engine capabilities: per-pipeline blend modes
  (`BeginBlendMode` ALPHA/ADDITIVE/MULTIPLIED/CUSTOM), real offscreen render
  targets, custom WGSL shaders with uniform reflection, format-aware batch
  pipelines (HDR `RGBA16Float`), the rlgl matrix stack + framebuffer helpers,
  real GPU instancing, and a CPU-projected 3D layer
  (`BeginMode3D`/`DrawBillboard`/`DrawMesh`/`DrawLine3D`).
- Composer undo/redo + mention pills, markdown file pills, a cross-platform
  spellcheck subsystem, split-view + path-truncation widgets, and a full
  theme/metric set with HiDPI scaling.

## Building the terminal libs

Prebuilt libvterm static libs are committed for darwin_arm64 / darwin_amd64 /
windows_amd64 and referenced via relative foreign imports, so consumers need no
linker flags. Linux links a system libvterm. Rebuild from the vendored C source
with:

```sh
scripts/build-libvterm.sh    # macOS
scripts/build-libvterm.bat   # Windows
```

## Memory-safety testing

Deterministic fuzz harnesses run under **AddressSanitizer** with a
`mem.Tracking_Allocator` (leaks / bad frees fail the run):

```sh
fuzz/run.sh net            # sim transport + HTTP response parser + WS frame parser (random seed)
fuzz/run.sh net 12345      # reproduce a specific seed
fuzz/run.sh ui             # widget toolkit harness
fuzz/run.sh term           # in-package fuzz tests via `odin test` (private procs)
```

All targets build with `-debug -sanitize:address`; `net` adds
`-define:INGOT_NET_SIM=true` so the simulated transport's clone/deliver/free
cycle is exercised, and also drives the RFC 6455 WebSocket frame parser
(`ws_parse_frame`) with random and mutated-valid frames. Harnesses live in
`fuzz/net/main.odin`, `fuzz/ui/main.odin`, and `term/term_input_fuzz_test.odin`
(mirrored by `net/http_fuzz_test.odin` and `net/ws_fuzz_test.odin`).
These run locally only — they are not part of CI. Regular builds keep Odin's
bounds checks enabled (never pass `-no-bounds-check`).

## Coding style

`ingot` follows **Tiger Style** (adapted from TigerBeetle for Odin): safety >
performance > developer experience, assertions everywhere (≥ 2 per procedure),
bounded loops, no recursion, explicit sized types, 70-line procedures, and
100-column lines. See [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) and
[`AGENTS.md`](AGENTS.md). The Tiger Style gate is `bash scripts/check.sh`
(`odin check -vet -strict-style`); format with `odinfmt -w .`.

## License

See repository for license details.
