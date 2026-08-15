package fuzzx

import "core:strings"
import "core:testing"

@(private = "file")
copy_bytes :: proc(source: []u8) -> []u8 {
	result := make([]u8, len(source))
	copy(result, source)
	return result
}

@(private = "file")
test_tape :: proc() -> Tape {
	tape := Tape {
		version = TAPE_VERSION,
		target  = strings.clone("synthetic"),
		seed    = 42,
	}
	tape.ops = make([dynamic]Tape_Op)
	append(&tape.ops, Tape_Op{tag = 7, payload = copy_bytes([]u8{0, 1, 0xFF})})
	append(&tape.ops, Tape_Op{tag = 65535, payload = make([]u8, 0)})
	return tape
}

@(test)
tape_codec_round_trip :: proc(t: ^testing.T) {
	source := test_tape()
	defer tape_destroy(&source)
	encoded, ok := tape_encode(&source)
	defer delete(encoded)
	testing.expect(t, ok)
	decoded, err := tape_decode(encoded, "synthetic")
	defer tape_destroy(&decoded)
	testing.expect_value(t, err, Tape_Error.None)
	testing.expect_value(t, decoded.target, source.target)
	testing.expect_value(t, decoded.seed, source.seed)
	testing.expect_value(t, len(decoded.ops), len(source.ops))
	for index in 0 ..< len(source.ops) {
		testing.expect_value(t, decoded.ops[index].tag, source.ops[index].tag)
		testing.expect_value(t, len(decoded.ops[index].payload), len(source.ops[index].payload))
		for byte_index in 0 ..< len(source.ops[index].payload) {
			testing.expect_value(
				t,
				decoded.ops[index].payload[byte_index],
				source.ops[index].payload[byte_index],
			)
		}
	}
	reencoded, reencoded_ok := tape_encode(&decoded)
	defer delete(reencoded)
	testing.expect(t, reencoded_ok)
	testing.expect_value(t, len(reencoded), len(encoded))
	for index in 0 ..< len(encoded) do testing.expect_value(t, reencoded[index], encoded[index])
}

@(test)
tape_decoder_rejects_invalid_inputs :: proc(t: ^testing.T) {
	_, err := tape_decode(nil)
	testing.expect_value(t, err, Tape_Error.Truncated)
	source := test_tape()
	defer tape_destroy(&source)
	encoded, ok := tape_encode(&source)
	defer delete(encoded)
	testing.expect(t, ok)
	bad_magic := copy_bytes(encoded)
	defer delete(bad_magic)
	bad_magic[0] = 0
	_, err = tape_decode(bad_magic)
	testing.expect_value(t, err, Tape_Error.Magic)
	bad_version := copy_bytes(encoded)
	defer delete(bad_version)
	write_u16(bad_version, 8, TAPE_VERSION + 1)
	_, err = tape_decode(bad_version)
	testing.expect_value(t, err, Tape_Error.Version)
	_, err = tape_decode(encoded, "other")
	testing.expect_value(t, err, Tape_Error.Target)
	_, err = tape_decode(encoded[:len(encoded) - 1])
	testing.expect_value(t, err, Tape_Error.Truncated)
	trailing := make([]u8, len(encoded) + 1)
	defer delete(trailing)
	copy(trailing, encoded)
	_, err = tape_decode(trailing)
	testing.expect_value(t, err, Tape_Error.Overflow)
}

@(test)
tape_limits_reject_oversized_values :: proc(t: ^testing.T) {
	tape := Tape {
		version = TAPE_VERSION,
		target  = strings.clone("synthetic"),
		seed    = 1,
	}
	defer tape_destroy(&tape)
	tape.ops = make([dynamic]Tape_Op)
	append(&tape.ops, Tape_Op{tag = 1, payload = make([]u8, TAPE_PAYLOAD_MAX + 1)})
	_, ok := tape_encode(&tape)
	testing.expect(t, !ok)
}

@(test)
failure_expect_is_non_terminating :: proc(t: ^testing.T) {
	testing.expect(t, !expect(true, 1, 0, "ok").failed)
	failure := expect(false, 17, 3, "failed")
	testing.expect(t, failure.failed)
	testing.expect_value(t, failure.class, u32(17))
	testing.expect_value(t, failure.op_index, i32(3))
}

@(private = "file")
shrink_sentinels :: proc(tape: ^Tape, userdata: rawptr) -> Failure {
	class := cast(^u32)userdata
	has_two := false
	has_five := false
	has_nine := false
	for op in tape.ops {
		has_two ||= op.tag == 2
		has_five ||= op.tag == 5
		has_nine ||= op.tag == 9
	}
	if has_nine do return failure_make(class^ + 1, 0, "unrelated")
	if has_two && has_five do return failure_make(class^, 0, "sentinels")
	return {}
}

@(private = "file")
shrink_fixture :: proc() -> Tape {
	tape := Tape {
		version = TAPE_VERSION,
		target  = strings.clone("shrink"),
		seed    = 7,
	}
	tape.ops = make([dynamic]Tape_Op)
	for tag in ([]u16{1, 2, 3, 4, 5, 6}) do append(&tape.ops, Tape_Op{tag = tag})
	return tape
}

@(test)
tape_shrinker_is_deterministic_and_class_stable :: proc(t: ^testing.T) {
	source := shrink_fixture()
	defer tape_destroy(&source)
	class := u32(41)
	options := Tape_Shrink_Options {
		maximum_runs = 128,
		allow_empty  = true,
	}
	first := tape_shrink(&source, shrink_sentinels, &class, options)
	defer tape_destroy(&first.tape)
	second := tape_shrink(&source, shrink_sentinels, &class, options)
	defer tape_destroy(&second.tape)
	testing.expect(t, first.reproduced && first.complete)
	testing.expect_value(t, len(first.tape.ops), 2)
	testing.expect_value(t, first.tape.ops[0].tag, u16(2))
	testing.expect_value(t, first.tape.ops[1].tag, u16(5))
	testing.expect_value(t, first.runs, second.runs)
	first_bytes, first_ok := tape_encode(&first.tape)
	defer delete(first_bytes)
	second_bytes, second_ok := tape_encode(&second.tape)
	defer delete(second_bytes)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, len(first_bytes), len(second_bytes))
	for index in 0 ..< len(first_bytes) do testing.expect_value(t, first_bytes[index], second_bytes[index])
}

@(test)
tape_shrinker_reports_budget_and_non_failure :: proc(t: ^testing.T) {
	source := shrink_fixture()
	defer tape_destroy(&source)
	class := u32(41)
	limited := tape_shrink(
		&source,
		shrink_sentinels,
		&class,
		Tape_Shrink_Options{maximum_runs = 1, allow_empty = true},
	)
	defer tape_destroy(&limited.tape)
	testing.expect(t, limited.reproduced && limited.budget_exhausted)
	non_failure := Tape {
		version = TAPE_VERSION,
		target  = strings.clone("empty"),
		seed    = 1,
	}
	defer tape_destroy(&non_failure)
	non_failure.ops = make([dynamic]Tape_Op)
	result := tape_shrink(
		&non_failure,
		shrink_sentinels,
		&class,
		Tape_Shrink_Options{maximum_runs = 8, allow_empty = true},
	)
	defer tape_destroy(&result.tape)
	testing.expect(t, !result.reproduced)
	testing.expect_value(t, result.runs, 1)
}
