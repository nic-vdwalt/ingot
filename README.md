# ingot

**The app framework for Odin — ship a polished, fast, native + web desktop
tool without Electron.**

ingot is a self-contained, immediate-mode app framework with game-engine DNA,
built on Odin's bundled `vendor:wgpu`. One renderer targets **native**
(macOS/Metal, Windows/D3D12, Linux/Vulkan) **and the browser** (WASM + WebGPU)
— no raylib, no OpenGL, no external libraries to vendor. 2D games are a
supported use case; polished desktop tools are the mission.

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
  frame — no hidden retained trees, no widget-ID hashing, no state that can
  accumulate invisibly.
- **Native feel, not lowest-common-denominator.** macOS vibrancy, Windows 11
  Mica, frameless custom title bars, platform-correct HiDPI — apps look like
  they belong on the OS.
- **Energy-efficient by design.** Event-driven frames idle at ~0% CPU between
  events; a frame pacer matches monitor refresh only while busy.
- **Batteries included.** Windowing, 2D batched rendering, textures, an
  stb_truetype glyph-atlas text stack, an immediate-mode widget toolkit, audio
  (miniaudio native / WebAudio web), gamepad input, HiDPI handling, custom
  window chrome, frame pacing, a terminal stack, and settings persistence.
- **Crisp on every display.** Per-size glyph atlases rasterized at native
  resolution × DPI, integer-pixel layout, platform-correct scaling policy.

## Packages

| Package          | Role | Summary |
|------------------|------|---------|
| `ingot:gfx`      | graphics core (raylib) | window/context, 2D shapes, textures, text atlas, input, math, `Camera2D`/`Camera3D`, plus an `rlgl` shim |
| `ingot:ui`       | widget toolkit (raygui) | buttons, text input, checkbox/radio/slider, dropdown, modal, context menu, tooltip, panels, scroll panes, markdown, word wrap, theming, HiDPI scaling, keyboard focus rings, custom title bar & window chrome, frame pacing |
| `ingot:prefs`    | persistence | per-app settings storage — native settings file (`core:*`-only) + web `localStorage` backend, same `read`/`write` API |
| `ingot:net`      | networking | background HTTP GET `Fetcher` (native `core:net` + worker threads / web `fetch()`) with optional cache validator, and an RFC 6455 `WebSocket` client (native hand-rolled / web `WebSocket`) |
| `ingot:sys`      | system integration | `open_url` — launch the default browser (native `open`/`xdg-open`/`ShellExecuteW` / web `window.open`); `open_file_dialog`/`save_file_dialog` — native file dialogs (osascript / comdlg32 / zenity·kdialog; web returns `ok = false` — use canvas drag-and-drop) |
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

Commit the submodule gitlink so every build uses one reviewed Ingot revision.
Update that pointer explicitly rather than building consumers against a floating branch.

```odin
import rl    "ingot:gfx"    // the raylib-shaped graphics core
import ui    "ingot:ui"
import prefs "ingot:prefs"
import term  "ingot:term"
```

**Requirements**

- Tested Odin toolchain: `dev-2026-06:285f6d87b`. Pin this revision in consumer CI.
- The wgpu-native prebuilt lib under `<odin>/vendor/wgpu/lib/` (Odin's build
  error links the download if missing).
- For the web target: a WebGPU browser (Chrome/Edge 113+, Safari 18+).

### HTTP Fetcher ownership and backpressure

Every Fetcher submission returns `bool`. Only mark application work pending when the
submission returns `true`; `false` means the request was invalid, stopped, or rejected
by bounded work or undrained-result capacity. Native requests reserve one result slot;
the deterministic simulator reserves two because duplicate delivery is possible. Call
`fetcher_stop` during orderly shutdown.

