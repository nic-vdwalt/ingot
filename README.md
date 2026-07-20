# ingot

The **raylib + raygui of WebGPU**, in pure Odin. `ingot:gfx` is a self-contained
immediate-mode graphics core (window, input, 2D batched rendering, textures,
font/text) built on Odin's bundled `vendor:wgpu` — no raylib, no OpenGL. Its
public API deliberately mirrors raylib's shapes (`Color`, `Vector2`,
`Rectangle`, `KeyboardKey`, `Font`, `Texture2D`, `Draw*`, `IsKey*`, …) so
existing Odin apps migrate mechanically: swap `import rl "vendor:raylib"` for
`import rl "ingot:gfx"` and the `rl.*` call sites keep resolving. `ingot:ui` is
the immediate-mode widget layer (raygui's role) that runs on top.

Internal shared library for ww-concord, cc-predev-scout, and openalloy/alloy.

All UI code is immediate-mode: callers own every piece of state and pass it in
each frame. `ingot:ui` imports only `core:*` and `ingot:gfx`; `ingot:prefs` is
`core:*`-only. The terminal stack (`ingot:term` / `ingot:libvterm` / `ingot:pty`)
ships its own prebuilt native libs so consumers still need zero linker flags.

WebGPU means one renderer targets native (macOS/Metal, Windows/D3D12,
Linux/Vulkan) **and** the browser (WASM + WebGPU) — see "Web / WASM" below.

## Packages

### `ingot:gfx`

The graphics + windowing core ("raylib of WebGPU"). Over `vendor:wgpu` +
`vendor:glfw` (native) it provides raylib-named:

| Area | Contents |
|------|----------|
| window/context | `InitWindow`/`CloseWindow`/`BeginDrawing`/`EndDrawing`/`ClearBackground`, DPI (`GetWindowScaleDPI`), frame pacing (`SetTargetFPS`), `GetWindowHandle` |
| 2D shapes | `DrawRectangle*`/`Rounded*`/`Lines*`, `DrawLine*`, `DrawCircle*`, `DrawRing`, `DrawTriangle`, gradients, `BeginScissorMode`, `CheckCollisionPointRec` |
| text | glyph-atlas stack (`LoadFontFromMemory`/`DrawTextEx`/`MeasureTextEx`/`DrawTextCodepoint`/`SetTextureFilter`) via `vendor:stb/truetype` into an R8 wgpu atlas |
| textures | `LoadImageFromMemory`/`LoadTextureFromImage`/`UpdateTexture`/`UnloadTexture`/`DrawTexture*`/`DrawTexturePro`, `SetWindowIcon` |
| input | keyboard/mouse/wheel/clipboard/cursor queries with raylib edge/repeat semantics |
| math | `Vector2*` helpers, `Camera2D`/`Camera3D`, CPU-projected `DrawLine3D`/`GetWorldToScreen` |

`ingot:gfx/rlgl` is a thin shim for the low-level `rl*` calls apps use
(`DrawRenderBatchActive` → batch flush; cull/vertex-array/framebuffer calls are
no-ops on the 2D batch). See "Status notes" for the deferred 3D/shader surface.

### `ingot:ui`

Immediate-mode widget toolkit (raygui's role), now running on `ingot:gfx`.

| Module               | Contents |
|----------------------|----------|
| `theme.odin`         | palette + layout constants (mutable globals, DPI-scaled) |
| `scale.odin`         | `set_ui_scale` / `sc` / `scf` HiDPI scaling |
| `dpi.odin`           | cross-platform DPI policy (`apply_platform_dpi` / `dpi_refresh`) |
| `font.odin`          | embedded JetBrains Mono Nerd Font, per-size atlas cache, `draw_text` / `measure_text` with LRU memo |
| `widgets.odin`       | buttons, `text_input` (full caret/selection/clipboard), panels, cards, scrollbars, pills, `Pane` scroll panes, `back_btn`, `collapsible_header` |
| `wrap.odin`          | pixel-accurate word wrap with LRU cache |
| `markdown.odin`      | inline **bold** / `code` / link spans, tables, headings |
| `cursor.odin`        | deferred, focus-gated OS cursor management |
| `pace.odin`          | adaptive frame pacing (`Frame_Pacer`: full rate on activity, idle FPS when quiet) |
| `settings_scale.odin`| generic UI-scale settings modal (caller-owned state) |
| `header.odin`        | one-call app header strip (`draw_app_header`) + window chrome glue |
| `caption_buttons.odin` | Win11-style min/max/close caption glyphs for the custom title bar |
| `window_style_*.odin`| per-OS window backdrop (`apply_window_style`: macOS vibrancy / Windows Mica) |
| `titlebar_*.odin`    | Windows frameless custom title bar (native frame hidden, own hit-testing) |

### `ingot:prefs`

Per-app settings-file persistence. `data_dir(app)` resolves to
`~/.local/share/<app>` on unix and `%APPDATA%\<app>` on Windows;
`read` / `write` move bytes, callers own the file format.

### `ingot:term`

Terminal emulator core: `Term_Instance` (libvterm + PTY), `term_pump`
(per-frame PTY drain, UTF-8 safe), `term_handle_input` (raylib keys → VT byte
sequences). Rendering is app-side — the package exposes the screen-cell grid,
the app draws it.

### `ingot:libvterm`

Odin bindings for libvterm 0.3.3. Prebuilt static libs are committed for
darwin_arm64 / darwin_amd64 / windows_amd64 and referenced with relative
foreign imports, so consumers need no linker flags. Linux links a system
libvterm. Rebuild from the vendored C source (`vendor/libvterm/`) with
`scripts/build-libvterm.sh` (macOS) or `scripts/build-libvterm.bat` (Windows).

### `ingot:pty`

Cross-platform PTY: `forkpty` on unix, ConPTY on Windows.

## Setup

Add as a submodule and register a collection:

    git submodule add <url> libs/ingot
    odin build src -collection:ingot=libs/ingot

    import rl    "ingot:gfx"    // the raylib-shaped graphics core
    import ui    "ingot:ui"
    import prefs "ingot:prefs"
    import term  "ingot:term"

Migrating an existing raylib app is mechanical: replace
`import rl "vendor:raylib"` with `import rl "ingot:gfx"` (and
`import rlgl "vendor:raylib/rlgl"` with `import rlgl "ingot:gfx/rlgl"`). The
`rl.*` call sites keep resolving because `ingot:gfx` mirrors raylib's type and
proc names. `vendor:wgpu`, `vendor:glfw`, and `vendor:stb` ship with Odin — no
external libraries to vendor. The wgpu-native prebuilt lib must be present under
`<odin>/vendor/wgpu/lib/` (Odin's build error links the download if missing).

## Quick start

### Window, DPI, font

    when ODIN_OS == .Darwin {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI})
    } else {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    }
    rl.InitWindow(w, h, title)   // rl == ingot:gfx
    ui.apply_platform_dpi()   // user_scale > 0 to override the OS default
    ui.init_font()

    for !rl.WindowShouldClose() {
        ui.dpi_refresh()      // re-rasterizes on monitor-move scale changes
        // ... draw ...
    }

### Window chrome (backdrop + custom title bar)

Ports openalloy/alloy's window styling: a macOS vibrancy ("glass") backdrop, a
Windows 11 Mica + dark title bar, and a **frameless custom title bar on
Windows** where a top header strip hosts drawn min/max/close caption buttons and
doubles as the drag region. macOS/Linux keep their native title bar.

    // macOS needs a transparent framebuffer so the vibrancy backdrop shows
    // through — add .WINDOW_TRANSPARENT to the config flags on Darwin.
    when ODIN_OS == .Darwin {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI, .WINDOW_TRANSPARENT})
    } else {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    }
    rl.InitWindow(w, h, title)

    ui.apply_window_style()   // macOS: vibrancy / Windows: Mica + dark titlebar
    ui.titlebar_init()        // Windows: strip native frame + install subclass

    for !rl.WindowShouldClose() {
        header_h := ui.TAB_BAR_HEIGHT   // inset your content below the header
        // ... draw map / panels starting at y = header_h ...

        ui.draw_app_header(title, screen_w)  // drawn last; on top of content

        busy := app_activity
        busy = busy || ui.titlebar_consume_activity()  // wake on caption hover
        ui.pacer_frame(&pacer, busy)
    }

