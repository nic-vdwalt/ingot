package fuzz_interact

import "core:testing"
import fuzzx "ingot:fuzz/fuzzx"
import rl "ingot:gfx"

@(test)
interact_frame_codec_preserves_actions_and_boundaries :: proc(t: ^testing.T) {
	frame := Frame_Op {
		count = 2,
		control = {hide_slider = 3, open_modal = true, open_menu = true, menu_x = 71, menu_y = 92},
	}
	frame.actions[0] = {
		kind = .Mouse,
		a    = -4,
		b    = 601,
	}
	frame.actions[1] = {
		kind = .Key,
		a    = i32(rl.KeyboardKey.TAB),
		b    = 1,
	}
	payload := frame_encode(frame, context.allocator)
	defer delete(payload)
	decoded, ok := frame_decode(payload)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.count, frame.count)
	testing.expect_value(t, decoded.actions[0], frame.actions[0])
	testing.expect_value(t, decoded.actions[1], frame.actions[1])
	testing.expect_value(t, decoded.control, frame.control)
}

@(test)
interact_tape_generation_and_replay_are_deterministic :: proc(t: ^testing.T) {
	first := interact_tape_generate(12345, 40)
	defer fuzzx.tape_destroy(&first)
	second := interact_tape_generate(12345, 40)
	defer fuzzx.tape_destroy(&second)
	first_bytes, first_ok := fuzzx.tape_encode(&first)
	defer delete(first_bytes)
	second_bytes, second_ok := fuzzx.tape_encode(&second)
	defer delete(second_bytes)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, len(first_bytes), len(second_bytes))
	for index in 0 ..< len(first_bytes) {
		testing.expect_value(t, first_bytes[index], second_bytes[index])
	}
	testing.expect(t, !interact_tape_execute(&first).failed)
	testing.expect(t, !interact_tape_execute(&first).failed)
}

@(test)
interact_tape_rejects_unknown_and_malformed_frames :: proc(t: ^testing.T) {
	tape := fuzzx.Tape {
		version = fuzzx.TAPE_VERSION,
		target  = "interact",
	}
	tape.ops = make([dynamic]fuzzx.Tape_Op)
	append(&tape.ops, fuzzx.Tape_Op{tag = INTERACT_OP_FRAME})
	testing.expect_value(t, interact_tape_execute(&tape).class, INTERACT_FAILURE_OPERATION)
	clear(&tape.ops)
	append(&tape.ops, fuzzx.Tape_Op{tag = 999})
	testing.expect_value(t, interact_tape_execute(&tape).class, INTERACT_FAILURE_OPERATION)
	delete(tape.ops)
}
