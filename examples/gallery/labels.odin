package main

import fit "ingot:fit"

// Gallery labels are rebuilt every frame. They are built with fit.Label_Text
// rather than core:fmt because, once fmt's procedures turn hot, Safari 20621's
// optimizing WASM tier aborts the page compiling their `any` type switches
// (WebKit bug 317022; see ui/label_text.odin). Each helper reproduces the fmt
// output it replaced byte for byte.

// prefix + %d + suffix.
label_int :: proc(prefix: string, value: i64, suffix: string = "") -> string {
	text: fit.Label_Text
	fit.label_text_string(&text, prefix)
	fit.label_text_int(&text, value)
	fit.label_text_string(&text, suffix)
	assert(text.len >= len(prefix) || text.truncated, "label_int: lost prefix")
	assert(!text.truncated, "label_int: label overflow")
	return fit.label_text_temp(&text)
}

// prefix + %.Nf + suffix.
label_float :: proc(prefix: string, value: f64, decimals: int, suffix: string = "") -> string {
	assert(decimals >= 0 && decimals <= 6, "label_float: unsupported precision")
	text: fit.Label_Text
	fit.label_text_string(&text, prefix)
	fit.label_text_float(&text, value, decimals)
	fit.label_text_string(&text, suffix)
	assert(!text.truncated, "label_float: label overflow")
	return fit.label_text_temp(&text)
}

// Concatenation of the parts, truncated at fit.LABEL_TEXT_BYTES_MAX.
label_join :: proc(parts: ..string) -> string {
	assert(len(parts) > 0, "label_join: no parts")
	text: fit.Label_Text
	for part in parts do fit.label_text_string(&text, part)
	assert(text.len <= fit.LABEL_TEXT_BYTES_MAX, "label_join: length out of range")
	return fit.label_text_temp(&text)
}

// fmt's %q for the gallery's name field. Only `"` and `\` are escaped: the
// field accepts typed printable text, so the control-character and non-UTF-8
// escapes %q also performs cannot occur here.
label_quoted :: proc(value: string) -> string {
	text: fit.Label_Text
	fit.label_text_byte(&text, '"')
	for index in 0 ..< len(value) {
		byte := value[index]
		if byte == '"' || byte == '\\' do fit.label_text_byte(&text, '\\')
		fit.label_text_byte(&text, byte)
	}
	fit.label_text_byte(&text, '"')
	assert(text.len >= 2 || text.truncated, "label_quoted: missing quotes")
	return fit.label_text_temp(&text)
}

// fmt's "#%02X%02X%02X".
label_hex_color :: proc(red, green, blue: u8) -> string {
	text: fit.Label_Text
	fit.label_text_byte(&text, '#')
	fit.label_text_hex2(&text, red)
	fit.label_text_hex2(&text, green)
	fit.label_text_hex2(&text, blue)
	assert(text.len == 7 && !text.truncated, "label_hex_color: bad length")
	return fit.label_text_temp(&text)
}

// Enum names exactly as fmt printed them (the field names). The arrays are
// complete, not #partial, so a new enum value fails the build instead of
// showing an empty label.
VISUAL_STATE_NAMES := [fit.Visual_State]string {
	.Rest     = "Rest",
	.Hover    = "Hover",
	.Pressed  = "Pressed",
	.Selected = "Selected",
	.Disabled = "Disabled",
}

SURFACE_KIND_NAMES := [fit.Surface_Kind]string {
	.App              = "App",
	.Panel            = "Panel",
	.Card             = "Card",
	.Popup            = "Popup",
	.Input            = "Input",
	.Row              = "Row",
	.Chip             = "Chip",
	.Code             = "Code",
	.Table_Header     = "Table_Header",
	.Button_Primary   = "Button_Primary",
	.Button_Secondary = "Button_Secondary",
	.Button_Danger    = "Button_Danger",
	.Button_Ghost     = "Button_Ghost",
}

INK_NAMES := [fit.Ink]string {
	.Primary      = "Primary",
	.Heading      = "Heading",
	.Secondary    = "Secondary",
	.Muted        = "Muted",
	.Accent       = "Accent",
	.Danger       = "Danger",
	.Success      = "Success",
	.Inverse      = "Inverse",
	.Disabled     = "Disabled",
	.Label        = "Label",
	.Accent_Light = "Accent_Light",
	.Tool         = "Tool",
	.Diff_Add     = "Diff_Add",
	.Diff_Remove  = "Diff_Remove",
	.User         = "User",
	.Assistant    = "Assistant",
	.Plan         = "Plan",
}

TEXT_ROLE_NAMES := [fit.Text_Role]string {
	.Body  = "Body",
	.Title = "Title",
	.Label = "Label",
	.Note  = "Note",
}

RADIUS_NAMES := [fit.Radius]string {
	.None = "None",
	.SM   = "SM",
	.MD   = "MD",
	.LG   = "LG",
	.Pill = "Pill",
}

SPACE_NAMES := [fit.Space]string {
	.None = "None",
	.XS   = "XS",
	.SM   = "SM",
	.MD   = "MD",
	.LG   = "LG",
	.XL   = "XL",
}

TINT_NAMES := [fit.Tint]string {
	.Subtle = "Subtle",
	.Light  = "Light",
	.Medium = "Medium",
	.Strong = "Strong",
}
