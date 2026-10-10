package ui

MAX_PREPARED_NODES_DEFAULT :: 128
MAX_PREPARED_NODES_HARD :: 8192
MAX_PREPARED_NODES :: #config(INGOT_PREPARED_NODE_CAP, MAX_PREPARED_NODES_DEFAULT)
#assert(MAX_PREPARED_NODES >= MAX_LAYOUT_DEPTH)
#assert(MAX_PREPARED_NODES <= MAX_PREPARED_NODES_HARD)

Prepared_Handle :: distinct i32
PREPARED_HANDLE_NONE :: Prepared_Handle(-1)

Prepared_Storage :: struct {
	nodes: []Prepared_Node,
}

Aspect_Ratio :: struct {
	width, height: i32,
}

Prepared_Transition :: struct {
	state:   ^Transition_Rect_State,
	options: Transition_Options,
}

Prepared_Size :: struct {
	width:      Track,
	height:     Track,
	aspect:     Aspect_Ratio,
	transition: Prepared_Transition,
}

Attachment_Target_Kind :: enum u8 {
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

Prepared_Attachment_Options :: struct {
	target_kind:       Attachment_Target_Kind,
	target:            Prepared_Handle,
	target_screen:     Rect_I32,
	target_point:      Attachment_Point,
	self_point:        Attachment_Point,
	offset_x:          i32,
	offset_y:          i32,
	z:                 Z_Order,
	claim:             bool,
	clamp_to_viewport: bool,
	transition:        Prepared_Transition,
}

Scroll_Axis :: enum u8 {
	Vertical,
	Horizontal,
}

Prepared_Scroll_State :: struct {
	offset:     f32,
	content_w:  i32,
	content_h:  i32,
	viewport_w: i32,
	viewport_h: i32,
	scrollbar:  Scrollbar_State,
}

Prepared_Scroll_Options :: struct {
	state:    ^Prepared_Scroll_State,
	id:       Widget_Id,
	padding:  Space,
	keyboard: bool,
	bar:      bool,
	axis:     Scroll_Axis,
	track:    Track,
	size:     Prepared_Size,
	focus:    Focus_Opt,
}

Prepared_Container_Surface :: struct {
	enabled:   bool,
	kind:      Surface,
	state:     Visual_State,
	radius:    Radius,
	border:    Border,
	elevation: Elevation,
}

Prepared_Container_Effects :: struct {
	clip:         bool,
	background:   Color,
	radius:       Radius,
	border:       Border,
	border_color: Color,
	surface:      Prepared_Container_Surface,
}

Prepared_Container_Options :: struct {
	gap:     Space,
	padding: Space,
	align:   Cross_Align,
	justify: Main_Align,
	track:   Track,
	size:    Prepared_Size,
	effects: Prepared_Container_Effects,
}

Prepared_Flow_Options :: struct {
	gap_x, gap_y: Space,
	padding:      Space,
	align:        Cross_Align,
	justify:      Main_Align,
	track:        Track,
	size:         Prepared_Size,
	effects:      Prepared_Container_Effects,
}

Prepared_Grid_Options :: struct {
	columns:       i32,
	row_height:    i32,
	column_tracks: []Track,
	row_tracks:    []Track,
	auto_flow:     Grid_Auto_Flow,
	gap_x, gap_y:  Space,
	padding:       Space,
	track:         Track,
	size:          Prepared_Size,
	effects:       Prepared_Container_Effects,
}

Prepared_Grid_Cell_Options :: struct {
	placement: Grid_Placement,
	align_x:   Cross_Align,
	align_y:   Cross_Align,
}

Label_Spec :: struct {
	text: string,
	role: Text_Role,
	ink:  Ink,
	wrap: bool,
}

Prepared_Label_Options :: struct {
	role: Text_Role,
	ink:  Ink,
	wrap: bool,
	size: Prepared_Size,
}

Prepared_Measure_Proc :: #type proc(
	u: ^Ui,
	constraints: Intrinsic_Constraints,
	userdata: rawptr,
) -> Intrinsic_Size

Prepared_Render_Proc :: #type proc(u: ^Ui, rect: Rect_I32, userdata: rawptr) -> bool

Prepared_Custom :: struct {
	measure:  Prepared_Measure_Proc,
	render:   Prepared_Render_Proc,
	userdata: rawptr,
	size:     Prepared_Size,
}

Prepared_Composite_Kind :: enum u8 {
	Toggle,
	Dropdown,
	Combobox,
	Tabs,
}

