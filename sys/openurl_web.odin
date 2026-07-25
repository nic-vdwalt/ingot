#+build js
// open_url (web): browsers cannot exec a shell like the native darwin/linux/
// windows variants, so route the URL through a JS bridge that calls
// window.open(). Backed by the ingot_open module in web/ingot_app.js.
package sys

foreign import openurl "ingot_open"
@(default_calling_convention = "c")
foreign openurl {
	// ingot_open_url opens `url` (byte range) in a new browser tab.
	ingot_open_url :: proc(url: [^]byte, url_len: i32) ---
}

open_url :: proc(
	url: string,
	options: Open_URL_Options = {allow_http = true, allow_https = true},
) -> Open_URL_Status {
	validated, status := _validate_external_url(url, options)
	if status != .Opened do return status
	b := transmute([]byte)validated
	ingot_open_url(raw_data(b), i32(len(b)))
	return .Opened
}