`fetcher_drain` returns temporary slice storage that must be consumed before the next
`free_all(context.temp_allocator)`. Each returned `Fetch_Result.body` transfers to the
caller and must be deleted exactly once. The Fetcher frees only undrained results and
unsubmitted work that it still owns when stopped.

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
# self-driving crash smoke (steps every scale preset, theme, and section):
scripts/smoke-gallery.sh
```

Flex sizing is opt-in and remains immediate-mode. Declare sibling sizes before
emitting them, then draw in source order:

```odin
ui.push_row(&layout, 40, gap = 8)
ui.flex_begin(&layout, {
	ui.flex_fixed(80),
	ui.flex_fit(measured_label_width, min_size = 48),
	ui.flex_grow(),
})
draw_sidebar(ui.flex_next(&layout))
draw_label(ui.flex_next(&layout))
draw_content(ui.flex_next(&layout))
ui.layout_pop(&layout)
```

`FIT` receives an intrinsic pixel size measured by the caller. `GROW` divides
free space by weight, `PERCENT` uses the gap-free content extent, and min/max
constraints are inclusive. Existing `next`, `row_weights`, and `ui_slot` code
does not change.

The sizing model was inspired by [Clay](https://github.com/nicbarker/clay),
Nic Barker's high-performance C UI layout library.

Use `Fit_Column` when a container must fit fixed or caller-measured child heights.
Resolve the child rectangles first, call `fit_column_end` for the exact content
bounds, then draw the container followed by its children. Unlike bounded
`Layout`, it does not clamp against a supplied height. It remains single-pass
and allocation-free: there is no retained tree, hidden state, recursive
measurement, or second widget invocation. Intrinsic text and widget dimensions
remain explicit caller inputs; `GROW` and `PERCENT` belong in bounded layouts.

### Breakout (audio + gamepad + web, one source)

`examples/breakout` is the Phase 1 proof game: synthesized sounds (no asset
files), keyboard + gamepad control, and the same source running natively and
in the browser:

```sh
odin run examples/breakout -collection:ingot=.
bash build_web.sh examples/breakout    # then serve web/ and open it
```

### Audio

Raylib-shaped: `vendor:miniaudio` natively (fixed generation-checked sound
pool, no per-play allocation), WebAudio in the browser. If no output device is
available, `IsAudioDeviceReady()` stays false and every call is a safe no-op.

```odin
rl.InitAudioDevice()

snd := rl.LoadSound("hit.wav")         // wav/ogg/mp3/flac — native only
beep := rl.LoadSoundFromWave(wave)     // caller-owned PCM — native AND web
rl.PlaySound(beep)                     // restarts from the top (raylib parity)
rl.SetSoundVolume(beep, 0.6)
rl.SetSoundPitch(beep, 1.2)

music := rl.LoadMusicStream("bgm.ogg") // streamed on the device thread
rl.PlayMusicStream(music)
rl.UpdateMusicStream(music)            // no-op both targets; call-site parity
```

Web notes: browsers have no file paths, so `LoadSound`/`LoadMusicStream`
return invalid handles there — embed bytes (`#load`) and use
`LoadSoundFromWave` (see `examples/breakout`). Autoplay policy suspends the
AudioContext until the first click/keypress; earlier plays are dropped
silently.

### Gamepad

Polled per frame like the rest of the input state. Native uses GLFW's SDL
mapping database; the browser uses the W3C standard mapping — both remap into
the same raylib button layout (unit-tested tables in `gfx/types.odin`).

```odin
if rl.IsGamepadAvailable(0) {
    x := rl.GetGamepadAxisMovement(0, .LEFT_X)      // -1..1, triggers rest at -1
    if rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN) do jump()
    name := rl.GetGamepadName(0)                    // temp-allocated
}
```

### File dialogs & dropped files

```odin
import "ingot:sys"

if path, ok := sys.open_file_dialog("Open project"); ok { load(path) }
if path, ok := sys.save_file_dialog("Export", "out.json"); ok { save(path) }
```

Native dialogs block until dismissed (osascript / comdlg32 / zenity·kdialog;
missing zenity on Linux → `ok = false`). On web both return `ok = false` —
the browser path is drag-and-drop onto the canvas, which now works on both
targets with contents access. Hover is absolute current state; applications own
target selection and can derive enter/leave edges from their previous value:

```odin
if rl.IsFileDragOver() {
    draw_drop_target()
}

if rl.IsFileDropped() {
    files := rl.LoadDroppedFiles()
    for i in 0 ..< i32(files.count) {
        data := rl.GetDroppedFileData(i)  // bytes on native AND web
        defer delete(data)
        ingest(string(files.paths[i]), data)
    }
    rl.UnloadDroppedFiles(files)
}
```

`IsFileDropped` stays true until `UnloadDroppedFiles`. `FilePathList` paths are
borrowed until unload, replacement by a later drop, or `CloseWindow`; data from
`GetDroppedFileData` is caller-owned. A drop retains at most 16 paths with 64
KiB aggregate native path bytes. Browser drops retain at most 16 files of 32
MiB each and expose bare names plus bytes. Native hover uses AppKit on macOS,
OLE on Windows, and best-effort XDND observation on X11; Wayland and unsupported
native backends preserve completed drops but report hover as false.

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
soup). Auto-layout controls accept explicit `Focus_Id` values: Tab order still
follows draw order, while logical identity survives insertion and reorder. A
theme-colored ring marks focus, Space/Enter activates it, and arrows adjust
sliders. Calls without IDs remain available for fixed, unconditional forms.

