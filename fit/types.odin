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

Storage_Node :: distinct ui.Prepared_Node
Storage :: struct {
	nodes:   []Storage_Node,
	outputs: []^bool,
}
STORAGE_NODE_DEFAULT :: ui.MAX_PREPARED_NODES
STORAGE_NODE_HARD_MAX :: ui.MAX_PREPARED_NODES_HARD
#assert(size_of(Storage_Node) == size_of(ui.Prepared_Node))
#assert(align_of(Storage_Node) == align_of(ui.Prepared_Node))

App :: struct {
	inner:    ui_gfx.App,
	builder:  Builder,
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
	userdata: rawptr,
}

Session :: struct {
	inner:    ui_gfx.Session,
	builder:  Builder,
	draw:     Session_Draw_Proc,
	userdata: rawptr,
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
	main_commands:      int,
	main_text_bytes:    int,
	overlay_commands:   int,
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
Build_Proc :: #type proc(builder: ^Builder, userdata: rawptr)

Callbacks :: struct {
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
}

Track_Kind :: enum u8 {
	Fit,
	Grow,
	Fixed,
	Percent,
}
Track :: struct {
	kind:     Track_Kind,
	basis:    i32,
	weight:   i32,
	percent:  f32,
	min_size: i32,
	max_size: i32,
}
Space :: enum u8 {
	None,
	XS,
	SM,
	MD,
	LG,
	XL,
}
Cross_Align :: enum u8 {
	Stretch,
	Start,
	Center,
	End,
}
Main_Align :: enum u8 {
	Start,
	Center,
	End,
	Space_Between,
}
Text_Role :: enum u8 {
	Body,
	Title,
	Label,
	Note,
}
Ink :: enum u8 {
	Primary,
	Heading,
	Secondary,
	Muted,
	Accent,
	Danger,
	Success,
	Inverse,
	Disabled,
	Label,
	Accent_Light,
	Tool,
	Diff_Add,
	Diff_Remove,
	User,
	Assistant,
	Plan,
}
Button_Style :: enum u8 {
	Primary,
	Secondary,
	Danger,
	Ghost,
}
Btn_Style :: Button_Style
Widget_Id :: distinct u64
Rect :: struct {
	x, y, w, h: i32,
}
Size :: struct {
	w, h:     i32,
	overflow: bool,
}
Constraints :: struct {
	min_w, min_h: i32,
	max_w, max_h: i32,
}
Z_Order :: distinct f32
Transition_State :: struct {
	current:     Rect,
	target:      Rect,
	initialized: bool,
}
Transition_Options :: struct {
	speed: f32,
}
Aspect_Ratio :: struct {
	width, height: i32,
}
Float_Rect :: struct {
	x, y, width, height: f32,
}
Color :: distinct [4]u8
Point :: struct {
	x, y: f32,
}
Key :: enum i32 {
	Escape = 256,
	Enter  = 257,
	Tab    = 258,
	Space  = 32,
	F12    = 301,
	Up     = 265,
	Down   = 264,
}
Mouse_Button :: enum i32 {
	Left,
	Right,
	Middle,
}
Cursor :: enum i32 {
	Default,
	Arrow,
	IBeam,
	Crosshair,
	Pointing_Hand,
}
Interaction :: struct {
	hovered:  bool,
	pressed:  bool,
	held:     bool,
	released: bool,
	clicked:  bool,
}
Metrics :: struct {
	font_title:     i32,
	font_body:      i32,
	font_label:     i32,
	font_note:      i32,
	line_height:    i32,
	tab_bar_height: i32,
	padding:        i32,
	row_small:      i32,
	row_medium:     i32,
	control_gap:    i32,
}
Radius :: enum u8 {
	None,
	SM,
	MD,
	LG,
	Pill,
}
Border :: enum u8 {
	None,
	Hairline,
	Emphasis,
	Ink,
}

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

Attachment_Target :: enum u8 {
	Parent,
	Root,
	Handle,
	Screen_Rect,
	Viewport,
}
Attachment_Point :: enum u8 {
	Top_Left,
	Top,
	Top_Right,
	Left,
	Center,
	Right,
	Bottom_Left,
	Bottom,
	Bottom_Right,
}

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

Control_Options :: struct {
	track:   Track,
	size:    Size_Options,
	changed: ^bool,
}

Custom_Options :: struct {
	track:     Track,
	size:      Size_Options,
	activated: ^bool,
}

Surface :: struct {
	inner: ^ui.Ui,
}

Region :: struct {
	inner: ui.Ui,
}

Pane_State :: struct {
	inner: ui.Pane,
}

Measure_Proc :: #type proc(constraints: Constraints, userdata: rawptr) -> Size
Render_Proc :: #type proc(surface: ^Surface, rect: Rect, userdata: rawptr) -> bool

Custom_Spec :: struct {
	measure:  Measure_Proc,
	render:   Render_Proc,
	userdata: rawptr,
	size:     Size_Options,
}

Fixed :: proc(size: i32) -> Track {
	assert(size >= 0, "Fit.Fixed: negative size")
	return {kind = .Fixed, basis = size, min_size = size, max_size = size}
}

Grow :: proc(weight: i32 = 1, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(weight > 0, "Fit.Grow: non-positive weight")
	assert(min_size >= 0, "Fit.Grow: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "Fit.Grow: invalid maximum")
	return {kind = .Grow, weight = weight, min_size = min_size, max_size = max_size}
}

Percent :: proc(value: f32, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(value >= 0 && value <= 1, "Fit.Percent: value outside 0..1")
	assert(min_size >= 0, "Fit.Percent: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "Fit.Percent: invalid maximum")
	return {kind = .Percent, percent = value, min_size = min_size, max_size = max_size}
}

Fit :: proc(basis: i32, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(basis >= 0, "Fit.Fit: negative basis")
	assert(min_size >= 0, "Fit.Fit: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "Fit.Fit: invalid maximum")
	return {kind = .Fit, basis = basis, min_size = min_size, max_size = max_size}
}
