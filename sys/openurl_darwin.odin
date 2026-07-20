// open_url (macOS): launch the default browser via `open`.
package sys

import "core:c/libc"
import "core:fmt"
import "core:strings"

open_url :: proc(url: string) {
	cmd := fmt.tprintf("open '%s'", url)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
}
