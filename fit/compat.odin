package fit

import "ingot:ui"

Ui :: ui.Ui
Ui_Frame :: ui.Ui_Frame
Ui_Input :: ui.Ui_Input
Ui_Output :: ui.Ui_Output
Ui_Runtime :: ui.Ui_Runtime
Rect_I32 :: ui.Rect_I32
Pane :: ui.Pane
Layout :: ui.Layout
Flow_Layout :: ui.Flow_Layout
Fit_Column :: ui.Fit_Column
legacy_text_role :: ui.Text_Role
legacy_ink :: ui.Ink
legacy_btn_style :: ui.Btn_Style
legacy_color :: ui.Color
legacy_radius :: ui.Radius
legacy_space :: ui.Space
legacy_track :: ui.Track
legacy_rect :: ui.Rect
legacy_input_box :: ui.Input_Box
legacy_text_input_semantics :: ui.Text_Input_Semantics
legacy_slider_state :: ui.Slider_State
legacy_dropdown_state :: ui.Dropdown_State
legacy_combobox_state :: ui.Combobox_State
legacy_combobox_item :: ui.Combobox_Item
legacy_date_picker_state :: ui.Date_Picker_State
legacy_calendar_date :: ui.Calendar_Date
legacy_tooltip_state :: ui.Tooltip_State
legacy_listbox_state :: ui.Listbox_State
legacy_listbox_config :: ui.Listbox_Config
legacy_table_sort :: ui.Table_Sort
legacy_table_column :: ui.Table_Column
legacy_chart_state :: ui.Chart_State
legacy_chart_series :: ui.Chart_Series
legacy_modal_state :: ui.Modal_State
legacy_context_menu_state :: ui.Context_Menu_State
legacy_menu_item :: ui.Menu_Item
legacy_toast_state :: ui.Toast_State
legacy_toast_kind :: ui.Toast_Kind
legacy_confirm_dialog_state :: ui.Confirm_Dialog_State

fixed :: ui.fixed
grow :: ui.grow
percent :: ui.percent
fit :: ui.fit
begin :: ui.begin
end :: ui.end
padding :: ui.padding
space :: ui.space
separator :: ui.separator
spacer :: ui.spacer
scope_begin :: ui.scope_begin
scope_end :: ui.scope_end
row_begin :: ui.row_begin
row_end :: ui.row_end
column_begin :: ui.column_begin
column_end :: ui.column_end
flex_begin :: ui.flex_begin
flex_next :: ui.flex_next
flex_row_begin :: ui.flex_row_begin
flex_row_end :: ui.flex_row_end
flex_slot_next :: ui.flex_slot_next
remaining_rect :: ui.remaining_rect
remaining :: ui.remaining
slot_next :: ui.slot_next
next :: ui.next
next_sized :: ui.next_sized
next_weighted :: ui.next_weighted
push_row :: ui.push_row
row_weights :: ui.row_weights
layout_begin :: ui.layout_begin
layout_pop :: ui.layout_pop
layout_end :: ui.layout_end
flow_begin :: ui.flow_begin
flow_next :: ui.flow_next
flow_end :: ui.flow_end
fit_column_begin :: ui.fit_column_begin
fit_column_next :: ui.fit_column_next
fit_column_end :: ui.fit_column_end
grid_begin :: proc(
	state: ^Grid_State,
	rect: ui.Rect_I32,
	columns, row_height: i32,
	gap_x: i32 = 0,
	gap_y: i32 = 0,
) {
	assert(state != nil, "Fit.grid_begin: nil state")
	ui.grid_begin(&state.inner, rect, columns, row_height, gap_x, gap_y)
}
grid_next :: proc(state: ^Grid_State) -> ui.Rect_I32 {
	assert(state != nil, "Fit.grid_next: nil state")
	return ui.grid_next(&state.inner)
}
grid_skip_to :: proc(state: ^Grid_State, index: i32) {
	assert(state != nil, "Fit.grid_skip_to: nil state")
	ui.grid_skip_to(&state.inner, index)
}
grid_visible_range :: ui.grid_visible_range
grid_end :: proc(state: ^Grid_State) -> ui.Rect_I32 {
	assert(state != nil, "Fit.grid_end: nil state")
	return ui.grid_end(&state.inner)
}
pane_begin :: ui.pane_begin
pane_end :: ui.pane_end
pane_reset :: ui.pane_reset

