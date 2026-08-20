package fit

import "ingot:ui"
import "ingot:ui_gfx"

Builder :: struct {
	inner:        ui.Fit_Builder,
	root:         ui.Ui,
	customs:      [STORAGE_NODE_DEFAULT]Custom_Spec,
	customs_used: i32,
	generation:   u64,
	bound:        bool,
}

Parent :: struct {
	builder:    ^Builder,
	generation: u64,
	handle:     ui.Prepared_Handle,
	identity:   ui.Widget_Id,
}

Signal :: struct {
	pending: bool,
}

Action_Proc :: #type proc(ctx: rawptr)
Tagged_Action_Proc :: #type proc(ctx: rawptr, tag: u64)

Action :: struct {
	procedure:        Action_Proc,
	tagged_procedure: Tagged_Action_Proc,
	ctx:          rawptr,
	tag:              u64,
}

@(private = "package")
STORAGE_NODE_SIZE :: size_of(ui.Prepared_Node)
@(private = "package")
STORAGE_NODE_ALIGNMENT :: align_of(ui.Prepared_Node)
Storage_Node :: struct #align (STORAGE_NODE_ALIGNMENT) {
	data: [STORAGE_NODE_SIZE]u8,
}
Storage :: struct {
	nodes:   []Storage_Node,
	outputs: []^bool,
}
STORAGE_NODE_DEFAULT :: 128
STORAGE_NODE_HARD_MAX :: 8192
#assert(STORAGE_NODE_DEFAULT == ui.MAX_PREPARED_NODES_DEFAULT)
#assert(STORAGE_NODE_HARD_MAX == ui.MAX_PREPARED_NODES_HARD)
#assert(size_of(Storage_Node) == size_of(ui.Prepared_Node))
#assert(align_of(Storage_Node) == align_of(ui.Prepared_Node))

App :: struct {
	inner:    ui_gfx.App,
	builder:  Builder,
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
	ctx:  rawptr,
}