Prepared_Composite :: struct {
	kind:    Prepared_Composite_Kind,
	size:    Prepared_Size,
	using _: struct #raw_union {
		toggle:   Toggle_Spec,
		dropdown: Dropdown_Spec,
		combobox: Combobox_Spec,
		tabs:     Tabs_Spec,
	},
}

Prepared_Kind :: enum u8 {
	Row,
	Column,
	Flow,
	Grid,
	Grid_Cell,
	Attachment,
	Scroll,
	Label,
	Button,
	Checkbox,
	Radio,
	Slider,
	Text_Input,
	Progress,
	Separator,
	Spacer,
	Table_Cell,
	Composite,
	Custom,
}

Prepared_Measure_Flag :: enum u8 {
	Natural_Valid,
	Width_Dependent,
	Width_Valid,
}

Prepared_Measure_Flags :: bit_set[Prepared_Measure_Flag;u8]

Prepared_Node :: struct {
	kind:                     Prepared_Kind,
	parent, first_child:      i32,
	next_sibling, last_child: i32,
	child_count:              i32,
	track:                    Track,
	sizing:                   Prepared_Size,
	using _:                  struct #raw_union {
		container:  Prepared_Container_Options,
		flow:       Prepared_Flow_Options,
		grid:       Prepared_Grid_Options,
		grid_cell:  Prepared_Grid_Cell_Options,
		attachment: Prepared_Attachment_Options,
		scroll:     Prepared_Scroll_Options,
		label:      Label_Spec,
		button:     Button_Spec,
		checkbox:   Checkbox_Spec,
		radio:      Radio_Spec,
		slider:     Slider_Spec,
		text_input: Prepared_Text_Input,
		progress:   Prepared_Progress,
		spacer:     Prepared_Spacer,
		table_cell: Prepared_Table_Cell,
		composite:  Prepared_Composite,
		custom:     Prepared_Custom,
	},
	size:                     Intrinsic_Size,
	rect:                     Rect_I32,
	target_rect:              Rect_I32,
	measured_width:           i32,
	measure_flags:            Prepared_Measure_Flags,
	activation:               ^bool,
	activated:                bool,
	action:                   Fit_Action,
}

Prepared_Summary :: struct {
	leaf_count:        i32,
	container_count:   i32,
	maximum_depth:     i32,
	depends_on_width:  bool,
	depends_on_height: bool,
	explicit_sizing:   bool,
}

Prepared_Ui :: struct {
	nodes:           [MAX_PREPARED_NODES]Prepared_Node,
	external:        []Prepared_Node,
	stack:           [MAX_LAYOUT_DEPTH]i32,
	u:               ^Ui,
	count:           i32,
	depth:           i32,
	root:            i32,
	constraints:     Intrinsic_Constraints,
	summary:         Prepared_Summary,
	direct_geometry: bool,
	open:            bool,
	measured:        bool,
	rendered:        bool,
}

prepared_set_storage :: proc(prepared: ^Prepared_Ui, storage: Prepared_Storage) {
	assert(prepared != nil && !prepared.open, "prepared_set_storage: description open")
	assert(len(storage.nodes) >= MAX_LAYOUT_DEPTH, "prepared_set_storage: capacity too small")
	assert(
		len(storage.nodes) <= MAX_PREPARED_NODES_HARD,
		"prepared_set_storage: capacity too large",
	)
	prepared.external = storage.nodes
}

prepared_reset_storage :: proc(prepared: ^Prepared_Ui) {
	assert(prepared != nil && !prepared.open, "prepared_reset_storage: description open")
	assert(prepared.count >= 0, "prepared_reset_storage: invalid count")
	prepared.external = nil
}

prepared_capacity :: proc(prepared: ^Prepared_Ui) -> int {
	assert(prepared != nil, "prepared_capacity: nil description")
	assert(len(prepared_nodes(prepared)) >= MAX_LAYOUT_DEPTH, "prepared_capacity: invalid storage")
	return len(prepared_nodes(prepared))
}

@(private = "package")
prepared_nodes :: proc(prepared: ^Prepared_Ui) -> []Prepared_Node {
	assert(prepared != nil, "prepared_nodes: nil description")
	if prepared.external != nil do return prepared.external
	return prepared.nodes[:]
}

Prepared_Dependencies :: struct {
	width, height: bool,
}


Prepared_Render_Frame :: struct {
	index:      i32,
	next_child: i32,
}


@(private = "package")
prepared_kind_is_container :: proc(kind: Prepared_Kind) -> bool {
	return(
		kind == .Row ||
		kind == .Column ||
		kind == .Flow ||
		kind == .Grid ||
		kind == .Grid_Cell ||
		kind == .Attachment ||
		kind == .Scroll \
	)
}