label :: ui.label
button :: ui.button
button_at :: ui.button_at
checkbox :: ui.checkbox
radio :: ui.radio
slider_state :: ui.slider_state
dropdown :: ui.dropdown
combobox :: ui.combobox
date_picker :: ui.date_picker
text_input :: ui.text_input
text_input_box :: ui.text_input_box
text_input_state_destroy :: ui.text_input_state_destroy
input_box_init :: ui.input_box_init
input_box_destroy :: ui.input_box_destroy
input_box_reset :: ui.input_box_reset
input_box_set_text :: ui.input_box_set_text
input_box_text :: ui.input_box_text
combobox_state_destroy :: ui.combobox_state_destroy
icon_btn :: ui.icon_btn
back_btn :: ui.back_btn
collapsible_header :: ui.collapsible_header
spinner :: ui.spinner
status_pill :: ui.status_pill
progress_bar :: ui.progress_bar
progress_bar_animated :: ui.progress_bar_animated
kv_row :: ui.kv_row
section_header :: ui.section_header
section_header_at :: ui.section_header_at
tab_bar :: ui.tab_bar
table_header :: ui.table_header
table_tracks :: ui.table_tracks
listbox_begin :: ui.listbox_begin
selectable_row :: ui.selectable_row
listbox_end :: ui.listbox_end
canvas :: ui.canvas

text :: ui.text
text_width :: ui.text_width
text_role_size :: ui.text_role_size
text_role_line_height :: ui.text_role_line_height
text_ink :: ui.text_ink
text_truncated :: ui.text_truncated
measure_text_frame :: ui.measure_text_frame
measure_text_string_frame :: ui.measure_text_string_frame
draw_text_frame :: ui.draw_text_frame
draw_text_string :: ui.draw_text_string
draw_text_wrapped_frame :: ui.draw_text_wrapped_frame
draw_text_truncated_frame :: ui.draw_text_truncated_frame
truncate_path_middle_frame :: ui.truncate_path_middle_frame

draw_rectangle :: ui.draw_rectangle
draw_rectangle_rec :: ui.draw_rectangle_rec
draw_rectangle_lines :: ui.draw_rectangle_lines
draw_rectangle_lines_ex :: ui.draw_rectangle_lines_ex
draw_rectangle_rounded :: ui.draw_rectangle_rounded
draw_rectangle_rounded_lines_ex :: ui.draw_rectangle_rounded_lines_ex
draw_circle_v :: ui.draw_circle_v
draw_line_ex :: ui.draw_line_ex
draw_triangle :: ui.draw_triangle
draw_surface :: proc(
	frame: ^ui.Ui_Frame,
	rect: ui.Rectangle,
	surface: Surface_Kind,
	state: Visual_State = .Rest,
	radius: ui.Radius = .MD,
	border: ui.Border = .Hairline,
	elevation: ui.Elevation = .Flat,
) {
	ui.draw_surface(
		frame,
		rect,
		ui.Surface(surface),
		ui.Visual_State(state),
		radius,
		border,
		elevation,
	)
}
draw_shadow_hard :: ui.draw_shadow_hard
draw_app_header :: ui.draw_app_header
draw_debug_overlay :: ui.draw_debug_overlay
draw_scale_settings_panel :: ui.draw_scale_settings_panel

line_chart_at :: ui.line_chart_at
bar_chart_at :: ui.bar_chart_at
sparkline_at :: ui.sparkline_at
card_bg_at :: ui.card_bg_at
list_row_bg_at :: ui.list_row_bg_at
markdown_context :: ui.markdown_context
markdown_draw :: ui.markdown_draw
markdown_link_activated :: ui.markdown_link_activated

