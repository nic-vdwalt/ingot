package ingotnet

import "core:strings"

query_component_encode :: proc(value: string, allocator := context.temp_allocator) -> string {
	if len(value) == 0 do return ""
	hex := "0123456789ABCDEF"
	builder := strings.builder_make(allocator)
	for byte in transmute([]u8)value {
		unreserved :=
			(byte >= 'a' && byte <= 'z') ||
			(byte >= 'A' && byte <= 'Z') ||
			(byte >= '0' && byte <= '9') ||
			byte == '-' ||
			byte == '.' ||
			byte == '_' ||
			byte == '~'
		if unreserved {
			strings.write_byte(&builder, byte)
		} else {
			strings.write_byte(&builder, '%')
			strings.write_byte(&builder, hex[byte >> 4])
			strings.write_byte(&builder, hex[byte & 15])
		}
	}
	return strings.to_string(builder)
}