Session :: struct {
	inner:   ui_gfx.Session,
	builder: Builder,
	draw:    Session_Draw_Proc,
	ctx: rawptr,
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

Window_Flag :: enum i32 {
	Fullscreen          = 1,
	Resizable           = 2,
	Undecorated         = 3,
	Transparent         = 4,
	Msaa_4x             = 5,
	Vsync               = 6,
	Hidden              = 7,
	Always_Run          = 8,
	Minimized           = 9,
	Maximized           = 10,
	Unfocused           = 11,
	Topmost             = 12,
	High_Dpi            = 13,
	Mouse_Passthrough   = 14,
	Borderless_Windowed = 15,
	Interlaced          = 16,
}
Window_Flags :: distinct bit_set[Window_Flag;i32]

Scale_Metrics_Proc :: #type proc(scale: f32)
Scale_Invalidate_Proc :: #type proc()

Session_Config :: struct {
	user_scale:        f32,
	semantics_enabled: bool,
	scale_metrics:     Scale_Metrics_Proc,
	scale_invalidate:  Scale_Invalidate_Proc,
}

Paint_Peaks :: struct {
	main_commands:      int,
	main_text_bytes:    int,
	overlay_commands:   int,
	overlay_text_bytes: int,
}

Paint_Summary :: struct {
	main_commands:          int,
	main_text_bytes:        int,
	main_geometry_commands: int,
	main_clip_depth:        int,
	overlay_commands:       int,
	overlay_text_bytes:     int,
	overlay_geometry:       int,
	overlay_clip_depth:     int,
	semantic_nodes:         int,
}

Frame_Timing :: struct {
	build_ns:          i64,
	measure_ns:        i64,
	layout_render_ns:  i64,
	builder_close_ns:  i64,
	frame_finalize_ns: i64,
	finalize_ns:       i64,
	frame_ns:          i64,
}

Paint_Telemetry :: struct {
	command_appends: u64,
	text_appends:    u64,
	text_bytes:      u64,
	command_growths: u64,
	text_growths:    u64,
}

Prepared_Phase_Timing :: struct {
	measure_natural_ns:    i64,
	resolve_size_ns:       i64,
	measure_resolved_ns:   i64,
	place_ns:              i64,
	render_tree_ns:        i64,
	output_clear_ns:       i64,
	finalize_routes_ns:    i64,
	finalize_semantics_ns: i64,
	finalize_lifetimes_ns: i64,
}

Frame_Telemetry :: struct {
	scratch_allocations:           u64,
	scratch_resizes:               u64,
	scratch_allocation_bytes:      u64,
	scratch_resize_bytes:          u64,
	main:                          Paint_Telemetry,
	overlay:                       Paint_Telemetry,
	text_input_full_paths:         u64,
	text_input_inactive_paths:     u64,
	phases:                        Prepared_Phase_Timing,
	description_nodes:             u64,
	leaf_nodes:                    u64,
	container_nodes:               u64,
	maximum_depth:                 u64,
	fixed_leaf_nodes:              u64,
	intrinsic_leaf_nodes:          u64,
	width_dependent_leaf_nodes:    u64,
	dependency_node_visits:        u64,
	dependency_child_visits:       u64,
	natural_node_visits:           u64,
	resolve_node_visits:           u64,
	remeasure_node_visits:         u64,
	width_assignment_visits:       u64,
	resolved_measure_visits:       u64,
	placement_node_visits:         u64,
	render_node_visits:            u64,
	child_run_visits:              u64,
	specialized_nodes:             u64,
	generic_fallback_nodes:        u64,
	natural_leaf_measures:         u64,
	resolved_leaf_measures:        u64,
	fixed_leaf_measure_skips:      u64,
	container_measures:            u64,
	width_assignments:             u64,
	placed_nodes:                  u64,
	rendered_nodes:                u64,
	activation_outputs:            u64,
	render_relayouts:              u64,
	measure_cache_hits:            u64,
	measure_cache_misses:          u64,
	measure_cache_policy_bypasses: u64,
}

Frame_Diagnostics :: struct {
	input_characters_dropped:   i32,
	degenerate_widgets_dropped: i32,
	semantic_nodes_dropped:     i32,
	semantic_focus_dropped:     i32,
	semantic_actions_dropped:   i32,
	semantic_id_collisions:     i32,
	semantic_text_truncations:  i32,
	main_commands_dropped:      i32,
	main_text_bytes_dropped:    i32,
	overlay_commands_dropped:   i32,
	overlay_text_bytes_dropped: i32,
	platform_controls_dropped:  i32,
}

Renderer_Peaks :: struct {
	vertices:                int,
	vertices_capacity:       int,
	indices:                 int,
	indices_capacity:        int,
	geometry_stream_bytes:   u64,
	geometry_capacity_bytes: u64,
	uniform_stream_bytes:    u64,
	uniform_capacity_bytes:  u64,
}

Config :: struct {
	width:         i32,
	height:        i32,
	title:         cstring,
	flags:         Window_Flags,
	frame_pacing:  Frame_Pacing,
	target_fps:    i32,
	event_waiting: bool,
	session:       Session_Config,
}

Draw_Proc :: #type proc(builder: ^Builder, ctx: rawptr)
Session_Draw_Proc :: #type proc(builder: ^Builder, ctx: rawptr)
Shutdown_Proc :: #type proc(app: ^App, ctx: rawptr)
Region_Build_Proc :: #type proc(region: ^Region, ctx: rawptr)
Layer_Build_Proc :: #type proc(surface: ^Surface, ctx: rawptr)
Pane_Build_Proc :: #type proc(surface: ^Surface, content_y: i32, ctx: rawptr) -> i32

Callbacks :: struct {
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
}

Track_Kind :: ui.Track_Kind
Track :: ui.Track
Space :: ui.Space
Cross_Align :: ui.Cross_Align
Main_Align :: ui.Main_Align
Text_Role :: ui.Text_Role
Truncate_Side :: ui.Truncate_Side
Ink :: ui.Ink
Button_Style :: ui.Btn_Style
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
Transition_State :: ui.Transition_Rect_State
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
	Null          = 0,
	Space         = 32,
	Apostrophe    = 39,
	Comma         = 44,
	Minus         = 45,
	Period        = 46,
	Slash         = 47,
	Zero          = 48,
	One           = 49,
	Two           = 50,
	Three         = 51,
	Four          = 52,
	Five          = 53,
	Six           = 54,
	Seven         = 55,
	Eight         = 56,
	Nine          = 57,
	Semicolon     = 59,
	Equal         = 61,
	A             = 65,
	B             = 66,
	C             = 67,
	D             = 68,
	E             = 69,
	F             = 70,
	G             = 71,
	H             = 72,
	I             = 73,
	J             = 74,
	K             = 75,
	L             = 76,
	M             = 77,
	N             = 78,
	O             = 79,
	P             = 80,
	Q             = 81,
	R             = 82,
	S             = 83,
	T             = 84,
	U             = 85,
	V             = 86,
	W             = 87,
	X             = 88,
	Y             = 89,
	Z             = 90,
	Left_Bracket  = 91,
	Backslash     = 92,
	Right_Bracket = 93,
	Grave         = 96,
	Escape        = 256,
	Enter         = 257,
	Tab           = 258,
	Backspace     = 259,
	Insert        = 260,
	Delete        = 261,
	Right         = 262,
	Left          = 263,
	Down          = 264,
	Up            = 265,
	Page_Up       = 266,
	Page_Down     = 267,
	Home          = 268,
	End           = 269,
	F1            = 290,
	F2            = 291,
	F3            = 292,
	F4            = 293,
	F5            = 294,
	F6            = 295,
	F7            = 296,
	F8            = 297,
	F9            = 298,
	F10           = 299,
	F11           = 300,
	F12           = 301,
	Keypad_Enter  = 335,
	Left_Shift    = 340,
	Left_Control  = 341,
	Left_Alt      = 342,
	Left_Super    = 343,
	Right_Shift   = 344,
	Right_Control = 345,
	Right_Alt     = 346,
	Right_Super   = 347,
}

