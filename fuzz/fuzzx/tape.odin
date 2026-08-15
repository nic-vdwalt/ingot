package fuzzx

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

TAPE_VERSION :: u16(1)
TAPE_MAGIC := [8]u8{'I', 'N', 'G', 'T', 'A', 'P', 'E', 0}
TAPE_TARGET_MAX :: 32
TAPE_OPS_MAX :: 131_072
TAPE_PAYLOAD_MAX :: 2 * 1024 * 1024
TAPE_BYTES_MAX :: 64 * 1024 * 1024
TAPE_HEADER_BYTES :: 24
TAPE_OP_HEADER_BYTES :: 8

Tape_Op :: struct {
	tag:     u16,
	payload: []u8,
}

Tape :: struct {
	version: u16,
	target:  string,
	seed:    u64,
	ops:     [dynamic]Tape_Op,
}

Tape_Error :: enum u8 {
	None,
	Magic,
	Version,
	Truncated,
	Overflow,
	Target,
	Limit,
	Io,
}

Tape_Shrink_Predicate :: #type proc(tape: ^Tape, userdata: rawptr) -> Failure

Tape_Shrink_Options :: struct {
	maximum_runs: int,
	minimum_ops:  int,
	allow_empty:  bool,
}

Tape_Shrink_Result :: struct {
	tape:             Tape,
	failure:          Failure,
	runs:             int,
	complete:         bool,
	budget_exhausted: bool,
	reproduced:       bool,
}

tape_destroy :: proc(tape: ^Tape, allocator := context.allocator) {
	assert(tape != nil, "tape_destroy: nil tape")
	for op in tape.ops do delete(op.payload, allocator)
	delete(tape.ops)
	delete(tape.target, allocator)
	tape^ = {}
}

tape_clone :: proc(source: ^Tape, allocator := context.allocator) -> Tape {
	assert(source != nil, "tape_clone: nil source")
	result := Tape{version = source.version, target = strings.clone(source.target, allocator), seed = source.seed}
	result.ops = make([dynamic]Tape_Op, 0, len(source.ops), allocator)
	for op in source.ops {
		payload := make([]u8, len(op.payload), allocator)
		copy(payload, op.payload)
		append(&result.ops, Tape_Op{tag = op.tag, payload = payload})
	}
	return result
}

tape_encoded_size :: proc(tape: ^Tape) -> (int, bool) {
	if tape == nil || len(tape.target) == 0 || len(tape.target) > TAPE_TARGET_MAX do return 0, false
	if len(tape.ops) > TAPE_OPS_MAX do return 0, false
	size := TAPE_HEADER_BYTES + len(tape.target)
	for op in tape.ops {
		if len(op.payload) > TAPE_PAYLOAD_MAX do return 0, false
		if size > TAPE_BYTES_MAX - TAPE_OP_HEADER_BYTES - len(op.payload) do return 0, false
		size += TAPE_OP_HEADER_BYTES + len(op.payload)
	}
	return size, size <= TAPE_BYTES_MAX
}

tape_encode :: proc(tape: ^Tape, allocator := context.allocator) -> ([]u8, bool) {
	size, valid := tape_encoded_size(tape)
	if !valid do return nil, false
	buffer := make([]u8, size, allocator)
	copy(buffer[:8], TAPE_MAGIC[:])
	write_u16(buffer, 8, TAPE_VERSION)
	write_u16(buffer, 10, u16(len(tape.target)))
	write_u32(buffer, 12, u32(len(tape.ops)))
	write_u64(buffer, 16, tape.seed)
	offset := TAPE_HEADER_BYTES
	copy(buffer[offset:], transmute([]u8)tape.target)
	offset += len(tape.target)
	for op in tape.ops {
		write_u16(buffer, offset, op.tag)
		write_u16(buffer, offset + 2, 0)
		write_u32(buffer, offset + 4, u32(len(op.payload)))
		offset += TAPE_OP_HEADER_BYTES
		copy(buffer[offset:], op.payload)
		offset += len(op.payload)
	}
	assert(offset == len(buffer), "tape_encode: size mismatch")
	return buffer, true
}

tape_decode :: proc(data: []u8, expected_target: string = "", allocator := context.allocator) -> (Tape, Tape_Error) {
	if len(data) > TAPE_BYTES_MAX do return {}, .Limit
	if len(data) < TAPE_HEADER_BYTES do return {}, .Truncated
	for index in 0 ..< len(TAPE_MAGIC) {
		if data[index] != TAPE_MAGIC[index] do return {}, .Magic
	}
	version := read_u16(data, 8)
	if version != TAPE_VERSION do return {}, .Version
	target_len := int(read_u16(data, 10))
	op_count := int(read_u32(data, 12))
	if target_len <= 0 || target_len > TAPE_TARGET_MAX || op_count > TAPE_OPS_MAX do return {}, .Limit
	if target_len > len(data) - TAPE_HEADER_BYTES do return {}, .Truncated
	target := string(data[TAPE_HEADER_BYTES:TAPE_HEADER_BYTES + target_len])
	if expected_target != "" && target != expected_target do return {}, .Target
	result := Tape{version = version, target = strings.clone(target, allocator), seed = read_u64(data, 16)}
	result.ops = make([dynamic]Tape_Op, 0, op_count, allocator)
	offset := TAPE_HEADER_BYTES + target_len
	for _ in 0 ..< op_count {
		if offset > len(data) - TAPE_OP_HEADER_BYTES {
			tape_destroy(&result, allocator)
			return {}, .Truncated
		}
		tag := read_u16(data, offset)
		payload_len_u32 := read_u32(data, offset + 4)
		if u64(payload_len_u32) > u64(TAPE_PAYLOAD_MAX) {
			tape_destroy(&result, allocator)
			return {}, .Limit
		}
		payload_len := int(payload_len_u32)
		offset += TAPE_OP_HEADER_BYTES
		if payload_len > len(data) - offset {
			tape_destroy(&result, allocator)
			return {}, .Truncated
		}
		payload := make([]u8, payload_len, allocator)
		copy(payload, data[offset:offset + payload_len])
		append(&result.ops, Tape_Op{tag = tag, payload = payload})
		offset += payload_len
	}
	if offset != len(data) {
		tape_destroy(&result, allocator)
		return {}, .Overflow
	}
	return result, .None
}

