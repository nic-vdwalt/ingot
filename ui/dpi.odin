// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

// Cross-platform DPI policy for crisp text on every display.
//
// Ingot uses two independent knobs:
//   - ui_scale  (scale.odin): multiplies every logical pixel dimension.
//   - font_dpi  (font.odin):  multiplies the atlas rasterization resolution.
//
// The correct pairing differs per platform:
//
//   macOS   — the window server reports logical points and composites HiDPI
//             itself. Open the window with the .WINDOW_HIGHDPI flag so the
//             framebuffer is physical pixels; keep ui_scale at 1.0 (points)
//             and drive font_dpi from GetWindowScaleDPI() so glyphs rasterize
//             at physical resolution (1:1 texel mapping, no blur).
//
//   Windows / Linux — do NOT set .WINDOW_HIGHDPI. Screen coordinates are
//             already physical pixels, so scaling belongs in ui_scale
//             (= GetWindowScaleDPI()) and font_dpi stays 1.0. Setting both
//             would double-scale and blur the atlas.
//
// Recommended init order:
//   rl.SetConfigFlags(...)   // .WINDOW_HIGHDPI only on Darwin
//   rl.InitWindow(...)
//   ui.apply_platform_dpi()
//   ui.init_font()
// and once per frame: ui.dpi_refresh().

// auto_scale returns the automatic UI scale factor for the current platform:
// 1.0 on macOS (the compositor handles HiDPI) or the OS DPI factor on
// Windows/Linux.
auto_scale :: proc() -> f32 {
	when ODIN_OS == .Darwin {
		return 1.0
	} else {
		s := rl.GetWindowScaleDPI().x
		return s if s > 0 else 1.0
	}
}

// apply_platform_dpi configures ui_scale and font_dpi for the current platform.
// Call once after rl.InitWindow() and before init_font(). Pass user_scale > 0
// to override the automatic scale (e.g. a persisted user preference); 0 uses
// the platform default.
apply_platform_dpi :: proc(user_scale: f32 = 0) {
	dpi := rl.GetWindowScaleDPI().x
	if dpi <= 0 do dpi = 1.0
	when ODIN_OS == .Darwin {
		set_ui_scale(user_scale if user_scale > 0 else 1.0)
		set_font_dpi(dpi)
	} else {
		set_ui_scale(user_scale if user_scale > 0 else dpi)
		set_font_dpi(1.0)
	}
}

// Last DPI factor observed by dpi_refresh; used to detect monitor-move changes.
@(private)
dpi_last: f32 = 0

// dpi_refresh re-applies the platform DPI policy when the window's scale factor
// changes (e.g. the window moved between a retina and a non-retina display).
// Call once per frame. Returns true when a change was applied so callers can
// re-layout / re-measure. Pass the same user_scale as apply_platform_dpi.
dpi_refresh :: proc(user_scale: f32 = 0) -> bool {
	dpi := rl.GetWindowScaleDPI().x
	if dpi <= 0 do return false
	if dpi_last == 0 {
		dpi_last = dpi
		return false
	}
	if dpi == dpi_last do return false
	dpi_last = dpi

	when ODIN_OS == .Darwin {
		// ui_scale stays at its point value; only the atlas resolution tracks
		// the physical-pixel ratio.
		set_font_dpi(dpi)
		reset_font_atlases()
	} else {
		// Scale lives in ui_scale; changing it resizes fonts and layout, so
		// atlases and scale-dependent caches must be dropped.
		if user_scale <= 0 {
			set_ui_scale(dpi)
		}
		reset_font_atlases()
		invalidate_scale_caches()
	}
	return true
}
