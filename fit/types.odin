package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

Builder :: struct {
	inner:        ui.Fit_Builder,
	root:         ui.Ui,
	customs:      [STORAGE_NODE_DEFAULT]Custom_Spec,
	customs_used: i32,
	bound:        bool,
}

Storage_Node :: ui.Prepared_Node
Storage :: ui.Fit_Storage
STORAGE_NODE_DEFAULT :: ui.MAX_PREPARED_NODES
STORAGE_NODE_HARD_MAX :: ui.MAX_PREPARED_NODES_HARD

App :: struct {
	inner:    ui_gfx.App,
	builder:  Builder,
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
	userdata: rawptr,
}

Session :: struct {
	inner:   ui_gfx.Session,
	frame:   ui_gfx.Session_Frame,
	builder: Builder,
	open:    bool,
}

State :: enum u8 {
	Empty,
	Ready,
	Running,
	Stopped,
}

Frame_Pacing :: enum u8 {
	Fixed,
	Uncapped,
	Monitor_Refresh,
}

Session_Config :: struct {
	user_scale:        f32,
	semantics_enabled: bool,
}

Paint_Peaks :: struct {
	main_commands:    int,
	main_text_bytes:  int,
	overlay_commands: int,
	overlay_text_bytes: int,
}

Config :: struct {
	width:         i32,
	height:        i32,
	title:         cstring,
	flags:         gfx.ConfigFlags,
	frame_pacing:  Frame_Pacing,
	target_fps:    i32,
	event_waiting: bool,
	session:       Session_Config,
}

Draw_Proc :: #type proc(builder: ^Builder, userdata: rawptr)
Session_Draw_Proc :: #type proc(builder: ^Builder, userdata: rawptr)
Shutdown_Proc :: #type proc(app: ^App, userdata: rawptr)

Callbacks :: struct {
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
}

Track :: ui.Track
Track_Kind :: ui.Track_Kind
Space :: ui.Space
Cross_Align :: ui.Cross_Align
Main_Align :: ui.Main_Align
Text_Role :: ui.Text_Role
Ink :: ui.Ink
Button_Style :: ui.Btn_Style
Btn_Style :: ui.Btn_Style
Widget_Id :: ui.Widget_Id
Rect :: ui.Rect_I32
Size :: ui.Intrinsic_Size
Constraints :: struct {
	min_w, min_h: i32,
	max_w, max_h: i32,
}
Z_Order :: ui.Z_Order
Transition_State :: ui.Transition_Rect_State
Transition_Options :: ui.Transition_Options
Aspect_Ratio :: ui.Aspect_Ratio
Float_Rect :: ui.Rect
Color :: ui.Color
Radius :: ui.Radius
Border :: ui.Border

Transition :: struct {
	state:   ^Transition_State,
	options: Transition_Options,
}

Size_Options :: struct {
	width:      Track,
	height:     Track,
	aspect:     Aspect_Ratio,
	transition: Transition,
}

Container_Effects :: struct {
	clip:         bool,
	background:   Color,
	radius:       Radius,
	border:       Border,
	border_color: Color,
}

Container_Options :: struct {
	gap:     Space,
	padding: Space,
	align:   Cross_Align,
	justify: Main_Align,
	track:   Track,
	size:    Size_Options,
	effects: Container_Effects,
}

Flow_Options :: struct {
	gap_x, gap_y: Space,
	padding:      Space,
	track:        Track,
	size:         Size_Options,
	effects:      Container_Effects,
}

Grid_Options :: struct {
	columns:      i32,
	row_height:   i32,
	gap_x, gap_y: Space,
	padding:      Space,
	track:        Track,
	size:         Size_Options,
	effects:      Container_Effects,
}

Attachment_Target :: ui.Attachment_Target_Kind
Attachment_Point :: ui.Attachment_Point

Attachment_Options :: struct {
	target_kind:       Attachment_Target,
	target:            i32,
	target_screen:     Rect,
	target_point:      Attachment_Point,
	self_point:        Attachment_Point,
	offset_x:          i32,
	offset_y:          i32,
	z:                 Z_Order,
	claim:             bool,
	clamp_to_viewport: bool,
	transition:        Transition,
}

Label_Options :: struct {
	role:  Text_Role,
	ink:   Ink,
	wrap:  bool,
	track: Track,
	size:  Size_Options,
}

Button_Options :: struct {
	style:       Button_Style,
	disabled:    bool,
	web_form_id: string,
	track:       Track,
	size:        Size_Options,
	activated:   ^bool,
}

Custom_Options :: struct {
	track:     Track,
	size:      Size_Options,
	activated: ^bool,
}

Surface :: struct {
	inner: ^ui.Ui,
}

Measure_Proc :: #type proc(constraints: Constraints, userdata: rawptr) -> Size
Render_Proc :: #type proc(surface: ^Surface, rect: Rect, userdata: rawptr) -> bool

Custom_Spec :: struct {
	measure:  Measure_Proc,
	render:   Render_Proc,
	userdata: rawptr,
	size:     Size_Options,
}

Fixed :: ui.fixed
Grow :: ui.grow
Percent :: ui.percent
Fit :: ui.fit
