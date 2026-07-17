# ingot

Immediate-mode raylib UI toolkit for Odin. Internal shared library for
ww-concord, cc-predev-scout, and (planned) openalloy/alloy.

Modules (package `ui`):
- theme.odin    — palette + layout constants (mutable globals, DPI-scaled)
- scale.odin    — set_ui_scale / sc / scf HiDPI scaling
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