`draw_app_header(title, screen_w) -> header_h` draws the `BG_SECONDARY` strip of
height `TAB_BAR_HEIGHT`, the title, a hairline border, and (Windows) the caption
buttons, then publishes the non-client layout so the whole strip drags the
window. `CAPTION_BTN_W` sizes each caption button. Both constants are DPI-scaled
by `set_ui_scale`.

The other procedures are platform-shimmed no-ops off Windows: `titlebar_init`,
`titlebar_enabled`, `titlebar_state`, `titlebar_set_layout`,
`titlebar_consume_activity`. The Win32 subclass uses a fixed id
`TITLEBAR_SUBCLASS_ID :: 2` — if a consumer installs its own subclass, avoid
that id. Dependencies stay within the Odin stdlib (`core:sys/darwin`,
`core:sys/windows`, `base:intrinsics`) — no external linker flags.

### Frame pacing

`Frame_Pacer` matches the monitor refresh rate while there is input, animation,
or app-declared work, then drops to an idle FPS after a grace period. It only
uses non-consuming input queries, so it never steals events from the app.

    pacer := ui.pacer_init(60, 15, 2.5)   // target fps, idle fps, grace seconds

    for !rl.WindowShouldClose() {
        // ... update + draw ...
        rl.EndDrawing()

        busy := animating || work_in_flight   // app-side activity hints
        ui.pacer_frame(&pacer, busy)
    }

