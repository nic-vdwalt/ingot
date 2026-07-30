#+build !js
package gfx

// Contract of _input_publish_staged, the single place published key edges are
// written. The web backend drains browser events into the same staging arrays
// earlier in the same input_poll (platform_web.odin _input_drain); an
// assignment here silently erased them, which killed every edge-driven key on
// the browser target (Enter, Backspace, Delete, Tab, arrows) while typed
// characters - carried by the char ring, not the edge arrays - kept working.

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
input_publish_staged_preserves_earlier_edges :: proc(t: ^testing.T) {
	inp := new(Input)
	defer free(inp)
	enter := int(KeyboardKey.ENTER)
	back := int(KeyboardKey.BACKSPACE)
	// Simulates the web drain, which publishes before this proc runs.
	inp.pressed[enter] = true
	inp.repeat[back] = true
	inp.released[enter] = true

	_input_publish_staged(inp)

	testing.expect(t, inp.pressed[enter], "an edge published earlier must survive")
	testing.expect(t, inp.repeat[back], "an edge published earlier must survive")
	testing.expect(t, inp.released[enter], "an edge published earlier must survive")
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
