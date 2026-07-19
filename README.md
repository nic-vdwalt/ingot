# ingot

Immediate-mode raylib UI toolkit for Odin. Internal shared library for
ww-concord, cc-predev-scout, and (planned) openalloy/alloy.

All UI code is immediate-mode: callers own every piece of state and pass it in
each frame. `ingot:ui` imports only `core:*` and `vendor:raylib`; `ingot:prefs`
is `core:*`-only. The terminal stack (`ingot:term` / `ingot:libvterm` /
`ingot:pty`) is the sanctioned exception — it ships its own prebuilt native
libs so consumers still need zero linker flags.

## Packages

### `ingot:ui`

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

    import ui    "ingot:ui"
    import prefs "ingot:prefs"
    import term  "ingot:term"

## Quick start

### Window, DPI, font

    when ODIN_OS == .Darwin {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI})
    } else {
        rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    }
    rl.InitWindow(w, h, title)
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

ingot is now the single source of truth for the shared ui + terminal engine.
All of openalloy/alloy's ahead-of-ingot features have been upstreamed here and
decoupled from any app package:

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

openalloy is wired to consume ingot (submodule `alloy/libs/ingot`,
`-collection:ingot` in `alloy/build.sh` — see `openalloy/.gitmodules`). The
final source swap in `alloy/src` (bare `import "ui"` / `"terminal"` →
`import "ingot:ui"` / `"ingot:term"`, deleting alloy's duplicate copies) is the
remaining migration step: it requires per-symbol `ui.` qualification across
alloy's ~38 app-view files because Odin has no file-scope `using` on packages.
Do it incrementally, compiling after each file. `ingot:term` was extracted from
alloy originally; the two are now feature-equivalent.
