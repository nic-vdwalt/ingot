package fuzz_net

import "core:testing"
import fuzzx "ingot:fuzz/fuzzx"

@(test)
net_tape_generation_and_replay_are_deterministic :: proc(t: ^testing.T) {
	first := net_tape_generate(12345, 8)
	defer fuzzx.tape_destroy(&first)
	second := net_tape_generate(12345, 8)
	defer fuzzx.tape_destroy(&second)
	first_bytes, first_ok := fuzzx.tape_encode(&first)
	defer delete(first_bytes)
	second_bytes, second_ok := fuzzx.tape_encode(&second)
	defer delete(second_bytes)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, len(first_bytes), len(second_bytes))
	for index in 0 ..< len(first_bytes) do testing.expect_value(t, first_bytes[index], second_bytes[index])
	testing.expect(t, !net_tape_execute(&first).failed)
	testing.expect(t, !net_tape_execute(&first).failed)
}

@(test)
net_tape_rejects_malformed_and_unknown_operations :: proc(t: ^testing.T) {
	tape := fuzzx.Tape{version = fuzzx.TAPE_VERSION, target = "net"}
	tape.ops = make([dynamic]fuzzx.Tape_Op)
	append(&tape.ops, fuzzx.Tape_Op{tag = NET_OP_WS})
	failure := net_tape_execute(&tape)
	testing.expect(t, failure.failed)
	testing.expect_value(t, failure.class, NET_FAILURE_OPERATION)
	clear(&tape.ops)
	append(&tape.ops, fuzzx.Tape_Op{tag = 999})
	failure = net_tape_execute(&tape)
	testing.expect(t, failure.failed)
	delete(tape.ops)
}
