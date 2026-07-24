#+build !js
package gfx

import "core:testing"

// --- audio handle packing ---------------------------------------------------

@(test)
audio_handle_roundtrips_slot_and_generation :: proc(t: ^testing.T) {
	for slot in i32(0) ..< i32(MAX_SOUNDS) {
		h := _audio_handle_pack(slot, 7)
		testing.expect(t, h != 0)
		testing.expect_value(t, _audio_handle_slot(h), slot)
		testing.expect_value(t, _audio_handle_gen(h), u16(7))
	}
}

@(test)
audio_handle_zero_is_invalid :: proc(t: ^testing.T) {
	testing.expect_value(t, _audio_handle_slot(0), i32(-1))
}

@(test)
audio_handle_rejects_out_of_range_slots :: proc(t: ^testing.T) {
	testing.expect_value(t, _audio_handle_pack(-1, 0), u32(0))
	testing.expect_value(t, _audio_handle_pack(MAX_SOUNDS, 0), u32(0))
	// A low word beyond the pool must decode as invalid.
	testing.expect_value(t, _audio_handle_slot(u32(MAX_SOUNDS + 1)), i32(-1))
}

@(test)
audio_handle_generation_changes_handle :: proc(t: ^testing.T) {
	a := _audio_handle_pack(3, 1)
	b := _audio_handle_pack(3, 2)
	testing.expect(t, a != b)
	testing.expect_value(t, _audio_handle_slot(a), _audio_handle_slot(b))
}

// --- gamepad remap tables ---------------------------------------------------

@(test)
glfw_pad_remap_covers_all_buttons_once :: proc(t: ^testing.T) {
	seen: [GAMEPAD_BUTTON_COUNT]int
	for mapped in _GLFW_PAD_REMAP {
		seen[int(mapped)] += 1
	}
	// GLFW has 15 digital buttons; every target must be hit exactly once and
	// the analog-only trigger buttons (plus UNKNOWN) not at all.
	testing.expect_value(t, seen[int(GamepadButton.UNKNOWN)], 0)
	testing.expect_value(t, seen[int(GamepadButton.LEFT_TRIGGER_2)], 0)
	testing.expect_value(t, seen[int(GamepadButton.RIGHT_TRIGGER_2)], 0)
	for b in 1 ..< GAMEPAD_BUTTON_COUNT {
		if b == int(GamepadButton.LEFT_TRIGGER_2) do continue
		if b == int(GamepadButton.RIGHT_TRIGGER_2) do continue
		testing.expect_value(t, seen[b], 1)
	}
}

@(test)
w3c_pad_remap_covers_all_buttons_once :: proc(t: ^testing.T) {
	seen: [GAMEPAD_BUTTON_COUNT]int
	for mapped in _W3C_PAD_REMAP {
		seen[int(mapped)] += 1
	}
	// W3C standard mapping has 17 buttons — all raylib buttons except UNKNOWN
	// are hit exactly once (triggers are digital buttons 6/7 on the web).
	testing.expect_value(t, seen[int(GamepadButton.UNKNOWN)], 0)
	for b in 1 ..< GAMEPAD_BUTTON_COUNT {
		testing.expect_value(t, seen[b], 1)
	}
}

@(test)
glfw_pad_remap_spot_checks :: proc(t: ^testing.T) {
	// GLFW SDL-mapping order: A, B, X, Y, LB, RB, back, start, guide, L3,
	// R3, dpad U/R/D/L.
	testing.expect_value(t, _GLFW_PAD_REMAP[0], GamepadButton.RIGHT_FACE_DOWN)
	testing.expect_value(t, _GLFW_PAD_REMAP[3], GamepadButton.RIGHT_FACE_UP)
	testing.expect_value(t, _GLFW_PAD_REMAP[6], GamepadButton.MIDDLE_LEFT)
	testing.expect_value(t, _GLFW_PAD_REMAP[8], GamepadButton.MIDDLE)
	testing.expect_value(t, _GLFW_PAD_REMAP[11], GamepadButton.LEFT_FACE_UP)
	testing.expect_value(t, _GLFW_PAD_REMAP[14], GamepadButton.LEFT_FACE_LEFT)
}

