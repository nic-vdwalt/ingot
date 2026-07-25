// open_url (Windows): launch the default browser via ShellExecuteW.
package sys

import win "core:sys/windows"

open_url :: proc(
	url: string,
	options: Open_URL_Options = {allow_http = true, allow_https = true},
) -> Open_URL_Status {
	validated, status := _validate_external_url(url, options)
	if status != .Opened do return status
	result := win.ShellExecuteW(
		nil,
		win.utf8_to_wstring("open", context.temp_allocator),
		win.utf8_to_wstring(validated, context.temp_allocator),
		nil,
		nil,
		win.SW_SHOWNORMAL,
	)
	if uintptr(result) <= 32 do return .Failed
	return .Opened
}
