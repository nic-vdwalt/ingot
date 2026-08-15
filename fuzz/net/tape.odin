package fuzz_net

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import fuzzx "ingot:fuzz/fuzzx"
import ingotnet "ingot:net"

NET_TAPE_TARGET :: "net"
NET_OP_HTTP :: u16(1)
NET_OP_WS :: u16(2)
NET_FAILURE_HTTP_BODY :: u32(1)
NET_FAILURE_HTTP_STATUS :: u32(2)
NET_FAILURE_WS_CONSUMED :: u32(3)
NET_FAILURE_WS_EXTREME :: u32(4)
NET_FAILURE_WS_STATUS :: u32(5)
NET_FAILURE_OPERATION :: u32(6)

net_tape_generate :: proc(
	seed: u64,
	iterations: int,
	allocator := context.allocator,
) -> fuzzx.Tape {
	assert(iterations > 0, "net_tape_generate: non-positive iterations")
	assert(iterations <= fuzzx.TAPE_OPS_MAX / 2, "net_tape_generate: too many iterations")
	p := fuzzx.prng_make(seed)
	tape := fuzzx.Tape {
		version = fuzzx.TAPE_VERSION,
		target  = strings.clone(NET_TAPE_TARGET, allocator),
		seed    = seed,
	}
	tape.ops = make([dynamic]fuzzx.Tape_Op, 0, iterations * 2, allocator)
	for _ in 0 ..< iterations {
		http_data: []u8
		if fuzzx.int_range(&p, 0, 3) == 0 {
			maximum :=
				MAXIMUM_WIRE_BYTES_LARGE if fuzzx.int_range(&p, 0, 67) == 0 else MAXIMUM_WIRE_BYTES
			http_data = fuzzx.random_bytes(&p, maximum)
		} else {
			http_data = mutated_response(&p)
		}
		append(
			&tape.ops,
			fuzzx.Tape_Op{tag = NET_OP_HTTP, payload = net_copy_bytes(http_data, allocator)},
		)
		ws_data: []u8
		extreme := false
		switch fuzzx.int_range(&p, 0, 6) {
		case 0, 1:
			ws_data = fuzzx.random_bytes(&p, MAXIMUM_WIRE_BYTES)
		case 2:
			ws_data = extreme_ws_header(&p)
			extreme = true
		case:
			ws_data = mutated_ws_frame(&p)
		}
		payload := make([]u8, len(ws_data) + 1, allocator)
		payload[0] = extreme ? 1 : 0
		copy(payload[1:], ws_data)
		append(&tape.ops, fuzzx.Tape_Op{tag = NET_OP_WS, payload = payload})
		free_all(context.temp_allocator)
	}
	return tape
}

net_tape_execute :: proc(tape: ^fuzzx.Tape, userdata: rawptr = nil) -> fuzzx.Failure {
	if tape == nil || tape.target != NET_TAPE_TARGET {
		return fuzzx.failure_make(NET_FAILURE_OPERATION, -1, "invalid net tape")
	}
	for op_index in 0 ..< len(tape.ops) {
		op := tape.ops[op_index]
		switch op.tag {
		case NET_OP_HTTP:
			response, ok := ingotnet.parse_http_response(
				op.payload,
				MAXIMUM_BODY_LIMIT,
				context.temp_allocator,
			)
			if ok && len(response.body) > MAXIMUM_BODY_LIMIT {
				return fuzzx.failure_make(
					NET_FAILURE_HTTP_BODY,
					op_index,
					"parser exceeded maximum_body",
				)
			}
			if ok && (response.status < 100 || response.status > 599) {
				return fuzzx.failure_make(
					NET_FAILURE_HTTP_STATUS,
					op_index,
					"parser accepted invalid status",
				)
			}
		case NET_OP_WS:
			if len(op.payload) < 1 {
				return fuzzx.failure_make(
					NET_FAILURE_OPERATION,
					op_index,
					"truncated WebSocket operation",
				)
			}
			extreme := op.payload[0] != 0
			data := op.payload[1:]
			frame, consumed, status := ingotnet.ws_parse_frame(data)
			if consumed < 0 || consumed > len(data) {
				return fuzzx.failure_make(
					NET_FAILURE_WS_CONSUMED,
					op_index,
					"invalid consumed count",
				)
			}
			if extreme && status == .Ok {
				return fuzzx.failure_make(
					NET_FAILURE_WS_EXTREME,
					op_index,
					"accepted extreme length",
				)
			}
			incomplete := status == .Need_More || status == .Too_Big
			if incomplete && consumed != 0 {
				return fuzzx.failure_make(
					NET_FAILURE_WS_STATUS,
					op_index,
					"incomplete frame consumed bytes",
				)
			}
			if status == .Ok {
				if len(frame.payload) > ingotnet.WS_MAX_PAYLOAD {
					return fuzzx.failure_make(
						NET_FAILURE_WS_STATUS,
						op_index,
						"payload exceeded bound",
					)
				}
				if len(frame.payload) > 0 {
					start := uintptr(raw_data(data))
					payload_start := uintptr(raw_data(frame.payload))
					payload_end := payload_start + uintptr(len(frame.payload))
					if payload_start < start || payload_end > start + uintptr(consumed) {
						return fuzzx.failure_make(
							NET_FAILURE_WS_STATUS,
							op_index,
							"payload escaped frame",
						)
					}
				}
			}
		case:
			return fuzzx.failure_make(NET_FAILURE_OPERATION, op_index, "unknown net operation")
		}
		free_all(context.temp_allocator)
	}
	return {}
}