```odin
form: ui.Ui
dd: ui.Dropdown_State
modal: ui.Modal_State
menu: ui.Context_Menu_State
tip: ui.Tooltip_State

ui.ui_begin(&form, x, y, w, h)
ui.checkbox(&form, ui.Focus_Id(1), "Enable", &enabled)
ui.slider(&form, ui.Focus_Id(2), &volume, 0, 100, 5)
ui.dropdown(&form, ui.Focus_Id(3), backends, &sel, &dd)
ui.ui_end(&form)
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
(Widgets + Overlay sections) for all of these live. State ownership, teardown,
stable dynamic-list IDs, and sequential compatibility are detailed in
[`docs/ui-state.md`](docs/ui-state.md).

### Accessibility (screen readers, high contrast, reduced motion)

Widgets record a per-frame **semantic buffer** (role, rect, label, state) as
they draw — an output buffer like the draw list, no retained tree, no
widget-ID hashing. Node identity derives from caller-owned state (the
form-focus slot + id, or a text input's `field_id`), never from call sites.
Two consumers read it:

- **Native**: [AccessKit](https://accesskit.dev)'s C API drives
  NSAccessibility / UIA / AT-SPI. The full tree is pushed each frame and
  AccessKit diffs; the factory only runs while a screen reader is active, so
  idle cost without AT is one branch per frame. Prebuilt static libs ship in
  `accesskit/lib/` (no linker flags; opt out with
  `-define:INGOT_ACCESSKIT=false`).
- **Web**: semantic nodes mirror into *real DOM controls* with ARIA roles
  (buttons, checkboxes, radios, ranges) positioned over the canvas —
  stronger browser AT support than a canvas-side tree, riding the same
  frame-stamped overlay as text-input autofill mirroring.

```odin
ui.a11y_init()                 // once, after InitWindow
for !rl.WindowShouldClose() {
    rl.BeginDrawing()
    ui.begin_cursor_frame()
    ui.focus_scope_cycle()     // app-wide Tab order across all forms/panes
    // ... draw widgets ...
    ui.apply_cursor()
    ui.a11y_frame_end()        // push tree + apply AT actions
    rl.EndDrawing()
}
```

AT clicks and focus requests route through the same `focus_activated` path
as Space/Enter, so widgets need no separate handling. `focus_scope_cycle`
Tab-cycles every focusable widget drawn last frame in draw order (per-form
`form_focus_cycle` still works for single forms). The theme carries the rest:
`theme_high_contrast()` (black/white/yellow, WCAG AAA primary text),
`theme.reduced_motion` (hover ease and caret blink snap to final state), and
`set_theme` asserts ≥ 4.5:1 contrast for text/button roles — the same spirit
as the focus-ring visibility assert. Interactive widgets assert non-empty
labels: a nameless control is invisible to assistive tech.

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

**End goal: the app framework for Odin** — the default answer to "I want to
ship a polished, fast, native + web desktop tool without Electron." Games are a
supported use case (2D first), not the mission. The roadmap is sequenced as
proof over features: close credibility gaps, convert features into public
evidence, then build the depth that makes people stay.

### Phase 1 — Close the gaps (now)

- **On-device validation of the opt-in GPU 3D path.** Depth-tested indexed
  sphere meshes render through a separate pass without changing legacy
  `BeginMode3D`; Metal is verified, while D3D12/Vulkan and browser validation
  remain.
- **HDR bloom/tonemap consumer migration.** ingot now names and preserves its
  render-target Y-flip convention; openalloy's multipass galaxy chain can migrate
  independently without changing nvim render-texture behavior.

### Phase 2 — Proof over features

- **Live web gallery** linked from this README — `examples/gallery` running in
  the browser as the primary demo artifact.
- **A flagship public app** built on ingot; the terminal stack (`ingot:term` +
  `ingot:pty`) is the natural candidate.
- **"Port your raylib app in 30 minutes" guide** plus a benchmark page with
  concrete numbers: idle CPU vs continuous-repaint IM libraries, binary size,
  clean compile time.

### Phase 3 — App-engine depth

- **Docking / panel system** — first-class, renderer-owned (no bolt-on seams).
- **Virtualized lists and tables** that stay smooth at millions of rows,
  extending the existing chart widgets.
- **Accessibility hardening** — the semantic layer, AccessKit native
  adapters, web DOM mirror, app-global focus order, high-contrast theme, and
  reduced-motion flag have shipped (see "Accessibility" above). Remaining:
  manual validation passes with VoiceOver (macOS), NVDA (Windows), and
  VoiceOver+Safari / ChromeVox against the web gallery; AT value-setting for
  sliders (Increment/Decrement actions); prebuilt-lib coverage for
  windows_arm64 and linux_arm64.
- **IME and complex text shaping** for non-Latin input.
- **Indexed instancing** (`DrawVertexArrayElementsInstanced`) for 3D node bodies.
- **Transparent/additive GPU 3D pipelines** with explicit depth-read/write policy.
- **macOS transparent-window fallback compositing** if a device exposes only
  `Unpremultiplied`; premultiplied mode is already preferred when supported.
- **Web parity for the 3D / galaxy path**, whose wgpu features may lag on the JS
  backend.

### Explicitly out of scope

- A 3D content pipeline (glTF, skeletal animation, PBR, scene graphs) — the
  GPU 3D pass remains an escape hatch for visualization, not a pillar.
- Mobile / touch targets, until desktop + web is won.
- Scripting layers or editors — Odin's compile speed *is* the iteration story.

### Recently shipped

- **Audio** (`InitAudioDevice`, `LoadSound`, `LoadSoundFromWave`, `PlaySound`,
  music streams): native `vendor:miniaudio` engine with a fixed generation-
  checked sound pool, web WebAudio bridge — same raylib-shaped API on both
  targets.
- **Gamepad input** (`IsGamepadAvailable`, `IsGamepadButtonDown/Pressed/
  Released`, `GetGamepadAxisMovement`): GLFW's SDL mapping database natively,
  the W3C standard mapping in the browser, remapped through unit-tested tables.
- **Cross-platform file drag lifecycle** (`IsFileDragOver`, `IsFileDropped`,
  `LoadDroppedFiles`) plus target-portable `GetDroppedFileData` — browsers
  deliver names + bytes, native reads the dropped path lazily.
- **Native file dialogs** in `ingot:sys` (`open_file_dialog`,
  `save_file_dialog`): osascript on macOS, comdlg32 on Windows,
  zenity/kdialog on Linux — zero new dependencies.
- **`examples/breakout`** — a complete tiny game proving audio + gamepad +
  web export end-to-end, with sounds synthesized at startup (zero asset
  files); `bash build_web.sh examples/breakout` runs it in the browser.
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
fuzz/run.sh net            # sim HTTP transport + HTTP/WS parsers
fuzz/run.sh net 12345      # reproduce a specific seed
fuzz/run.sh ui             # parsers + widget math + a11y semantic buffer
fuzz/run.sh term           # input bytes + vterm + PTY pump/resize/EOF fuzz
fuzz/run.sh interact       # widget interaction sequences (headless synthetic input)
fuzz/run.sh input          # text-input edit ops: caret/selection/undo/pills
fuzz/run.sh wsreconn       # concurrent WS reconnect state machine vs sim transport
fuzz/run.sh tsan           # TSan: WS worker + HTTP pool + a11y action queue
fuzz/run.sh gfx-frame      # WINDOWED: GPU resource-lifecycle fuzzer (see below)
```

