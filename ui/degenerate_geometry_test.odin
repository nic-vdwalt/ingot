#+build !js
package ui

// Degenerate-geometry matrix.
//
// Every widget here is exercised with rects that are zero or negative in each
// dimension, with empty and nil collections, and with hostile label strings.
// None of these inputs is a programmer error: layout arithmetic legitimately
// produces a zero or negative width when a window is narrowed, a panel is
// collapsed, or a sidebar takes more room than the window has left, and a
// caller-supplied item list is legitimately empty before its data has loaded.
//
// Tiger Style says assertions catch *programmer* errors. Layout-derived
// geometry and caller-collection emptiness are operating inputs, so a widget
// handed one must draw nothing and return its zero result. Trapping instead is
// what produced six identical EXC_BREAKPOINT reports in the field, all of them
// unattributable because the assertion message never reached disk.
//
// Every widget below must survive this table. `frame.degenerate_drops` is the
// safety net: production degrades silently, and the golden-path tests assert
// the counter stays zero so a real layout bug is still caught.

import "core:strings"
import "core:testing"

// Widths and heights spanning far-negative, just-negative, zero, and the
// smallest positive value. The 1px column matters: it is the boundary where
// clamping bugs turn into off-by-one rendering rather than a trap.
@(private = "file")
DEGENERATE_EXTENTS :: [?]i32{-100, -1, 0, 1}

// Labels that have historically broken text measurement and atlas paths.
@(private = "file")
degenerate_labels :: proc() -> []string {
	// Static storage: a compound slice literal would point into this frame.
	@(static) big: [4096]u8
	@(static) labels: [6]string
	for i in 0 ..< len(big) do big[i] = 'x'
	labels[0] = "" // empty: no glyphs to measure
	labels[1] = "ok" // plain ASCII
	labels[2] = "\u00e9\u00fc\u00f1" // multi-byte UTF-8
	labels[3] = "\U0001F600\U0001F680" // astral-plane emoji
	labels[4] = string(big[:]) // 4 KiB: atlas and wrap pressure
	labels[5] = "\xff\xfe bad" // invalid UTF-8: decoders must not walk off the end
	return labels[:]
}

// with_frame runs `body` inside a fully-initialised frame and reports the
// frame's degenerate-drop count and final clip depth.
@(private = "file")
with_frame :: proc(
	t: ^testing.T,
	body: proc(t: ^testing.T, frame: ^Ui_Frame),
) -> (
	drops: int,
	clip_depth: int,
) {
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)

	// A real output buffer, so the tests can assert that a dropped widget
	// emitted no paint commands and left no clip on the stack.
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	frame.output = output
	ui_frame_begin(frame, runtime)
	body(t, frame)
	drops = frame.degenerate_drops
	clip_depth = frame.output.main.clip_count
	ui_frame_end(frame)
	return
}

@(test)
checkbox_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				checked := false
				changed := checkbox_at(frame, Rect_I32{0, 0, w, h}, "label", &checked)
				testing.expect(t, !changed, "degenerate checkbox must not report a change")
				testing.expect(t, !checked, "degenerate checkbox must not mutate state")
			}
		}
	})
	testing.expect(t, drops > 0, "degenerate rects must be counted, not silently ignored")
	testing.expect_value(t, clip_depth, 0)
}

@(test)
radio_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				selected: i32 = 3
				changed := radio_at(frame, Rect_I32{0, 0, w, h}, "label", &selected, 1)
				testing.expect(t, !changed, "degenerate radio must not report a change")
				testing.expect_value(t, selected, i32(3))
			}
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
slider_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				st: Slider_State
				value: f32 = 0.5
				changed := slider_at_state(frame, &st, Rect_I32{0, 0, w, h}, &value, 0, 1)
				testing.expect(t, !changed, "degenerate slider must not report a change")
				testing.expect_value(t, value, f32(0.5))
			}
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
slider_survives_inverted_and_empty_ranges :: proc(t: ^testing.T) {
	// A collapsed range (lo == hi) is what a settings row shows before its
	// bounds arrive; an inverted range is a caller bug that must still not take
	// the process down.
	drops, _ := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		st: Slider_State
		value: f32 = 5
		_ = slider_at_state(frame, &st, Rect_I32{0, 0, 100, 20}, &value, 5, 5)
		_ = slider_at_state(frame, &st, Rect_I32{0, 0, 100, 20}, &value, 10, 0)
	})
	testing.expect(t, drops > 0, "collapsed and inverted ranges must be dropped, not trapped")
}

@(test)
dropdown_survives_degenerate_rects_and_empty_items :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(
	t,
	proc(t: ^testing.T, frame: ^Ui_Frame) {
		items_many := []string{"a", "b", "c"}
		items_one := []string{"only"}
		empty: []string
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				st: Dropdown_State
				selected: i32 = 1
				_ = dropdown_at(frame, Rect_I32{0, 0, w, h}, items_many, &selected, &st, 800, 600)
			}
		}
		// A healthy rect with no items at all: the model list has not loaded.
		for items in ([3][]string{nil, empty, items_one}) {
			st: Dropdown_State
			selected: i32 = 0
			_ = dropdown_at(frame, Rect_I32{0, 0, 200, 24}, items, &selected, &st, 800, 600)
		}
	},
	)
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
dropdown_with_no_items_reports_no_selection :: proc(t: ^testing.T) {
	_, _ = with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		empty: []string
		st: Dropdown_State
		selected: i32 = 7
		changed := dropdown_at(frame, Rect_I32{0, 0, 200, 24}, empty, &selected, &st, 800, 600)
		testing.expect(t, !changed, "an empty dropdown cannot report a change")
		testing.expect_value(t, selected, i32(-1))
		testing.expect(t, !st.menu.open, "an empty dropdown must not open a popup")
	})
}

