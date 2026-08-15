package fuzzx

// Shared fuzz-harness support: deterministic PRNG, structure-aware mutation
// engine, option parsing, and failure reporting with input dumps.
//
// The PRNG is xorshift64* with explicit seeds (TigerBeetle VOPR style) so any
// failure reproduces exactly. The mutators go beyond byte flips: insertion,
// deletion, duplication, cross-template splicing, and boundary-byte / ASCII
// digit-run injection reach parser states plain flips cannot (length-field
// poisoning, delimiter removal, structure duplication).

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "ingot:testx"

Prng :: testx.Prng
prng_make :: testx.prng_make
next_u64 :: testx.next_u64
int_range :: testx.int_range
random_bytes :: testx.random_bytes

// parse_options reads -seed:N, -iterations:N, and -rounds:N from os.args.
// Each round reruns the whole workload with a derived seed (seed + round),
// so one binary invocation can soak across many seeds.
parse_options :: proc(iterations_default: int) -> (seed: u64, iterations: int, rounds: int) {
	seed = u64(time.now()._nsec) // replaced by -seed:N for reproduction runs
	iterations = iterations_default
	rounds = 1
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-seed:") {
			if value, ok := strconv.parse_u64(arg[len("-seed:"):]); ok do seed = value
		}
		if strings.has_prefix(arg, "-iterations:") {
			if value, ok := strconv.parse_int(arg[len("-iterations:"):]); ok do iterations = value
		}
		if strings.has_prefix(arg, "-rounds:") {
			if value, ok := strconv.parse_int(arg[len("-rounds:"):]); ok do rounds = value
		}
	}
	assert(iterations > 0)
	assert(rounds > 0)
	return seed, iterations, rounds
}

// BOUNDARY_BYTES are values that sit on sign/UTF-8/ASCII edges - injected to
// poison length fields, delimiters, and rune decoding.
BOUNDARY_BYTES := [?]u8{0x00, 0x7F, 0x80, 0xFF}

// mutate applies 1–4 random structural mutations to a copy of data and
// returns the (temp-allocated) result. Mutations: byte replace, bit flip,
// insert random bytes, delete a range, duplicate a range, boundary-byte
// injection, and ASCII digit-run injection (length-field poisoning).
mutate :: proc(p: ^Prng, data: []u8) -> []u8 {
	buf := make([dynamic]u8, 0, len(data) + 16, context.temp_allocator)
	append(&buf, ..data)
	for _ in 0 ..< int_range(p, 1, 5) {
		switch int_range(p, 0, 7) {
		case 0:
			// byte replace
			if len(buf) > 0 do buf[int_range(p, 0, len(buf))] = u8(next_u64(p) & 0xFF)
		case 1:
			// bit flip
			if len(buf) > 0 do buf[int_range(p, 0, len(buf))] ~= 1 << uint(int_range(p, 0, 8))
		case 2:
			// insert 1–8 random bytes
			at := int_range(p, 0, len(buf) + 1)
			count := int_range(p, 1, 9)
			for _ in 0 ..< count do insert_byte(&buf, at, u8(next_u64(p) & 0xFF))
		case 3:
			// delete a range
			if len(buf) > 0 {
				start := int_range(p, 0, len(buf))
				end := min(start + int_range(p, 1, 17), len(buf))
				remove_range(&buf, start, end)
			}
		case 4:
			// duplicate a range in place
			if len(buf) > 0 {
				start := int_range(p, 0, len(buf))
				end := min(start + int_range(p, 1, 17), len(buf))
				chunk := make([]u8, end - start, context.temp_allocator)
				copy(chunk, buf[start:end])
				at := int_range(p, 0, len(buf) + 1)
				#reverse for b in chunk do insert_byte(&buf, at, b)
			}
		case 5:
			// boundary-byte injection
			at := int_range(p, 0, len(buf) + 1)
			insert_byte(&buf, at, BOUNDARY_BYTES[int_range(p, 0, len(BOUNDARY_BYTES))])
		case 6:
			// ASCII digit run - poisons length/chunk-size fields
			at := int_range(p, 0, len(buf) + 1)
			count := int_range(p, 1, 21)
			digits := "0123456789ABCDEFabcdef"
			for _ in 0 ..< count do insert_byte(&buf, at, digits[int_range(p, 0, len(digits))])
		}
	}
	return buf[:]
}

// splice copies a random slice of b into a random position of a (replacing
// bytes, not inserting), returning a temp-allocated copy. Cross-template
// splicing combines structural features (e.g. chunked headers spliced into a
// content-length response).
splice :: proc(p: ^Prng, a, b: []u8) -> []u8 {
	out := make([]u8, len(a), context.temp_allocator)
	copy(out, a)
	if len(a) == 0 || len(b) == 0 do return out
	src_start := int_range(p, 0, len(b))
	src_end := min(src_start + int_range(p, 1, 65), len(b))
	dst := int_range(p, 0, len(out))
	copy(out[dst:], b[src_start:src_end])
	return out
}

// Ctx carries the current fuzz input so any invariant failure can dump it.
Ctx :: struct {
	name:      string,
	seed:      u64,
	iteration: int,
	input:     []u8,
}

// check fails the run with a reproducible report (seed, iteration, hex dump
// of the offending input) when ok is false.
check :: proc(c: ^Ctx, ok: bool, message: string, loc := #caller_location) {
	if ok do return
	fmt.eprintfln("%s FAILED: %s at %v", c.name, message, loc)
	fmt.eprintfln("  reproduce with: -seed:%d (iteration %d)", c.seed, c.iteration)
	dump_hex(c.input)
	os.exit(1)
}

DUMP_MAXIMUM :: 256

dump_hex :: proc(input: []u8) {
	n := min(len(input), DUMP_MAXIMUM)
	fmt.eprintfln("  input (%d bytes%s):", len(input), len(input) > n ? ", truncated" : "")
	for row := 0; row < n; row += 16 {
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "  %04x: ", row)
		for i in row ..< min(row + 16, n) {
			fmt.sbprintf(&sb, "%02x ", input[i])
		}
		fmt.eprintln(strings.to_string(sb))
	}
}

// report prints tracking-allocator leaks / bad frees and exits non-zero.
// Call after the workload; a clean run returns silently.
report :: proc(track: ^mem.Tracking_Allocator, name: string, seed: u64) {
	if len(track.allocation_map) > 0 {
		for _, entry in track.allocation_map {
			fmt.eprintfln("LEAK %v bytes @ %v", entry.size, entry.location)
		}
		fmt.eprintfln(
			"%s FAILED: %d leaks - reproduce with -seed:%d",
			name,
			len(track.allocation_map),
			seed,
		)
		os.exit(1)
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintfln(
			"%s FAILED: %d bad frees - reproduce with -seed:%d",
			name,
			len(track.bad_free_array),
			seed,
		)
		os.exit(1)
	}
}

@(private)
insert_byte :: proc(buf: ^[dynamic]u8, at: int, b: u8) {
	inject_at(buf, min(at, len(buf)), b)
}