tape_load :: proc(path, expected_target: string, allocator := context.allocator) -> (Tape, Tape_Error) {
	if path == "" do return {}, .Io
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, .Io
	return tape_decode(data, expected_target, allocator)
}

tape_save :: proc(path: string, tape: ^Tape) -> bool {
	if path == "" || tape == nil do return false
	data, ok := tape_encode(tape, context.temp_allocator)
	if !ok do return false
	temporary := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(temporary, data) != nil do return false
	if os.rename(temporary, path) != nil {
		_ = os.remove(temporary)
		return false
	}
	return true
}

tape_summary :: proc(tape: ^Tape) -> string {
	assert(tape != nil, "tape_summary: nil tape")
	size, _ := tape_encoded_size(tape)
	return fmt.tprintf("target=%s version=%d seed=%d operations=%d bytes=%d", tape.target, tape.version, tape.seed, len(tape.ops), size)
}

tape_shrink :: proc(
	source: ^Tape,
	predicate: Tape_Shrink_Predicate,
	userdata: rawptr,
	options: Tape_Shrink_Options,
	allocator := context.allocator,
) -> Tape_Shrink_Result {
	assert(source != nil, "tape_shrink: nil source")
	assert(predicate != nil, "tape_shrink: nil predicate")
	assert(options.maximum_runs > 0, "tape_shrink: non-positive run limit")
	assert(options.minimum_ops >= 0, "tape_shrink: negative minimum")
	result := Tape_Shrink_Result{tape = tape_clone(source, allocator)}
	original := predicate(&result.tape, userdata)
	result.runs = 1
	result.failure = original
	if !original.failed do return result
	result.reproduced = true
	minimum := options.minimum_ops
	if !options.allow_empty do minimum = max(minimum, 1)
	parts := min(2, len(result.tape.ops))
	for len(result.tape.ops) > minimum && parts > 0 {
		removed := false
		chunk := (len(result.tape.ops) + parts - 1) / parts
		start := 0
		for start < len(result.tape.ops) {
			if result.runs >= options.maximum_runs {
				result.budget_exhausted = true
				return result
			}
			end := min(start + chunk, len(result.tape.ops))
			if len(result.tape.ops) - (end - start) < minimum {
				start = end
				continue
			}
			candidate := tape_without_range(&result.tape, start, end, allocator)
			failure := predicate(&candidate, userdata)
			result.runs += 1
			if failure.failed && failure.class == original.class {
				tape_destroy(&result.tape, allocator)
				result.tape = candidate
				result.failure = failure
				parts = max(parts - 1, 2)
				removed = true
				break
			}
			tape_destroy(&candidate, allocator)
			start = end
		}
		if removed do continue
		if parts >= len(result.tape.ops) do break
		parts = min(parts * 2, len(result.tape.ops))
	}
	result.complete = true
	return result
}

@(private)
tape_without_range :: proc(source: ^Tape, start, end: int, allocator: mem.Allocator) -> Tape {
	assert(source != nil, "tape_without_range: nil source")
	assert(start >= 0 && start < end && end <= len(source.ops), "tape_without_range: invalid range")
	result := Tape{version = source.version, target = strings.clone(source.target, allocator), seed = source.seed}
	result.ops = make([dynamic]Tape_Op, 0, len(source.ops) - (end - start), allocator)
	for index in 0 ..< len(source.ops) {
		if index >= start && index < end do continue
		op := source.ops[index]
		payload := make([]u8, len(op.payload), allocator)
		copy(payload, op.payload)
		append(&result.ops, Tape_Op{tag = op.tag, payload = payload})
	}
	return result
}

@(private)
write_u16 :: proc(data: []u8, offset: int, value: u16) {
	assert(offset >= 0 && offset <= len(data) - 2, "write_u16: out of range")
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private)
write_u32 :: proc(data: []u8, offset: int, value: u32) {
	assert(offset >= 0 && offset <= len(data) - 4, "write_u32: out of range")
	for index in 0 ..< 4 do data[offset + index] = u8(value >> u32(index * 8))
}

@(private)
write_u64 :: proc(data: []u8, offset: int, value: u64) {
	assert(offset >= 0 && offset <= len(data) - 8, "write_u64: out of range")
	for index in 0 ..< 8 do data[offset + index] = u8(value >> u64(index * 8))
}

@(private)
read_u16 :: proc(data: []u8, offset: int) -> u16 {
	assert(offset >= 0 && offset <= len(data) - 2, "read_u16: out of range")
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private)
read_u32 :: proc(data: []u8, offset: int) -> u32 {
	assert(offset >= 0 && offset <= len(data) - 4, "read_u32: out of range")
	value: u32
	for index in 0 ..< 4 do value |= u32(data[offset + index]) << u32(index * 8)
	return value
}

@(private)
read_u64 :: proc(data: []u8, offset: int) -> u64 {
	assert(offset >= 0 && offset <= len(data) - 8, "read_u64: out of range")
	value: u64
	for index in 0 ..< 8 do value |= u64(data[offset + index]) << u64(index * 8)
	return value
}
