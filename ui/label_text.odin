// LIB-CANDIDATE: imports only core:*.
// Fixed-capacity label text for per-frame widget labels.
//
// Per-frame labels used to be built with core:fmt. On Safari 20621 (WebKit
// before 318166@main, bug 317022) the optimizing WASM tier aborts the whole
// page while compiling fmt's `any` type switches: their eight typeid-hash
// comparisons span more than 2^63, the span wraps, and B3 tries to allocate a
// jump table for the wrapped size. Those procedures are only compiled once they
// are hot, so keeping fmt off every per-frame path keeps them cold. strconv
// formats numbers without an `any` switch, which is why this builder uses it.
package ui

import "core:strconv"
import "core:strings"

LABEL_TEXT_BYTES_MAX :: 256
// Enough for any i64 in base 10 including the sign.
LABEL_TEXT_INT_BYTES :: 24
// strconv's 'f' formatting of the largest f64 needs ~310 digits plus the
// requested decimals; anything longer than a label can hold is truncated by
// the append below, so the scratch only has to cover realistic magnitudes.
LABEL_TEXT_FLOAT_BYTES :: 384
LABEL_TEXT_DECIMALS_MAX :: 6
LABEL_TEXT_PAD_WIDTH_MAX :: 20

// Callers own a Label_Text on the stack, append pieces, then take a temp
// string. Overflow is an operating condition (long user text), so it truncates
// and records `truncated` instead of asserting.
Label_Text :: struct {
	bytes:     [LABEL_TEXT_BYTES_MAX]u8,
	len:       int,
	truncated: bool,
}

@(private = "file")
label_text_valid :: proc(text: ^Label_Text) -> bool {
	return text != nil && text.len >= 0 && text.len <= LABEL_TEXT_BYTES_MAX
}

label_text_reset :: proc(text: ^Label_Text) {
	assert(text != nil)
	text.len = 0
	text.truncated = false
	assert(label_text_valid(text))
}

label_text_string :: proc(text: ^Label_Text, value: string) {
	assert(label_text_valid(text))
	room := LABEL_TEXT_BYTES_MAX - text.len
	count := min(len(value), room)
	copy(text.bytes[text.len:text.len + count], value[:count])
	text.len += count
	if count < len(value) do text.truncated = true
	assert(label_text_valid(text))
}

label_text_byte :: proc(text: ^Label_Text, value: u8) {
	assert(label_text_valid(text))
	if text.len == LABEL_TEXT_BYTES_MAX {
		text.truncated = true
		return
	}
	assert(text.len >= 0 && text.len < len(text.bytes))
	text.bytes[text.len] = value
	text.len += 1
	assert(label_text_valid(text))
}

// Matches fmt's `%d`.
label_text_int :: proc(text: ^Label_Text, value: i64) {
	assert(label_text_valid(text))
	scratch: [LABEL_TEXT_INT_BYTES]u8
	digits := strconv.write_int(scratch[:], value, 10)
	assert(len(digits) > 0 && len(digits) <= LABEL_TEXT_INT_BYTES)
	label_text_string(text, digits)
}

// Matches fmt's `%0Nd` (e.g. `%02d`, `%04d`): zero padding goes after the
// sign, as fmt places it.
label_text_int_padded :: proc(text: ^Label_Text, value: i64, width: int) {
	assert(label_text_valid(text))
	assert(width >= 1 && width <= LABEL_TEXT_PAD_WIDTH_MAX)
	scratch: [LABEL_TEXT_INT_BYTES]u8
	digits := strconv.write_int(scratch[:], value, 10)
	assert(len(digits) > 0)
	digit_width := width
	if digits[0] == '-' {
		label_text_byte(text, '-')
		digits = digits[1:]
		digit_width -= 1
	}
	for _ in len(digits) ..< digit_width {
		label_text_byte(text, '0')
	}
	label_text_string(text, digits)
}

// Matches fmt's `%02X`.
label_text_hex2 :: proc(text: ^Label_Text, value: u8) {
	assert(label_text_valid(text))
	HEX_DIGITS :: "0123456789ABCDEF"
	#assert(len(HEX_DIGITS) == 16)
	digits := HEX_DIGITS
	high := value >> 4
	low := value & 0xF
	assert(int(high) < len(digits) && int(low) < len(digits))
	label_text_byte(text, digits[high])
	label_text_byte(text, digits[low])
}

// Matches fmt's `%.Nf`. strconv always emits a sign; fmt drops the `+` unless
// the `+` flag is set, so this does too.
label_text_float :: proc(text: ^Label_Text, value: f64, decimals: int) {
	assert(label_text_valid(text))
	assert(decimals >= 0 && decimals <= LABEL_TEXT_DECIMALS_MAX)
	scratch: [LABEL_TEXT_FLOAT_BYTES]u8
	digits := strconv.write_float(scratch[:], value, 'f', decimals, 64)
	assert(len(digits) > 0)
	if digits[0] == '+' do digits = digits[1:]
	label_text_string(text, digits)
}

// Temp-allocated copy, the same lifetime fmt.tprintf gave these labels.
label_text_temp :: proc(text: ^Label_Text) -> string {
	assert(label_text_valid(text))
	result := strings.clone(string(text.bytes[:text.len]), context.temp_allocator)
	assert(len(result) == text.len)
	return result
}

// Temp-allocated, NUL-terminated copy, the same lifetime fmt.ctprintf gave.
label_text_ctemp :: proc(text: ^Label_Text) -> cstring {
	assert(label_text_valid(text))
	result := strings.clone_to_cstring(string(text.bytes[:text.len]), context.temp_allocator)
	assert(result != nil)
	return result
}