net_tape_cli :: proc() -> bool {
	replay_path := ""
	shrink_path := ""
	shrink_output := ""
	record_path := ""
	seed: u64 = 1
	iterations := 100
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-replay:") do replay_path = arg[len("-replay:"):]
		if strings.has_prefix(arg, "-shrink:") do shrink_path = arg[len("-shrink:"):]
		if strings.has_prefix(arg, "-shrink-output:") do shrink_output = arg[len("-shrink-output:"):]
		if strings.has_prefix(arg, "-record:") do record_path = arg[len("-record:"):]
		if strings.has_prefix(arg, "-seed:") {
			if value, ok := strconv.parse_u64(arg[len("-seed:"):]); ok do seed = value
		}
		if strings.has_prefix(arg, "-iterations:") {
			if value, ok := strconv.parse_int(arg[len("-iterations:"):]); ok do iterations = value
		}
	}
	modes := int(replay_path != "") + int(shrink_path != "") + int(record_path != "")
	if modes == 0 do return false
	if modes != 1 {
		fmt.eprintln("fuzz_net: choose exactly one of replay, shrink, or record")
		os.exit(2)
	}
	if record_path != "" {
		tape := net_tape_generate(seed, iterations)
		defer fuzzx.tape_destroy(&tape)
		if !fuzzx.tape_save(record_path, &tape) do os.exit(1)
		failure := net_tape_execute(&tape)
		if failure.failed do net_tape_fail(failure)
		fmt.println(fuzzx.tape_summary(&tape))
		return true
	}
	path := replay_path if replay_path != "" else shrink_path
	tape, err := fuzzx.tape_load(path, NET_TAPE_TARGET)
	if err != .None {
		fmt.eprintfln("fuzz_net: cannot load tape: %v", err)
		os.exit(1)
	}
	defer fuzzx.tape_destroy(&tape)
	if replay_path != "" {
		failure := net_tape_execute(&tape)
		if failure.failed do net_tape_fail(failure)
		fmt.println(fuzzx.tape_summary(&tape))
		return true
	}
	if shrink_output == "" {
		fmt.eprintln("fuzz_net: -shrink-output is required")
		os.exit(2)
	}
	result := fuzzx.tape_shrink(
		&tape,
		net_tape_execute,
		nil,
		{maximum_runs = 1024, allow_empty = true},
	)
	defer fuzzx.tape_destroy(&result.tape)
	if !result.reproduced {
		fmt.eprintln("fuzz_net: tape does not reproduce a structured failure")
		os.exit(1)
	}
	if !fuzzx.tape_save(shrink_output, &result.tape) do os.exit(1)
	fmt.printfln(
		"shrunk operations=%d runs=%d complete=%v",
		len(result.tape.ops),
		result.runs,
		result.complete,
	)
	return true
}

@(private)
net_tape_fail :: proc(failure: fuzzx.Failure) {
	fmt.eprintfln(
		"fuzz_net replay FAILED: class=%d operation=%d %s",
		failure.class,
		failure.op_index,
		failure.message,
	)
	os.exit(1)
}

@(private)
net_copy_bytes :: proc(source: []u8, allocator: mem.Allocator) -> []u8 {
	result := make([]u8, len(source), allocator)
	copy(result, source)
	return result
}
