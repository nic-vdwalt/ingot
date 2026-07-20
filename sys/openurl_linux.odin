// open_url (Linux): launch the default browser via xdg-open.
package sys

import "core:c/libc"
import "core:fmt"
import "core:strings"

open_url :: proc(url: string) {
	cmd := fmt.tprintf("xdg-open '%s' >/dev/null 2>&1 &", url)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
}
