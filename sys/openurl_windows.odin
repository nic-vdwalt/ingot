// open_url (Windows): launch the default browser via ShellExecuteW.
package sys

import win "core:sys/windows"

open_url :: proc(url: string) {
	win.ShellExecuteW(
		nil,
		win.utf8_to_wstring("open", context.temp_allocator),
		win.utf8_to_wstring(url, context.temp_allocator),
		nil,
		nil,
		win.SW_SHOWNORMAL,
	)
}