Test_Input :: struct {
	mouse_position:  Point,
	mouse_delta:     Point,
	mouse_wheel:     Point,
	mouse_pressed:   [7]bool,
	mouse_released:  [7]bool,
	mouse_down:      [7]bool,
	keys_pressed:    [512]bool,
	keys_repeat:     [512]bool,
	keys_released:   [512]bool,
	keys_down:       [512]bool,
	characters:      [32]rune,
	character_count: int,
	clipboard:       [4096]u8,
	clipboard_len:   int,
	frame_time:      f32,
	time:            f64,
	dpi_scale:       f32,
	fps:             i32,
	monitor_refresh: i32,
	screen_size:     Point,
}

Mouse_Button :: enum i32 {
	Left,
	Right,
	Middle,
	Side,
	Extra,
	Forward,
	Back,
}
Cursor :: enum i32 {
	Default,
	Arrow,
	IBeam,
	Crosshair,
	Pointing_Hand,
	Resize_EW,
	Resize_NS,
	Resize_NWSE,
	Resize_NESW,
	Resize_All,
	Not_Allowed,
}
Interaction :: struct {
	hovered:  bool,
	pressed:  bool,
	held:     bool,
	released: bool,
	clicked:  bool,
}
Metrics :: struct {
	font_title:         i32,
	font_body:          i32,
	font_label:         i32,
	font_note:          i32,
	line_height:        i32,
	tab_bar_height:     i32,
	caption_button_w:   i32,
	padding:            i32,
	row_small:          i32,
	row_medium:         i32,
	panel_header_h:     i32,
	card_radius:        f32,
	control_box:        i32,
	control_gap:        i32,
	slider_track_h:     i32,
	slider_knob_radius: f32,
	menu_item_h:        i32,
	menu_padding:       i32,
	menu_min_w:         i32,
	tooltip_padding:    i32,
	code_block_padding: i32,
	bullet_indent:      i32,
	table_cell_padding: i32,
	split_divider_w:    i32,
}
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

