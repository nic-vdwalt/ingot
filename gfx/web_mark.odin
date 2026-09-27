package gfx

// web_mark records an application breadcrumb in the browser crash recorder
// (web/ingot_crash.js), so a tab the OS kills without a JS error can still
// be attributed to what the app was doing, e.g. which page was open.
// No-op on native targets.
web_mark :: proc(label: string) {
	when ODIN_OS == .JS {
		if len(label) == 0 do return
		_js_web_mark(web_string_data(label), i32(len(label)))
	}
}