Call `ui.pacer_note_activity(&pacer)` for activity the pacer can't observe
(e.g. data arriving on a background channel).

### Scroll panes

    @(private = "file") my_pane: ui.Pane

    // on view reset:
    ui.pane_reset(&my_pane)

    // each frame:
    y := ui.pane_begin(&my_pane, x, top, w, view_h)   // scissor on; y is scrolled origin
    // ... draw content downward from y ...
    ui.pane_end(&my_pane, x, top, w, view_h, y)       // measures content, draws scrollbar

### Back button and collapsible header

    bw := ui.back_btn_w("runs")
    if ui.back_btn(x, y, "runs") { go_back() }

    open := !state.minimized
    ui.collapsible_header(x, y, w, "Legend", &open)
    state.minimized = !open

### UI-scale settings modal + persistence

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

### Terminal

    import term "ingot:term"

    ts, ok := term.term_start(cols, rows, "/bin/zsh")

    // each frame:
    term.term_pump(&ts)                       // drain PTY, feed libvterm
    term.term_handle_input(&ts)               // raylib input → VT bytes
    // optional: skip chords the app owns
    term.term_handle_input(&ts, {.W, .T})     // skip Ctrl+Shift+W / +T

    // draw ts's cell grid with ingot:ui text calls (rendering is app-side)

`term_start` takes optional `default_fg` / `default_bg` RGB params so the
palette matches the host app's theme.

## Web / WASM (browser WebGPU)

Because the renderer is built on `vendor:wgpu`, the same GPU code path targets
the browser via WASM + WebGPU (`ODIN_OS == .JS`, canvas surface via
`SurfaceSourceCanvasHTMLSelector`). The **whole engine** — `gfx` batch renderer,
`ui` widgets, and the stb_truetype text atlas — now runs on the web target, not
just a rendering spike. Build and serve the demo:

    bash build_web.sh                       # -> web/ingot_web.wasm (+ odin.js, wgpu.js)
    (cd web && python3 -m http.server 8000) # open http://localhost:8000