@(test)
text_input_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				box: Input_Box
				defer input_box_destroy(&box)
				_ = input_at(frame, 0, 0, w, h, &box, "placeholder", true)
			}
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
text_input_survives_hostile_labels :: proc(t: ^testing.T) {
	_, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for label in degenerate_labels() {
			box: Input_Box
			defer input_box_destroy(&box)
			strings.write_string(&box.sb, label)
			_ = input_at(frame, 0, 0, 200, 24, &box, label, true)
		}
	})
	testing.expect_value(t, clip_depth, 0)
}

@(test)
pressable_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				config := Pressable_Config {
					rect      = Rect_I32{0, 0, w, h},
					role      = .Button,
					label     = "press me",
					stable_id = "degenerate",
				}
				res := pressable(frame, config)
				testing.expect(t, !res.activated, "a zero-area control cannot be activated")
				testing.expect(t, !res.hovered, "a zero-area control cannot be hovered")
				testing.expect(t, !res.pressed)
				testing.expect(t, !res.held)
			}
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
listbox_survives_degenerate_rects_and_counts :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(
	t,
	proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				st: Listbox_State
				selected := 0
				_ = listbox_begin(
					frame,
					&st,
					Listbox_Config {
						rect = Rect_I32{0, 0, w, h},
						label = "list",
						stable_id = "degenerate",
						count = 3,
						selected = &selected,
					},
				)
				listbox_end(frame, &st)
			}
		}
		// Healthy rect, no rows: the list has loaded and is genuinely empty.
		st: Listbox_State
		selected := 4
		_ = listbox_begin(
			frame,
			&st,
			Listbox_Config {
				rect = Rect_I32{0, 0, 200, 100},
				label = "list",
				stable_id = "empty",
				count = 0,
				selected = &selected,
			},
		)
		listbox_end(frame, &st)
		testing.expect_value(t, selected, -1)
	},
	)
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
focus_ring_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				draw_focus_ring(frame, 0, 0, w, h)
			}
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
focus_ring_survives_transparent_theme :: proc(t: ^testing.T) {
	// A transparent focus ring is a legitimate theme choice, not a programmer
	// error. It must skip the draw, not abort the process.
	_, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		theme := ui_frame_theme(frame)
		theme.focus_ring.a = 0
		ui_runtime_set_theme(frame.runtime, theme^)
		draw_focus_ring(frame, 0, 0, 40, 20)
	})
	testing.expect_value(t, clip_depth, 0)
}

@(test)
focus_opt_click_survives_degenerate_rects :: proc(t: ^testing.T) {
	drops, _ := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			for h in DEGENERATE_EXTENTS {
				if w > 0 && h > 0 do continue
				slot: int
				focus_opt_click(frame, Focus_Opt{&slot, 1}, 0, 0, w, h)
				testing.expect_value(t, slot, 0)
			}
		}
	})
	testing.expect(t, drops > 0)
}

@(test)
app_header_survives_degenerate_widths :: proc(t: ^testing.T) {
	// A zero-width frame happens during a resize and when a macOS Space
	// switches; it must not be fatal.
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		for w in DEGENERATE_EXTENTS {
			if w > 0 do continue
			_ = draw_app_header(frame, "title", w)
		}
	})
	testing.expect(t, drops > 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
golden_path_records_no_degenerate_drops :: proc(t: ^testing.T) {
	// The counter must stay zero on healthy geometry, otherwise it is useless
	// as a signal and a genuine layout bug hides behind it.
	drops, clip_depth := with_frame(t, proc(t: ^testing.T, frame: ^Ui_Frame) {
		checked := false
		_ = checkbox_at(frame, Rect_I32{0, 0, 120, 20}, "label", &checked)
		selected: i32 = 0
		_ = radio_at(frame, Rect_I32{0, 24, 120, 20}, "label", &selected, 0)
		st: Slider_State
		value: f32 = 0.5
		_ = slider_at_state(frame, &st, Rect_I32{0, 48, 120, 20}, &value, 0, 1)
		_ = pressable(
			frame,
			Pressable_Config {
				rect = Rect_I32{0, 72, 120, 20},
				role = .Button,
				label = "ok",
				stable_id = "golden",
			},
		)
		draw_focus_ring(frame, 0, 96, 120, 20)
		_ = draw_app_header(frame, "title", 1024)
	})
	testing.expect_value(t, drops, 0)
	testing.expect_value(t, clip_depth, 0)
}

@(test)
degenerate_widgets_emit_no_paint :: proc(t: ^testing.T) {
	// Dropping must mean "draw nothing". A widget that returns early *after*
	// emitting geometry would leave a stray rectangle at the origin.
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	frame.output = output
	ui_frame_begin(frame, runtime)
	before := frame.output.main.count
	checked := false
	_ = checkbox_at(frame, Rect_I32{0, 0, 0, 0}, "label", &checked)
	_ = pressable(
		frame,
		Pressable_Config {
			rect = Rect_I32{0, 0, -5, 10},
			role = .Button,
			label = "x",
			stable_id = "y",
		},
	)
	draw_focus_ring(frame, 0, 0, 0, 20)
	testing.expect_value(t, frame.output.main.count, before)
	ui_frame_end(frame)
}