layer_begin :: ui.layer_begin
layer_end :: ui.layer_end
modal_begin :: ui.modal_begin
modal_end :: ui.modal_end
toast_push :: ui.toast_push
toasts_draw :: ui.toasts_draw
context_menu_open :: ui.context_menu_open
context_menu :: ui.context_menu
confirm_dialog_open :: ui.confirm_dialog_open
confirm_dialog :: ui.confirm_dialog
calendar_format :: ui.calendar_format
calendar_date_valid :: ui.calendar_date_valid
tooltip_wrapped_at :: ui.tooltip_wrapped_at

id :: ui.id
interact :: ui.interact
get_mouse_position :: ui.get_mouse_position
get_wheel_move :: ui.get_wheel_move
is_key_pressed :: ui.is_key_pressed
is_mouse_button_down :: ui.is_mouse_button_down
is_mouse_button_pressed :: ui.is_mouse_button_pressed
request_cursor :: ui.request_cursor
request_redraw :: ui.request_redraw
frame_pane_origin :: ui.frame_pane_origin
frame_viewport :: ui.frame_viewport
ui_frame_sc :: ui.ui_frame_sc
ui_frame_scf :: ui.ui_frame_scf
ui_frame_metrics :: ui.ui_frame_metrics
ui_frame_theme :: ui.ui_frame_theme
ui_runtime_init :: ui.ui_runtime_init
ui_runtime_destroy :: ui.ui_runtime_destroy
ui_runtime_set_scale :: ui.ui_runtime_set_scale
ui_runtime_set_theme :: ui.ui_runtime_set_theme
ui_frame_begin :: ui.ui_frame_begin
ui_frame_end :: ui.ui_frame_end
settings_auto_scale :: ui.settings_auto_scale
settings_scale_preset_index :: ui.settings_scale_preset_index
rect_f32 :: ui.rect_f32
point_in_rect :: ui.point_in_rect
contrast_ratio :: ui.contrast_ratio
space_pixels :: ui.space_pixels
color_tinted :: proc(color: ui.Color, tint: Tint) -> ui.Color {
	return ui.color_tinted(color, ui.Tint(tint))
}
tint_alpha :: proc(tint: Tint) -> u8 {
	return ui.tint_alpha(ui.Tint(tint))
}
theme_dark :: ui.theme_dark
theme_light :: ui.theme_light
theme_sketch_warm :: ui.theme_sketch_warm
theme_sketch_grey :: ui.theme_sketch_grey
theme_high_contrast :: ui.theme_high_contrast
theme_pigment :: proc(theme: ^ui.Theme, pigment: Pigment) -> ui.Color {
	return ui.theme_pigment(theme, ui.Pigment(pigment))
}

surface_colors :: proc(
	frame: ^ui.Ui_Frame,
	surface: Surface_Kind,
	state: Visual_State,
) -> ui.Surface_Colors {
	return ui.surface_colors(frame, ui.Surface(surface), ui.Visual_State(state))
}
scatter_unit :: ui.scatter_unit
dot_grid_fits :: ui.dot_grid_fits
draw_rule_lines :: ui.draw_rule_lines
draw_dot_grid :: ui.draw_dot_grid
draw_margin_rule :: ui.draw_margin_rule
draw_paper_tooth :: ui.draw_paper_tooth
draw_hand_underline :: ui.draw_hand_underline
draw_pigment_block :: ui.draw_pigment_block
draw_chalk_highlight :: ui.draw_chalk_highlight
draw_highlight_swipe :: ui.draw_highlight_swipe
draw_scribble_fill :: ui.draw_scribble_fill
draw_wash :: ui.draw_wash
draw_tape_strip :: ui.draw_tape_strip
draw_dog_ear :: ui.draw_dog_ear
eased :: ui.eased