`web/demo.odin` drives the real engine (`InitWindow` → `run(frame)`, a baked font
via `DrawTextEx`, mouse + keyboard input) — the *same source* that runs natively.
Requires a WebGPU browser (Chrome/Edge 113+, Safari 18+) and Odin's
`--export-table` linker flag (set by the script).

### The platform seam (`when ODIN_OS == .JS`)

All OS-specific plumbing lives behind a small platform seam so `gfx` carries no
windowing-backend import. Every `platform_*` proc has two implementations,
selected by build tag:

| Concern | Native (`platform_native.odin`, `#+build !js`) | Web (`platform_web.odin`, `#+build js`) |
|---------|------------------------------------------------|------------------------------------------|
| Window + surface | GLFW window → `glfwglue.GetSurface` | canvas → `SurfaceSourceCanvasHTMLSelector` |
| GPU init | synchronous busy-wait (`InstanceProcessEvents`) | async adapter→device callback → `_gpu_finish` |
| Frame loop | `run()` blocks in `for !WindowShouldClose()` | `run()` stores the callback; RAF drives exported `step(dt)` |
| Input | GLFW key/char/scroll callbacks | DOM events (`ingot_web.js`/`ingot_input.js`) → staging buffer → same `Input` struct |
| Timing | `core:time` (monotonic) | `performance.now` |
| DPI / resize | GLFW content scale + framebuffer size | canvas CSS size × `devicePixelRatio` |

Consumer apps write `main()` once — `InitWindow` … `gfx.run(frame)` — and it
compiles to both native and web. The native GLFW path is unchanged; the web path
is purely additive (`#+build js` siblings). The browser host glue (`web/ingot_web.js`
+ `web/ingot_input.js`) provides the `ingot` foreign-import module (timing, canvas
geometry, cursor) and forwards DOM input into the engine's exported entry points.

## DPI & text readability

Text stays crisp on every platform via per-size glyph atlases rasterized at
native size × DPI (no downscaling blur), integer-pixel layout, and a
platform-correct pairing of the two scaling knobs. Wire it identically in every
consumer (see Quick start above).

Policy (matches openalloy/alloy):

| Platform      | .WINDOW_HIGHDPI | ui_scale              | font_dpi              |
|---------------|-----------------|-----------------------|-----------------------|
| macOS         | yes             | 1.0 (points)          | GetWindowScaleDPI().x |
| Windows/Linux | no              | GetWindowScaleDPI().x | 1.0                   |

macOS composites HiDPI itself, so scaling lives in the atlas (font_dpi) at
physical resolution. On Windows/Linux screen coordinates are already physical
pixels, so scaling lives in ui_scale and the atlas must stay at 1.0 — setting
both would double-scale and blur.

## Status notes

ingot is now the **WebGPU** graphics + UI + terminal engine (no raylib, no
OpenGL). `ingot:gfx` replaces `vendor:raylib` as the graphics core; `ingot:ui`,
`ingot:term`, and all three consumer apps (ww-concord, cc-predev-scout,
openalloy/alloy) build and run against it on native (macOS/Metal verified).

Migration status per consumer:

- **ww-concord** — fully migrated (2D UI + terminal + screen-share textures +
  voice). Builds and runs on WebGPU.
- **cc-predev-scout** — fully migrated (map tiles, 2D massing via `DrawTriangle`,
  gradients, textures). Builds and runs on WebGPU.
- **openalloy/alloy** — fully migrated. Core (chat + terminal + 2D UI) runs on
  WebGPU. The **embedded nvim / Ctrl+E editor** — which caches its grid into a
  `RenderTexture` and blits it — renders again now that render targets are real
  (was blank while `BeginTextureMode` discarded offscreen draws). The **galaxy
  view** is no longer no-op'd: `ingot:gfx` now implements the 3D/shader/render-
  target/rlgl surface it needs — per-pipeline blend modes (additive/custom),
  real offscreen render targets, WGSL custom-shader objects with uniform
  reflection, format-aware batch pipelines (for the HDR `RGBA16Float` targets),
  a CPU-projected 3D layer (`BeginMode3D`/`DrawBillboard`/`DrawMesh`/`DrawLine3D`),
  the rlgl matrix stack + framebuffer helpers, and **real GPU instancing**
  (`LoadVertexArray`/`SetVertexAttribute(+Divisor)`/`DrawVertexArrayInstanced`)
  that backs the 2D bubble/node/star fields and 3D starfield. All 21 galaxy
  shaders are ported GLSL→WGSL.