@(test)
w3c_pad_remap_spot_checks :: proc(t: ^testing.T) {
	// W3C order: A, B, X, Y, LB, RB, LT, RT, back, start, L3, R3,
	// dpad U/D/L/R, guide.
	testing.expect_value(t, _W3C_PAD_REMAP[0], GamepadButton.RIGHT_FACE_DOWN)
	testing.expect_value(t, _W3C_PAD_REMAP[6], GamepadButton.LEFT_TRIGGER_2)
	testing.expect_value(t, _W3C_PAD_REMAP[7], GamepadButton.RIGHT_TRIGGER_2)
	testing.expect_value(t, _W3C_PAD_REMAP[12], GamepadButton.LEFT_FACE_UP)
	testing.expect_value(t, _W3C_PAD_REMAP[15], GamepadButton.LEFT_FACE_RIGHT)
	testing.expect_value(t, _W3C_PAD_REMAP[16], GamepadButton.MIDDLE)
}

// --- gamepad query bounds ---------------------------------------------------

@(test)
gamepad_queries_reject_out_of_range :: proc(t: ^testing.T) {
	testing.expect(t, !IsGamepadAvailable(-1))
	testing.expect(t, !IsGamepadAvailable(MAX_GAMEPADS))
	testing.expect(t, !IsGamepadButtonDown(-1, .RIGHT_FACE_DOWN))
	testing.expect(t, !IsGamepadButtonPressed(MAX_GAMEPADS, .RIGHT_FACE_DOWN))
	testing.expect_value(t, GetGamepadAxisMovement(-1, .LEFT_X), f32(0))
	testing.expect_value(t, GetGamepadAxisMovement(0, GamepadAxis(99)), f32(0))
}

@(test)
gamepad_edge_detection_uses_prev_buttons :: proc(t: ^testing.T) {
	pad := &g.inp.pads[0]
	old := pad^
	defer pad^ = old

	pad.connected = true
	idx := int(GamepadButton.RIGHT_FACE_DOWN)
	pad.buttons[idx] = true
	pad.prev_buttons[idx] = false
	testing.expect(t, IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN))
	testing.expect(t, !IsGamepadButtonReleased(0, .RIGHT_FACE_DOWN))

	pad.buttons[idx] = false
	pad.prev_buttons[idx] = true
	testing.expect(t, !IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN))
	testing.expect(t, IsGamepadButtonReleased(0, .RIGHT_FACE_DOWN))
}

// --- wave normalization -----------------------------------------------------

@(test)
load_sound_from_wave_requires_ready_device :: proc(t: ^testing.T) {
	// Without InitAudioDevice the loader must return the invalid Sound and
	// touch nothing — verifies the "audio off is a safe no-op" contract.
	samples := [4]i16{0, 16384, -16384, 0}
	wave := Wave {
		frameCount = 4,
		sampleRate = 44100,
		sampleSize = 16,
		channels   = 1,
		data       = raw_data(samples[:]),
	}
	old_ready := g_audio.ready
	defer g_audio.ready = old_ready
	g_audio.ready = false
	snd := LoadSoundFromWave(wave)
	testing.expect_value(t, snd._handle, u32(0))
	testing.expect(t, !IsSoundPlaying(snd))
}

@(test)
audio_slot_rejects_stale_generation :: proc(t: ^testing.T) {
	slot := &g_audio.slots[0]
	old_slot := slot^
	defer slot^ = old_slot
	slot.used = true
	slot.gen = 7
	handle := _audio_handle_pack(0, slot.gen)
	testing.expect_value(t, _audio_slot_resolve(handle), i32(0))
	slot.gen += 1
	testing.expect_value(t, _audio_slot_resolve(handle), i32(-1))
	slot.used = false
	testing.expect_value(t, _audio_slot_resolve(_audio_handle_pack(0, slot.gen)), i32(-1))
}