`interact` drives real widgets (buttons, checkboxes, sliders, dropdown,
modal, context menu) with random synthetic event sequences through the
compile-gated input sim seam (`-define:INGOT_INPUT_SIM=true`,
`gfx/input_sim.odin`) and checks routing/focus/latch/semantic invariants
under any ordering. `input` fuzzes the text-input edit state machine
in-package at 200k ops (the same test runs at 2k ops in `scripts/test.sh`).
`term` additionally drives `term_pump`'s real drain/EOF loop and public
`term_resize` path through the scripted PTY (`INGOT_PTY_SIM`), including
resizes between split UTF-8 chunks.

`wsreconn` keeps the **real worker thread, mutexes, atomics, condition
variable, queue, and reconnect loop**, replacing only socket I/O with a
seed-scripted transport (`INGOT_WS_SIM`) that produces dial failures,
handshake faults, split/garbage frames, server closes, cuts, and liveness
timeouts. It checks `conn_gen`, close/join, queue ownership, and watchdog
invariants under concurrent send/drain/state polls. `tsan` runs this harness,
the 8-worker HTTP fetch-pool tests, and the a11y action-queue producer/drain
stress under ThreadSanitizer; ASan and TSan are separate binaries because
they cannot compose. Every `soak` round appends this TSan phase. term/pty are
single-threaded by design, so TSan there would exercise nothing.

`gfx-frame` opens a real window and interleaves resource destruction —
font-atlas resets, texture/render-target unloads, UI rescaling, window
resizes — *inside* live frames, catching the destroy-before-submit bug class
(wgpu validation aborts) that headless tests can't reach. It builds with
`-define:INGOT_GPU_STRICT=true` so any validation message aborts the run. It
needs a display, so it is excluded from `all`/`soak`; run it explicitly
after touching GPU resource lifetimes. `scripts/smoke-gallery.sh` covers the
same class end-to-end through the gallery's real event handlers, and
`scripts/check-web.sh` gates the web target (wasm compile of both examples +
`node --test` of the semantic DOM overlay against a dependency-free stub).

Known limitation: wgpu-native and AccessKit are prebuilt release libraries,
so ASan/TSan instrument the Odin side only.

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