### Engine capabilities added (WebGPU)

| Area | Status |
|------|--------|
| Per-pipeline blend modes (`BeginBlendMode` ALPHA/ADDITIVE/MULTIPLIED/CUSTOM, `rlgl.SetBlendFactors`) | implemented — inputs premultiplied, additive = One/One |
| Render targets (`LoadRenderTexture`/`BeginTextureMode`/`EndTextureMode`) | implemented — own command encoder, y-flipped to match raylib; fixes the nvim editor |
| Custom shaders (`LoadShaderFromMemory`/`GetShaderLocation`/`SetShaderValue*`/`BeginShaderMode`) | implemented — WGSL modules, `struct U` uniform reflection, per-target-format pipelines, extra-texture bindings |
| rlgl framebuffers (`LoadFramebuffer`/`LoadTexture`/`LoadTextureDepth`/…) | implemented — back the galaxy HDR (`RGBA16Float`) + depth targets |
| rlgl instancing (VAO/VBO + `DrawVertexArrayInstanced`) | implemented — generic per-vertex + per-instance attribute layouts → real instanced draws |
| rlgl matrix stack (`PushMatrix`/`Translatef`/`PopMatrix`) + depth mask + `GetMatrixProjection` | implemented — 2D model-translate (galaxy pane origin) |
| 3D (`BeginMode3D`/`DrawMesh`/`DrawBillboard(Pro)`/`DrawLine3D`) | CPU-projected over the 2D batch (camera-facing quads / shaded discs) |

### Remaining / needs on-device tuning

- The galaxy render is now **functional but visually unvalidated** on-device:
  the whole pipeline compiles, links, and runs without GPU validation errors,
  but exact HDR bloom/tonemap tuning, the render-target Y-flip across the
  multi-pass bloom chain, the CPU-projected 3D approximation (billboards/discs
  vs. true lit instanced spheres), and **indexed** instancing for the 3D node
  spheres (`DrawVertexArrayElementsInstanced`, currently a no-op — the 3D node
  bodies use the CPU disc path) still need visual verification/iteration on a
  Metal/D3D12/Vulkan display. A true GPU 3D mesh pipeline (real depth-tested
  instanced spheres) is the natural follow-up to replace the CPU approximation.
- macOS `WINDOW_TRANSPARENT` vibrancy uses the surface's supported alpha mode
  (`Unpremultiplied`) while the batch outputs premultiplied alpha; fully-opaque
  UI composites correctly, semi-transparent backdrop blending is approximate.
- full `ingot:ui` on the browser/WASM target (see "Web / WASM").

Previously upstreamed app features (all live in ingot):

- composer **undo/redo + mention pills** (`input_undo.odin`, `mention_pills.odin`)
- **markdown file pills** + workspace-path registry (`markdown.odin` +
  `ui.workspace_has_path` / `ui.set_md_file_ctx`)
- the **spellcheck** subsystem (`spell*.odin`, `spellcheck.odin`, per-OS backends)
- split-view + path-truncation widgets (`draw_split_divider`,
  `draw_split_drop_hint`, `truncate_to_width_left`, `truncate_path_middle`)
- the full app **metric / colour set** incl. macOS `GLASS_ENABLED` vibrancy
  (`theme.odin`, `scale.odin`), with app-specific view metrics rescaled via the
  `scale_metrics_hook` / `scale_invalidate_hook` callbacks (no app import)
- the wider Nerd Font glyph coverage folded into ingot's DPI-atlas font system
