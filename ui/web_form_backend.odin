// LIB-CANDIDATE: imports only core:*.
// Web form interop backend: dependency-inverted bridge that lets text inputs
// and submit buttons mirror into real browser form controls (password-manager
// autofill, save-password prompts, form submit) without ui importing a
// renderer. The graphics adapter installs an implementation on web targets;
// everywhere else the zero value leaves every call a no-op.
package ui

Web_Form_Text_Result :: struct {
	value:   string, // temp-allocated by the backend; copy before frame end
	cursor:  int,
	changed: bool,
	focused: bool,
}

Web_Form_Sync_Text_Proc :: #type proc(
	data: rawptr,
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> Web_Form_Text_Result

Web_Form_Sync_Submit_Proc :: #type proc(
	data: rawptr,
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool

Web_Form_Backend :: struct {
	data:               rawptr,
	sync_text_input:    Web_Form_Sync_Text_Proc,
	sync_submit_button: Web_Form_Sync_Submit_Proc,
}

ui_runtime_set_web_form_backend :: proc(runtime: ^Ui_Runtime, backend: Web_Form_Backend) {
	assert(
		runtime != nil && runtime.initialized,
		"ui_runtime_set_web_form_backend: invalid runtime",
	)
	runtime.web_form = backend
}
