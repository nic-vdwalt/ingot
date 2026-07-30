#+build !js
package gfx

// Contract of the input staging seam: _stage_key / _stage_char enqueue, and
// _input_publish_staged is the single writer of the published snapshot.
//
// Both backends share one staging buffer. The web backend used to keep a
// second, identically named copy in platform_web.odin and publish it directly
// from platform_poll_events; _input_publish_staged then assigned over the
// result later in the same input_poll and erased it. Every edge-driven key on
// the browser target died (Enter, Backspace, Delete, Tab, arrows) while typed
// characters kept working, because those ride the char ring rather than the
// edge arrays - which is exactly why it read as flaky rather than broken.
//
// These tests pin the publish contract and the ring bounds, including the
// negative space: a full ring must drop rather than overwrite, and an empty
// staging buffer must not invent edges.

import "core:testing"

@(test)
input_publish_staged_moves_edges_and_clears_staging :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	enter := int(KeyboardKey.ENTER)
	back := int(KeyboardKey.BACKSPACE)
	inp.st_pressed[enter] = true
	inp.st_repeat[back] = true
	inp.st_released[back] = true

	_input_publish_staged(inp)

	testing.expect(t, inp.pressed[enter], "staged press must publish")
	testing.expect(t, inp.repeat[back], "staged repeat must publish")
	testing.expect(t, inp.released[back], "staged release must publish")
	testing.expect(t, !inp.st_pressed[enter], "staging must be consumed")
	testing.expect(t, !inp.st_repeat[back], "staging must be consumed")
	testing.expect(t, !inp.st_released[back], "staging must be consumed")
}

@(test)
input_publish_staged_leaves_untouched_keys_clear :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	_input_publish_staged(inp)
	for index in 0 ..< KEY_COUNT {
		testing.expect(t, !inp.pressed[index], "no key may report a phantom press")
		testing.expect(t, !inp.released[index], "no key may report a phantom release")
		testing.expect(t, !inp.repeat[index], "no key may report a phantom repeat")
	}
}

@(test)
input_stage_key_publishes_in_order :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	order := [?]KeyboardKey{.ENTER, .BACKSPACE, .TAB}
	for key in order do _stage_key(inp, key)

	_input_publish_staged(inp)

	for want in order {
		got := KeyboardKey.KEY_NULL
		if inp.key_h != inp.key_t {
			got = inp.key_q[inp.key_h]
			inp.key_h = (inp.key_h + 1) % CHAR_Q
		}
		testing.expect_value(t, got, want)
	}
	testing.expect_value(t, inp.key_h, inp.key_t)
}

@(test)
input_stage_char_publishes_in_order :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	for value in "ab\n" do _stage_char(inp, value)

	_input_publish_staged(inp)

	for want in "ab\n" {
		got := rune(0)
		if inp.char_h != inp.char_t {
			got = inp.char_q[inp.char_h]
			inp.char_h = (inp.char_h + 1) % CHAR_Q
		}
		testing.expect_value(t, got, want)
	}
	testing.expect_value(t, inp.char_h, inp.char_t)
}

// Negative space: a burst larger than the ring must drop the overflow rather
// than wrap over unread entries, and publication must still drain cleanly.
@(test)
input_stage_rings_drop_overflow_without_wrapping :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	for _ in 0 ..< CHAR_Q * 2 {
		_stage_key(inp, .A)
		_stage_char(inp, 'a')
	}
	testing.expect_value(t, inp.st_key_t, CHAR_Q - 1)
	testing.expect_value(t, inp.st_char_t, CHAR_Q - 1)

	_input_publish_staged(inp)

	testing.expect_value(t, inp.st_key_h, inp.st_key_t)
	testing.expect_value(t, inp.st_char_h, inp.st_char_t)
}

@(test)
input_publish_staged_accumulates_wheel :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	inp.wheel_pending = {1, 2}
	inp.st_wheel = {3, 4}

	_input_publish_staged(inp)

	testing.expect_value(t, inp.wheel_pending, Vector2{4, 6})
	testing.expect_value(t, inp.st_wheel, Vector2{})
}
