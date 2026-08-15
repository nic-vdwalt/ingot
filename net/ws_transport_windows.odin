#+build windows
package ingotnet

import "core:os"

ws_read_ca_file :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil && len(data) > 0
}