Container_Surface :: struct {
	enabled:   bool,
	kind:      Surface_Kind,
	state:     Visual_State,
	radius:    Radius,
	border:    Border,
	elevation: Elevation,
}

Container_Effects :: struct {
	clip:         bool,
	background:   Color,
	radius:       Radius,
	border:       Border,
	border_color: Color,
	surface:      Container_Surface,
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

Section_Options :: struct {
	container: Container_Options,
	title:     Label_Options,
}

Card_Options :: struct {
	container: Container_Options,
	kind:      Surface_Kind,
	state:     Visual_State,
	radius:    Radius,
	border:    Border,
	elevation: Elevation,
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
	// activated is the advanced raw-output path. Render writes it after the
	// build callback returns, so it must outlive the build and render.
	activated:   ^bool,
	action:      Action,
}

Control_Options :: struct {
	track:   Track,
	size:    Size_Options,
	// changed follows the activated lifetime contract on Button_Options: it
	// is written during Render and must outlive the build callback.
	changed: ^bool,
}

Leaf_Options :: struct {
	track: Track,
	size:  Size_Options,
}

Builder_Text_Input_Options :: struct {
	height:    i32,
	masked:    bool,
	semantics: Text_Input_Semantics,
	track:     Track,
	size:      Size_Options,
	submitted: ^bool,
}

Progress_Options :: struct {
	height:   i32,
	ink:      Ink,
	label:    string,
	field_id: string,
	track:    Track,
	size:     Size_Options,
}

Custom_Options :: struct {
	track:     Track,
	size:      Size_Options,
	// activated follows the lifetime contract on Button_Options: it is
	// written during Render and must outlive the build callback.
	activated: ^bool,
}

Canvas_Options :: struct {
	intrinsic: Size,
	track:     Track,
	size:      Size_Options,
	activated: ^bool,
}

Surface :: struct {
	inner: ^ui.Ui,
}

Region :: struct {
	inner:         ui.Ui,
	managed_scope: bool,
}

Region_Options :: struct {
	gap:   Space,
	scope: string,
}

Test_Driver :: struct {
	inner: rawptr,
}

Pane_State :: struct {
	inner: ui.Pane,
}

Scroll_State :: struct {
	inner: ui.Prepared_Scroll_State,
}

Scroll_Options :: struct {
	padding:  Space,
	keyboard: bool,
	bar:      bool,
	track:    Track,
	size:     Size_Options,
}

Table_Header_Options :: struct {
	height: i32,
	track:  Track,
	size:   Size_Options,
}

Grid_State :: struct {
	inner:   ui.Grid,
	surface: ^Surface,
	open:    bool,
}

Layout_State :: struct {
	inner:   ui.Layout,
	surface: ^Surface,
	open:    bool,
}

Flow_State :: struct {
	inner:   ui.Flow_Layout,
	surface: ^Surface,
	open:    bool,
}

Fit_Column_State :: struct {
	inner:   ui.Fit_Column,
	surface: ^Surface,
	open:    bool,
}

Visible_Range :: struct {
	first: i32,
	end:   i32,
}

Measure_Proc :: #type proc(constraints: Constraints, ctx: rawptr) -> Size
Render_Proc :: #type proc(surface: ^Surface, rect: Rect, ctx: rawptr) -> bool

Custom_Spec :: struct {
	measure:   Measure_Proc,
	render:    Render_Proc,
	ctx:   rawptr,
	size:      Size_Options,
	intrinsic: Size,
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
