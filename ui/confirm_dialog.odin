// LIB-CANDIDATE: imports only core:*.
// Confirm dialog: a thin preset over the generic modal with a message and a
// Cancel / Confirm pair, for destructive actions that need a second look.
package ui

Confirm_Choice :: enum u8 {
	None,
	Confirmed,
	Canceled,
}

// Confirm_Dialog_State wraps the modal lifecycle. Set open with
// confirm_dialog_open; the dialog clears it on any outcome.
Confirm_Dialog_State :: struct {
	modal: Modal_State,
}

confirm_dialog_open :: proc(st: ^Confirm_Dialog_State) {
	assert(st != nil, "confirm_dialog_open: nil state")
	st.modal = {}
	st.modal.open = true
}

// confirm_dialog draws the dialog while open and reports the user's choice
// for this frame. Escape / click-away count as Canceled.
confirm_dialog :: proc(
	frame: ^Ui_Frame,
	st: ^Confirm_Dialog_State,
	title, message, confirm_label: string,
	screen: Rect_I32,
	danger: bool = true,
) -> Confirm_Choice {
	assert(frame != nil, "confirm_dialog: nil frame")
	assert(st != nil, "confirm_dialog: nil state")
	assert(title != "" && message != "", "confirm_dialog: empty text")
	assert(confirm_label != "", "confirm_dialog: empty confirm label")
	if !st.modal.open do return .None
	metrics := ui_frame_metrics(frame)
	body := modal_begin(
		frame,
		&st.modal,
		title,
		{size = {ui_frame_sc(frame, 420), ui_frame_sc(frame, 190)}, screen = screen},
	)
	message_x := body.x + metrics.PADDING
	message_w := body.w - metrics.PADDING * 2
	_ = draw_text_wrapped_frame(
		frame,
		message_x,
		body.y + ui_frame_sc(frame, 4),
		message_w,
		message,
		ui_frame_theme(frame).fg_secondary,
		metrics.FONT_SIZE_BODY,
		metrics.LINE_HEIGHT,
	)
	button_w := ui_frame_sc(frame, 110)
	button_h := metrics.ROW_H_MD
	button_y := body.y + body.h - button_h - metrics.PADDING
	cancel_rect := Rect_I32 {
		body.x + body.w - button_w * 2 - metrics.PADDING * 2,
		button_y,
		button_w,
		button_h,
	}
	confirm_rect := Rect_I32 {
		body.x + body.w - button_w - metrics.PADDING,
		button_y,
		button_w,
		button_h,
	}
	choice := Confirm_Choice.None
	if button_at(frame, cancel_rect, "Cancel", .Ghost) {
		choice = .Canceled
	}
	confirm_style: Btn_Style = .Danger if danger else .Primary
	if button_at(frame, confirm_rect, confirm_label, confirm_style) {
		choice = .Confirmed
	}
	modal_end(&st.modal)
	if st.modal.dismissed do choice = .Canceled
	if choice != .None {
		st.modal.open = false
		st.modal.dismissed = false
	}
	return choice
}
