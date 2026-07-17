# ingot

Immediate-mode raylib UI toolkit for Odin. Internal shared library for
ww-concord, cc-predev-scout, and (planned) openalloy/alloy.

Modules (package `ui`):
- theme.odin    — palette + layout constants (mutable globals, DPI-scaled)
- scale.odin    — set_ui_scale / sc / scf HiDPI scaling
- dpi.odin      — cross-platform DPI policy (apply_platform_dpi / dpi_refresh)
- font.odin     — embedded JetBrains Mono Nerd Font, per-size atlas cache,
                  draw_text / measure_text with LRU memo
- widgets.odin  — buttons, text_input (full caret/selection/clipboard),
                  panels, cards, scrollbars, pills
- wrap.odin     — pixel-accurate word wrap with LRU cache
- markdown.odin — inline **bold** / `code` / link spans, tables, headings
- cursor.odin   — deferred, focus-gated OS cursor management

## Usage

Add as a submodule and register a collection:

    git submodule add <url> libs/ingot
    odin build src -collection:ingot=libs/ingot

    import ui "ingot:ui"

Requires only `core:*` and `vendor:raylib`.

## DPI & text readability

Text stays crisp on every platform via per-size glyph atlases rasterized at
native size × DPI (no downscaling blur), integer-pixel layout, and a
platform-correct pairing of the two scaling knobs. Wire it identically in every
consumer:

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

Policy (matches openalloy/alloy):

| Platform      | .WINDOW_HIGHDPI | ui_scale              | font_dpi              |
|---------------|-----------------|-----------------------|-----------------------|
| macOS         | yes             | 1.0 (points)          | GetWindowScaleDPI().x |
| Windows/Linux | no              | GetWindowScaleDPI().x | 1.0                   |

macOS composites HiDPI itself, so scaling lives in the atlas (font_dpi) at
physical resolution. On Windows/Linux screen coordinates are already physical
pixels, so scaling lives in ui_scale and the atlas must stay at 1.0 — setting
both would double-scale and blur.
