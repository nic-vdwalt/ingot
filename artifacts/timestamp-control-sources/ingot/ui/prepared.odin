package ui

import "core:fmt"

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

prepared_begin :: proc(prepared: ^Prepared_Ui, constraints: Intrinsic_Constraints = {}) {
	assert(prepared != nil, "prepared_begin: nil description")
	assert(!prepared.open, "prepared_begin: description already open")
	assert(constraints.min_w >= 0 && constraints.min_h >= 0, "prepared_begin: invalid minimum")
	assert(constraints.max_w == 0 || constraints.max_w >= constraints.min_w)
	assert(constraints.max_h == 0 || constraints.max_h >= constraints.min_h)
	prepared.u = nil
	nodes := prepared_nodes(prepared)
	assert(len(nodes) >= MAX_LAYOUT_DEPTH && len(nodes) <= MAX_PREPARED_NODES_HARD)
	assert(prepared.count >= 0 && prepared.count <= i32(len(nodes)))
	prepared.count = 0
	prepared.depth = 0
	prepared.root = -1
	prepared.constraints = constraints
	prepared.summary = {}
	prepared.direct_geometry = false
	prepared.open = true
	prepared.measured = false
	prepared.rendered = false
}

prepared_row_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Container_Options = {},
) -> Prepared_Handle {
	return prepared_container_begin(prepared, .Row, options)
}

prepared_column_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Container_Options = {},
) -> Prepared_Handle {
	return prepared_container_begin(prepared, .Column, options)
}

prepared_flow_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Flow_Options = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_flow_begin: description not open")
	handle := prepared_add(
		prepared,
		Prepared_Node{kind = .Flow, track = options.track, sizing = options.size, flow = options},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_grid_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Grid_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_grid_begin: description not open")
	assert(
		(options.columns > 0) != (len(options.column_tracks) > 0),
		"prepared_grid_begin: invalid columns",
	)
	assert(options.row_height >= 0, "prepared_grid_begin: invalid row height")
	assert(len(options.column_tracks) <= MAX_GRID_TRACKS, "prepared_grid_begin: too many columns")
	assert(len(options.row_tracks) <= MAX_GRID_TRACKS, "prepared_grid_begin: too many rows")
	handle := prepared_add(
		prepared,
		Prepared_Node{kind = .Grid, track = options.track, sizing = options.size, grid = options},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_grid_cell_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Grid_Cell_Options = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_grid_cell_begin: description not open")
	assert(options.placement.column >= -1 && options.placement.row >= -1)
	assert(options.placement.column_span >= 0 && options.placement.row_span >= 0)
	handle := prepared_add(prepared, Prepared_Node{kind = .Grid_Cell, grid_cell = options})
	prepared_push_container(prepared, handle)
	return handle
}

prepared_attachment_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Attachment_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_attachment_begin: description not open")
	assert(prepared.depth > 0, "prepared_attachment_begin: attachment cannot be root")
	assert(options.z == options.z && options.z > Z_CONTENT, "prepared_attachment_begin: invalid z")
	if options.target_kind == .Handle {
		target := i32(options.target)
		assert(target >= 0 && target < prepared.count, "prepared_attachment_begin: invalid target")
	}
	handle := prepared_add(prepared, Prepared_Node{kind = .Attachment, attachment = options})
	prepared_push_container(prepared, handle)
	return handle
}

prepared_scroll_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Scroll_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_scroll_begin: description not open")
	assert(options.state != nil, "prepared_scroll_begin: nil state")
	assert(options.id != WIDGET_ID_NONE, "prepared_scroll_begin: invalid id")
	handle := prepared_add(
		prepared,
		Prepared_Node {
			kind = .Scroll,
			scroll = options,
			track = options.track,
			sizing = options.size,
		},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_row :: proc(u: ^Ui, prepared: ^Prepared_Ui, options: Prepared_Container_Options = {}) {
	assert(u != nil && prepared != nil, "prepared_row: invalid argument")
	prepared_root_begin(u, prepared, .Row, options)
}

prepared_column :: proc(u: ^Ui, prepared: ^Prepared_Ui, options: Prepared_Container_Options = {}) {
	assert(u != nil && prepared != nil, "prepared_column: invalid argument")
	prepared_root_begin(u, prepared, .Column, options)
}

prepared_end :: proc(prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(prepared != nil && prepared.open, "prepared_end: description not open")
	assert(prepared.u != nil && prepared.u.open, "prepared_end: invalid bound UI")
	assert(prepared.depth == 1, "prepared_end: nested container still open")
	prepared_container_end(prepared)
	return prepared_fit(prepared.u, prepared)
}

prepared_container_end :: proc(prepared: ^Prepared_Ui) {
	assert(prepared != nil && prepared.open, "prepared_container_end: description not open")
	assert(
		prepared.depth > 0 && prepared.depth <= MAX_LAYOUT_DEPTH,
		"prepared_container_end: no container",
	)
	stack_index := prepared.depth - 1
	assert(stack_index >= 0 && stack_index < len(prepared.stack))
	index := prepared.stack[stack_index]
	assert(index >= 0 && index < prepared.count, "prepared_container_end: invalid index")
	kind := prepared_nodes(prepared)[index].kind
	if kind == .Attachment || kind == .Scroll || kind == .Grid_Cell {
		assert(index >= 0 && index < i32(len(prepared_nodes(prepared))))
		assert(prepared_child_count(prepared, prepared_nodes(prepared)[index].first_child) == 1)
	}
	if kind == .Grid_Cell {
		parent := prepared_nodes(prepared)[index].parent
		assert(parent >= 0 && prepared_nodes(prepared)[parent].kind == .Grid)
	}
	prepared.depth -= 1
}

@(private = "package")
prepared_label_spec :: proc(
	prepared: ^Prepared_Ui,
	spec: Label_Spec,
	track: Track = {},
	sizing: Prepared_Size = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_label_spec: description not open")
	assert(spec.text != "", "prepared_label_spec: empty text")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Label, label = spec, track = track, sizing = sizing},
	)
}

@(private = "package")
prepared_label_text :: proc(
	prepared: ^Prepared_Ui,
	text: string,
	options: Prepared_Label_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_label_text: description not open")
	assert(text != "", "prepared_label_text: empty text")
	return prepared_label_spec(
		prepared,
		{text = text, role = options.role, ink = options.ink, wrap = options.wrap},
		track,
		options.size,
	)
}

prepared_label :: proc {
	prepared_label_spec,
	prepared_label_text,
}

@(private = "package")
prepared_button_spec :: proc(
	prepared: ^Prepared_Ui,
	spec: Button_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_button_spec: description not open")
	assert(spec.id != WIDGET_ID_NONE, "prepared_button_spec: zero stable id")
	assert(spec.label != "", "prepared_button_spec: empty label")
	return prepared_add(prepared, Prepared_Node{kind = .Button, button = spec, track = track})
}

@(private = "package")
prepared_button_id :: proc(
	prepared: ^Prepared_Ui,
	widget: Widget_Id,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_button_id: description not open")
	assert(widget != WIDGET_ID_NONE && label != "", "prepared_button_id: invalid button")
	return prepared_button_spec(prepared, button_spec(prepared.u, widget, label, options), track)
}

@(private = "package")
prepared_button_string :: proc(
	prepared: ^Prepared_Ui,
	key: string,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.u != nil, "prepared_button_string: UI not bound")
	assert(key != "" && label != "", "prepared_button_string: invalid button")
	return prepared_button_id(prepared, id(prepared.u, key), label, options, track)
}

@(private = "package")
prepared_button_u64 :: proc(
	prepared: ^Prepared_Ui,
	key: u64,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.u != nil, "prepared_button_u64: UI not bound")
	assert(label != "", "prepared_button_u64: empty label")
	return prepared_button_id(prepared, id(prepared.u, key), label, options, track)
}

prepared_button :: proc {
	prepared_button_spec,
	prepared_button_id,
	prepared_button_string,
	prepared_button_u64,
}

prepared_checkbox :: proc(
	prepared: ^Prepared_Ui,
	spec: Checkbox_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_checkbox: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "" && spec.checked != nil)
	return prepared_add(prepared, Prepared_Node{kind = .Checkbox, checkbox = spec, track = track})
}

prepared_radio :: proc(
	prepared: ^Prepared_Ui,
	spec: Radio_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_radio: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "" && spec.selected != nil)
	return prepared_add(prepared, Prepared_Node{kind = .Radio, radio = spec, track = track})
}

prepared_slider :: proc(
	prepared: ^Prepared_Ui,
	spec: Slider_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_slider: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.value != nil && spec.maximum > spec.minimum)
	assert(spec.step >= 0 && spec.a11y_label != "", "prepared_slider: invalid spec")
	return prepared_add(prepared, Prepared_Node{kind = .Slider, slider = spec, track = track})
}

prepared_text_input :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Text_Input,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_text_input: description not open")
	assert(
		spec.id != WIDGET_ID_NONE && prepared_text_input_source_ok(spec),
		"prepared_text_input: invalid spec",
	)
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Text_Input, text_input = spec, track = track},
	)
}

prepared_progress :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Progress,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_progress: description not open")
	assert(spec.value >= 0 && spec.value <= 1, "prepared_progress: invalid value")
	return prepared_add(prepared, Prepared_Node{kind = .Progress, progress = spec, track = track})
}

prepared_separator :: proc(prepared: ^Prepared_Ui, track: Track = {}) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_separator: description not open")
	return prepared_add(prepared, Prepared_Node{kind = .Separator, track = track})
}

prepared_spacer :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Spacer,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_spacer: description not open")
	return prepared_add(prepared, Prepared_Node{kind = .Spacer, spacer = spec, track = track})
}

prepared_table_cell :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Table_Cell,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_table_cell: description not open")
	assert(spec.text != "", "prepared_table_cell: empty text")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Table_Cell, table_cell = spec, track = track},
	)
}

prepared_composite :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Composite,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_composite: description not open")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Composite, composite = spec, track = track, sizing = spec.size},
	)
}

prepared_composite_size :: proc(
	u: ^Ui,
	spec: Prepared_Composite,
	max_width: i32,
) -> Intrinsic_Size {
	assert(u != nil && u.open && max_width >= 0, "prepared composite size: invalid argument")
	switch spec.kind {
	case .Toggle:
		return toggle_spec_size(u, spec.toggle)
	case .Dropdown:
		return dropdown_spec_size(u, spec.dropdown)
	case .Combobox:
		return combobox_spec_size(u, spec.combobox)
	case .Tabs:
		return tabs_spec_size(u, spec.tabs)
	}
	unreachable()
}

prepared_composite_at :: proc(u: ^Ui, spec: Prepared_Composite, rect: Rect_I32) -> bool {
	assert(u != nil && u.open, "prepared composite render: invalid UI")
	switch spec.kind {
	case .Toggle:
		return toggle_spec_at(u, spec.toggle, rect)
	case .Dropdown:
		return dropdown_spec_at(u, spec.dropdown, rect)
	case .Combobox:
		return combobox_spec_at(u, spec.combobox, rect)
	case .Tabs:
		return tabs_spec_at(u, spec.tabs, rect)
	}
	unreachable()
}

prepared_custom :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Custom,
	track: Track = {},
) -> Prepared_Handle {
	assert(spec.measure != nil, "prepared_custom: nil measure procedure")
	assert(spec.render != nil, "prepared_custom: nil render procedure")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Custom, custom = spec, track = track, sizing = spec.size},
	)
}

prepared_measure :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared_measure: invalid UI")
	assert(prepared != nil && prepared.open, "prepared_measure: description not open")
	assert(prepared.depth == 0 && prepared.count > 0, "prepared_measure: unbalanced or empty tree")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_measure: invalid root")
	prepared_telemetry_describe(u.frame, prepared)
	if prepared_direct_grid_measure(u, prepared) do return prepared_nodes(prepared)[prepared.root].size
	natural_started := prepared_phase_begin(u.frame, .Measure_Natural)
	prepared_measure_natural(u, prepared)
	prepared_phase_end(u.frame, .Measure_Natural, natural_started)
	root := &prepared_nodes(prepared)[prepared.root]
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	dependencies := Prepared_Dependencies {
		width  = prepared.summary.depends_on_width,
		height = prepared.summary.depends_on_height,
	}
	if dependencies.width {
		assert(
			prepared.constraints.max_w > 0,
			"prepared_measure: dependent track needs finite width",
		)
		root.size.w = prepared.constraints.max_w
	}
	if dependencies.height {
		assert(
			prepared.constraints.max_h > 0,
			"prepared_measure: dependent track needs finite height",
		)
		root.size.h = prepared.constraints.max_h
	}
	resolve_started := prepared_phase_begin(u.frame, .Resolve_Size)
	if prepared.summary.explicit_sizing {
		prepared_resolve_sizes(u, prepared)
		prepared_remeasure_containers(u, prepared)
	}
	prepared_phase_end(u.frame, .Resolve_Size, resolve_started)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	resolved_started := prepared_phase_begin(u.frame, .Measure_Resolved)
	prepared_assign_widths(u, prepared)
	prepared_measure_heights(u, prepared)
	prepared_phase_end(u.frame, .Measure_Resolved, resolved_started)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	assert(!root.size.overflow, "prepared_measure: intrinsic overflow")
	prepared.measured = true
	prepared.rendered = false
	return root.size
}

prepared_render_at :: proc(u: ^Ui, prepared: ^Prepared_Ui, rect: Rect_I32) {
	assert(u != nil && u.open && u.frame != nil, "prepared_render_at: invalid UI")
	assert(prepared != nil && prepared.measured, "prepared_render_at: description not measured")
	assert(!prepared.rendered && rect.w >= 0 && rect.h >= 0, "prepared_render_at: invalid render")
	assert(prepared.root >= 0, "prepared_render_at: negative root")
	assert(
		prepared.root < i32(prepared_capacity(prepared)),
		"prepared_render_at: root out of bounds",
	)
	assert(prepared.root < prepared.count, "prepared_render_at: root beyond count")
	root := &prepared_nodes(prepared)[prepared.root]
	if root.size.w > rect.w || root.size.h > rect.h {
		ui_frame_record_layout_overflow(u.frame)
	}
	if root.size.w != rect.w || root.size.h != rect.h {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.render_relayouts += 1
		root.size.w = rect.w
		root.size.h = rect.h
		root.rect = rect
		// The render rect is the authoritative bound: re-resolve explicit
		// tracks against it so Grow and Percent land identically no matter
		// what constraints the measure pass ran under. Rendering the same
		// tree at the same rect must produce the same layout (pass
		// idempotence); skipping the height half of this left Grow-height
		// children at their stale measure-time resolution whenever only the
		// height changed, collapsing them to their natural floor.
		prepared.constraints = intrinsic_constraints(max_w = rect.w, max_h = rect.h)
		if prepared.summary.explicit_sizing {
			prepared_resolve_sizes(u, prepared)
			prepared_remeasure_containers(u, prepared)
			root.size = intrinsic_constrain(root.size, prepared.constraints)
		}
		prepared_assign_widths(u, prepared)
		prepared_measure_heights(u, prepared)
	}
	root.rect = rect
	place_started := prepared_phase_begin(u.frame, .Place)
	if prepared.direct_geometry {
		prepared_direct_grid_place(u, prepared)
		root.target_rect = root.rect
	} else {
		prepared_place(u, prepared)
	}
	prepared_phase_end(u.frame, .Place, place_started)
	render_started := prepared_phase_begin(u.frame, .Render_Tree)
	prepared_render_tree(u, prepared)
	prepared_phase_end(u.frame, .Render_Tree, render_started)
	prepared.rendered = true
	prepared.open = false
}

prepared_fit :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(u != nil && u.open, "prepared_fit: frame not open")
	assert(prepared != nil && prepared.open, "prepared_fit: description not open")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_fit: invalid root")
	size := prepared_nodes(prepared)[prepared.root].size
	if !prepared.measured do size = prepared_measure(u, prepared)
	assert(size.w >= 0 && size.h >= 0 && !size.overflow, "prepared_fit: invalid size")
	rect := slot_next_px(u, size.w, size.h)
	prepared_render_at(u, prepared, rect)
	return rect
}

prepared_activated :: proc(prepared: ^Prepared_Ui, handle: Prepared_Handle) -> bool {
	assert(prepared != nil && prepared.rendered, "prepared_activated: description not rendered")
	index := i32(handle)
	assert(index >= 0 && index < prepared.count, "prepared_activated: handle out of range")
	return prepared_nodes(prepared)[index].activated
}

@(private = "file")
prepared_root_begin :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) {
	assert(u != nil && u.open && u.frame != nil, "prepared_root_begin: invalid UI")
	assert(prepared != nil && !prepared.open, "prepared_root_begin: description already open")
	assert(kind == .Row || kind == .Column, "prepared_root_begin: invalid kind")
	prepared_begin(prepared, intrinsic_constraints(max_w = remaining_rect(u).w))
	prepared.u = u
	_ = prepared_container_begin(prepared, kind, options)
}

@(private = "file")
prepared_container_begin :: proc(
	prepared: ^Prepared_Ui,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_container_begin: description not open")
	assert(kind == .Row || kind == .Column, "prepared_container_begin: invalid kind")
	assert(prepared.depth < MAX_LAYOUT_DEPTH, "prepared_container_begin: depth out of bounds")
	handle := prepared_add(
		prepared,
		Prepared_Node {
			kind = kind,
			container = options,
			track = options.track,
			sizing = options.size,
		},
	)
	prepared_push_container(prepared, handle)
	return handle
}

@(private = "file")
prepared_push_container :: proc(prepared: ^Prepared_Ui, handle: Prepared_Handle) {
	assert(prepared != nil && prepared.open, "prepared_push_container: description not open")
	assert(prepared.depth < MAX_LAYOUT_DEPTH, "prepared_push_container: depth out of bounds")
	index := i32(handle)
	assert(index >= 0 && index < prepared.count, "prepared_push_container: invalid handle")
	prepared.stack[prepared.depth] = index
	prepared.depth += 1
}

@(private = "file")
prepared_add :: proc(prepared: ^Prepared_Ui, node: Prepared_Node) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_add: description not open")
	assert(
		prepared.depth >= 0 && prepared.depth <= len(prepared.stack),
		"prepared_add: invalid depth",
	)
	parent := i32(-1)
	if prepared.depth > 0 do parent = prepared.stack[prepared.depth - 1]
	return prepared_add_to(prepared, parent, node)
}

prepared_add_to :: proc(
	prepared: ^Prepared_Ui,
	parent_index: i32,
	node: Prepared_Node,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_add_to: description not open")
	nodes := prepared_nodes(prepared)
	when !ODIN_DISABLE_ASSERT {
		if prepared.count < 0 || prepared.count >= i32(len(nodes)) {
			buffer: [256]u8
			message := fmt.bprintf(
				buffer[:],
				"prepared_add_to: nodes full (parent=%d count=%d capacity=%d)",
				parent_index,
				prepared.count,
				len(nodes),
			)
			assert(prepared.count >= 0 && prepared.count < i32(len(nodes)), message)
		}
	}
	index := prepared.count
	assert(parent_index >= -1 && parent_index < index, "prepared_add_to: invalid parent")
	value := node
	value.parent = parent_index
	value.first_child = -1
	value.next_sibling = -1
	value.last_child = -1
	value.child_count = 0
	depth := i32(1)
	if parent_index >= 0 {
		parent := &nodes[parent_index]
		assert(prepared_kind_is_container(parent.kind), "prepared_add_to: parent is not container")
		limit := i32(MAX_LAYOUT_FLEX)
		if parent.kind == .Flow || parent.kind == .Grid {
			limit = min(i32(len(nodes) - 1), i32(MAX_GRID_CELLS))
		}
		if parent.kind == .Attachment || parent.kind == .Scroll || parent.kind == .Grid_Cell {
			limit = 1
		}
		assert(parent.child_count < limit, "prepared_add_to: children full")
		if parent.first_child < 0 {
			parent.first_child = index
		} else {
			assert(
				parent.last_child >= 0 && parent.last_child < index,
				"prepared_add_to: invalid sibling",
			)
			nodes[parent.last_child].next_sibling = index
		}
		parent.last_child = index
		parent.child_count += 1
		ancestor := parent_index
		for ancestor >= 0 {
			assert(depth < MAX_LAYOUT_DEPTH, "prepared_add_to: depth full")
			ancestor = nodes[ancestor].parent
			depth += 1
		}
	} else {
		assert(prepared.root < 0, "prepared_add_to: multiple roots")
		prepared.root = index
	}
	nodes[index] = value
	prepared.count += 1
	prepared.summary.depends_on_width ||= prepared_axis_dependent(value.sizing.width)
	prepared.summary.depends_on_height ||= prepared_axis_dependent(value.sizing.height)
	prepared.summary.explicit_sizing ||=
		prepared_axis_explicit(value.sizing.width) ||
		prepared_axis_explicit(value.sizing.height) ||
		value.sizing.aspect.width > 0
	if value.kind == .Flow || value.kind == .Grid || value.kind == .Scroll {
		prepared.summary.depends_on_width = true
	}
	if value.parent >= 0 {
		parent_kind := nodes[value.parent].kind
		track_dependent := value.track.kind == .Grow || value.track.kind == .Percent
		if parent_kind == .Row do prepared.summary.depends_on_width ||= track_dependent
		if parent_kind == .Column do prepared.summary.depends_on_height ||= track_dependent
	}
	if prepared_kind_is_container(value.kind) {
		prepared.summary.container_count += 1
	} else {
		prepared.summary.leaf_count += 1
	}
	prepared.summary.maximum_depth = max(prepared.summary.maximum_depth, depth)
	assert(prepared.summary.leaf_count + prepared.summary.container_count == prepared.count)
	return Prepared_Handle(index)
}

@(private = "file")
prepared_telemetry_describe :: proc(frame: ^Ui_Frame, prepared: ^Prepared_Ui) {
	assert(frame != nil && prepared != nil, "prepared telemetry: invalid argument")
	assert(prepared.count > 0, "prepared telemetry: empty description")
	when UI_TELEMETRY_ENABLED {
		telemetry := &frame.prepared_telemetry
		telemetry.description_nodes = u64(prepared.count)
		telemetry.leaf_nodes = u64(prepared.summary.leaf_count)
		telemetry.container_nodes = u64(prepared.summary.container_count)
		telemetry.maximum_depth = u64(prepared.summary.maximum_depth)
		telemetry.fixed_leaf_nodes = 0
		telemetry.intrinsic_leaf_nodes = 0
		telemetry.width_dependent_leaf_nodes = 0
		for index in 0 ..< prepared.count {
			node := &prepared_nodes(prepared)[index]
			if prepared_kind_is_container(node.kind) do continue
			if prepared_leaf_size_is_fixed(node) {
				telemetry.fixed_leaf_nodes += 1
			} else {
				telemetry.intrinsic_leaf_nodes += 1
			}
			if prepared_leaf_width_dependent(node) {
				telemetry.width_dependent_leaf_nodes += 1
			}
		}
		assert(telemetry.leaf_nodes == telemetry.fixed_leaf_nodes + telemetry.intrinsic_leaf_nodes)
	}
}

@(private = "file")
prepared_direct_grid_measure :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> bool {
	assert(u != nil && prepared != nil, "prepared direct grid: invalid argument")
	if !prepared_direct_grid_eligible(prepared) do return false
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		if prepared_kind_is_container(node.kind) do continue
		node.size.w = prepared_axis_size(u, node.sizing.width, 0, prepared.constraints.max_w)
		node.size.h = prepared_axis_size(u, node.sizing.height, 0, prepared.constraints.max_h)
		node.measure_flags += {.Width_Valid}
	}
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row do prepared_measure_container(u, prepared, index, false)
	}
	root := &prepared_nodes(prepared)[prepared.root]
	prepared_measure_grid(u, prepared, prepared.root, false)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	prepared.direct_geometry = true
	prepared.measured = true
	prepared.rendered = false
	when UI_TELEMETRY_ENABLED {
		u.frame.prepared_telemetry.fixed_leaf_measure_skips += u64(prepared.summary.leaf_count)
		u.frame.prepared_telemetry.specialized_nodes += u64(prepared.count)
	}
	return true
}

@(private = "file")
prepared_direct_grid_eligible :: proc(prepared: ^Prepared_Ui) -> bool {
	assert(prepared != nil && prepared.root >= 0, "prepared direct grid: invalid description")
	root := &prepared_nodes(prepared)[prepared.root]
	if root.kind != .Grid || root.grid.row_height <= 0 do return false
	if len(root.grid.column_tracks) > 0 || len(root.grid.row_tracks) > 0 do return false
	if root.grid.effects != (Prepared_Container_Effects{}) do return false
	if root.sizing != (Prepared_Size{}) do return false
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row {
			if node.parent != prepared.root ||
			   node.container.effects != (Prepared_Container_Effects{}) {
				return false
			}
			if node.sizing.aspect.width != 0 || node.sizing.transition.state != nil do return false
			continue
		}
		if prepared_kind_is_container(node.kind) || !prepared_leaf_size_is_fixed(node) do return false
		parent := &prepared_nodes(prepared)[node.parent]
		if parent.kind != .Grid && parent.kind != .Row do return false
		if node.sizing.aspect.width != 0 || node.sizing.transition.state != nil do return false
	}
	return true
}

@(private = "file")
prepared_direct_grid_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared direct place: invalid argument")
	assert(prepared.direct_geometry, "prepared direct place: generic description")
	prepared_place_grid(u, prepared, prepared.root)
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		node.target_rect = node.rect
		if node.kind == .Row do prepared_place_children(u, prepared, index, false)
	}
}

prepared_measure_natural :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_natural: invalid argument")
	assert(prepared.count > 0 && prepared.count <= i32(prepared_capacity(prepared)))
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.natural_node_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, false)
		} else if prepared_kind_is_container(node.kind) {
			prepared_measure_container(u, prepared, index, false)
		} else {
			if prepared_leaf_width_dependent(node) {
				node.measure_flags += {.Width_Dependent}
			}
			if prepared_leaf_size_is_fixed(node) {
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.fixed_leaf_measure_skips += 1
			} else if prepared_leaf_needs_natural(prepared, index) {
				prepared_measure_leaf(u, node, 0)
				node.measure_flags += {.Natural_Valid}
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.natural_leaf_measures += 1
			}
		}
	}
}

@(private = "file")
prepared_leaf_needs_natural :: proc(prepared: ^Prepared_Ui, index: i32) -> bool {
	assert(prepared != nil && index >= 0, "prepared natural leaf: invalid argument")
	assert(index < prepared.count, "prepared natural leaf: index out of range")
	node := &prepared_nodes(prepared)[index]
	assert(!prepared_kind_is_container(node.kind), "prepared natural leaf: container")
	if node.parent < 0 do return true
	assert(node.parent < index, "prepared natural leaf: invalid parent")
	parent := &prepared_nodes(prepared)[node.parent]
	return parent.kind != .Grid || parent.grid.row_height <= 0
}

@(private = "file")
prepared_axis_is_fixed :: proc(track: Track) -> bool {
	return track.kind == .Fixed || (track.kind == .Fit && track.basis > 0)
}

@(private = "file")
prepared_leaf_size_is_fixed :: proc(node: ^Prepared_Node) -> bool {
	assert(node != nil, "prepared fixed leaf: nil node")
	assert(!prepared_kind_is_container(node.kind), "prepared fixed leaf: container")
	return prepared_axis_is_fixed(node.sizing.width) && prepared_axis_is_fixed(node.sizing.height)
}

@(private = "file")
prepared_leaf_width_dependent :: proc(node: ^Prepared_Node) -> bool {
	assert(node != nil, "prepared leaf dependency: nil node")
	assert(!prepared_kind_is_container(node.kind), "prepared leaf dependency: container")
	return (node.kind == .Label && node.label.wrap) || node.kind == .Custom
}

@(private = "file")
prepared_leaf_needs_width_measure :: proc(node: ^Prepared_Node, width: i32) -> bool {
	assert(node != nil, "prepared leaf measure: nil node")
	assert(width >= 0, "prepared leaf measure: negative width")
	if prepared_leaf_size_is_fixed(node) do return false
	if .Natural_Valid not_in node.measure_flags do return true
	if .Width_Dependent not_in node.measure_flags do return false
	return .Width_Valid not_in node.measure_flags || node.measured_width != width
}

@(private = "file")
prepared_measure_leaf :: proc(u: ^Ui, node: ^Prepared_Node, max_width: i32) {
	assert(u != nil && node != nil, "prepared_measure_leaf: invalid argument")
	assert(max_width >= 0, "prepared_measure_leaf: negative width")
	switch node.kind {
	case .Label:
		if node.label.wrap && max_width > 0 {
			font_size := text_role_size(u.frame, node.label.role)
			line_height := text_role_line_height(u.frame, node.label.role)
			node.size = intrinsic_leaf(
				wrapped_max_line_width_frame(u.frame, node.label.text, max_width, font_size),
				wrapped_height_px_frame(
					u.frame,
					node.label.text,
					max_width,
					font_size,
					line_height,
				),
			)
		} else {
			node.size = intrinsic_text(u, node.label.text, node.label.role)
		}
	case .Button:
		node.size = button_spec_size(u, node.button)
	case .Checkbox:
		node.size = checkbox_spec_size(u, node.checkbox)
	case .Radio:
		node.size = radio_spec_size(u, node.radio)
	case .Slider:
		node.size = slider_spec_size(u, node.slider)
	case .Text_Input:
		node.size = prepared_text_input_size(u, node.text_input)
	case .Progress:
		node.size = prepared_progress_size(u, node.progress)
	case .Separator:
		node.size = prepared_separator_size(u)
	case .Spacer:
		node.size = prepared_spacer_size(u, node.spacer)
	case .Table_Cell:
		node.size = prepared_table_cell_size(u, node.table_cell)
	case .Composite:
		node.size = prepared_composite_size(u, node.composite, max_width)
	case .Custom:
		node.size = node.custom.measure(u, {max_w = max_width}, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Grid_Cell, .Attachment, .Scroll:
		unreachable()
	}
	assert(node.size.w >= 0 && node.size.h >= 0, "prepared_measure_leaf: invalid result")
}

@(private = "file")
prepared_measure_attachment :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Attachment, "prepared_measure_attachment: wrong kind")
	assert(node.first_child >= 0 && node.first_child == node.last_child)
	node.size = prepared_nodes(prepared)[node.first_child].size
}

@(private = "file")
prepared_measure_grid_cell :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Grid_Cell, "prepared_measure_grid_cell: wrong kind")
	assert(node.first_child >= 0 && node.first_child == node.last_child)
	node.size = prepared_nodes(prepared)[node.first_child].size
}

prepared_measure_scroll :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Scroll && node.scroll.state != nil, "prepared scroll: invalid node")
	assert(
		node.first_child >= 0 && node.first_child == node.last_child,
		"prepared scroll: child count",
	)
	child := &prepared_nodes(prepared)[node.first_child]
	padding := insets_of(u, node.scroll.padding)
	node.scroll.state.content_w = child.size.w + padding.left + padding.right
	node.scroll.state.content_h = child.size.h + padding.top + padding.bottom
	node.size = intrinsic_padding(child.size, padding)
	if keep_width && node.rect.w > 0 do node.size.w = node.rect.w
}

@(private = "file")
prepared_measure_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_container: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_container: index out of range")
	node := &prepared_nodes(prepared)[index]
	children: [MAX_LAYOUT_FLEX]Intrinsic_Size
	count: i32
	child := node.first_child
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		if child < 0 do break
		assert(
			child < prepared.count && count < MAX_LAYOUT_FLEX,
			"prepared_measure_container: bad child",
		)
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			children[count] = value.size
			count += 1
		}
		child = value.next_sibling
	}
	assert(child < 0, "prepared_measure_container: too many children")
	gap := space_px(u, node.container.gap)
	size := intrinsic_row(children[:count], gap)
	if node.kind == .Column do size = intrinsic_column(children[:count], gap)
	size = intrinsic_padding(size, insets_of(u, node.container.padding))
	if keep_width && node.rect.w > 0 do size.w = node.rect.w
	node.size = size
}

@(private = "file")
prepared_measure_flow :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_flow: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_flow: index out of range")
	node := &prepared_nodes(prepared)[index]
	padding := insets_of(u, node.flow.padding)
	max_width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do max_width = node.rect.w
	assert(max_width > 0, "prepared_measure_flow: finite width required")
	content_w := max(max_width - padding.left - padding.right, 0)
	flow: Flow_Layout
	flow_begin(&flow, {w = content_w}, space_px(u, node.flow.gap_x), space_px(u, node.flow.gap_y))
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_measure_flow: child out of range")
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment do _ = flow_next(&flow, value.size.w, value.size.h)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_measure_flow: child bound")
	content := flow_end(&flow)
	node.size = intrinsic_padding(intrinsic_leaf(content.w, content.h), padding)
	if keep_width do node.size.w = max_width
}

@(private = "file")
prepared_measure_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_grid: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_grid: index out of range")
	node := &prepared_nodes(prepared)[index]
	padding := insets_of(u, node.grid.padding)
	width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do width = node.rect.w
	assert(width > 0, "prepared_measure_grid: finite width required")
	if len(node.grid.column_tracks) == 0 {
		assert(node.grid.columns > 0, "prepared_measure_grid: invalid columns")
		count := prepared_in_flow_child_count(prepared, node.first_child)
		rows := (count + node.grid.columns - 1) / node.grid.columns
		gap_y := space_px(u, node.grid.gap_y)
		row_h := ui_frame_sc(u.frame, node.grid.row_height)
		content_h := rows * row_h + max(rows - 1, 0) * gap_y
		content_w := max(width - padding.left - padding.right, 0)
		node.size = intrinsic_padding(intrinsic_leaf(content_w, content_h), padding)
		return
	}
	rows := len(node.grid.row_tracks)
	if rows == 0 {
		count := prepared_in_flow_child_count(prepared, node.first_child)
		rows = int(
			(count + i32(len(node.grid.column_tracks)) - 1) / i32(len(node.grid.column_tracks)),
		)
	}
	row_h := ui_frame_sc(u.frame, node.grid.row_height)
	content_h := i32(rows) * row_h + max(i32(rows) - 1, 0) * space_px(u, node.grid.gap_y)
	if len(node.grid.row_tracks) > 0 {
		row_tracks: [MAX_GRID_TRACKS]Track
		row_sizes: [MAX_GRID_TRACKS]i32
		for track, track_index in node.grid.row_tracks {
			row_tracks[track_index] = prepared_scale_track(u, track)
		}
		result := track_resolve(
			row_tracks[:rows],
			prepared.constraints.max_h,
			space_px(u, node.grid.gap_y),
			row_sizes[:],
		)
		content_h = result.used
	}
	node.size = intrinsic_padding(
		intrinsic_leaf(width - padding.left - padding.right, content_h),
		padding,
	)
}

@(private = "file")
prepared_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		assert(count >= 0 && count < prepared.count, "prepared_child_count: corrupt count")
		if child < 0 do break
		assert(child < prepared.count, "prepared_child_count: child out of range")
		count += 1
		child = prepared_nodes(prepared)[child].next_sibling
	}
	assert(child < 0, "prepared_child_count: child bound")
	return count
}

@(private = "file")
prepared_in_flow_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_in_flow_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_in_flow_child_count: child out of range")
		if prepared_nodes(prepared)[child].kind != .Attachment do count += 1
		child = prepared_nodes(prepared)[child].next_sibling
	}
	assert(child < 0 && count >= 0, "prepared_in_flow_child_count: child bound")
	return count
}

Prepared_Dependencies :: struct {
	width, height: bool,
}

@(private = "file")
prepared_dependencies :: proc(prepared: ^Prepared_Ui) -> Prepared_Dependencies {
	assert(prepared != nil, "prepared_dependencies: nil description")
	assert(
		prepared.count > 0 && prepared.count <= i32(prepared_capacity(prepared)),
		"prepared_dependencies: invalid count",
	)
	result: Prepared_Dependencies
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do prepared.u.frame.prepared_telemetry.dependency_node_visits += 1
		node := prepared_nodes(prepared)[index]
		result.width = result.width || prepared_axis_dependent(node.sizing.width)
		result.height = result.height || prepared_axis_dependent(node.sizing.height)
		if node.kind == .Flow || node.kind == .Grid || node.kind == .Scroll do result.width = true
		child := node.first_child
		for _ in 0 ..< prepared.count {
			if child < 0 do break
			when UI_TELEMETRY_ENABLED do prepared.u.frame.prepared_telemetry.dependency_child_visits += 1
			assert(child < prepared.count, "prepared_dependencies: child out of range")
			track := prepared_nodes(prepared)[child].track
			dependent := track.kind == .Grow || track.kind == .Percent
			if node.kind == .Row do result.width = result.width || dependent
			if node.kind == .Column do result.height = result.height || dependent
			child = prepared_nodes(prepared)[child].next_sibling
		}
		assert(child < 0, "prepared_dependencies: child bound")
	}
	return result
}

@(private = "file")
prepared_axis_dependent :: proc(track: Track) -> bool {
	return track.kind == .Grow || track.kind == .Percent
}

@(private = "file")
prepared_resolve_sizes :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_resolve_sizes: invalid argument")
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolve_node_visits += 1
		prepared_resolve_node_size(u, prepared, &prepared_nodes(prepared)[index])
	}
}

@(private = "file")
prepared_resolve_node_size :: proc(u: ^Ui, prepared: ^Prepared_Ui, node: ^Prepared_Node) {
	assert(u != nil && prepared != nil && node != nil, "prepared resolve node: invalid argument")
	prepared_validate_size(node.sizing)
	node.size.w = prepared_axis_size(u, node.sizing.width, node.size.w, prepared.constraints.max_w)
	node.size.h = prepared_axis_size(
		u,
		node.sizing.height,
		node.size.h,
		prepared.constraints.max_h,
	)
	prepared_apply_aspect(&node.size, node.sizing, prepared.constraints)
}

@(private = "file")
prepared_remeasure_containers :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_remeasure_containers: invalid argument")
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.remeasure_node_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, false)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, false)
		} else {
			continue
		}
		prepared_resolve_node_size(u, prepared, node)
	}
}

@(private = "file")
prepared_validate_size :: proc(sizing: Prepared_Size) {
	ratio := sizing.aspect
	assert(ratio.width >= 0 && ratio.height >= 0, "prepared size: negative aspect")
	assert((ratio.width == 0) == (ratio.height == 0), "prepared size: incomplete aspect")
}

@(private = "file")
prepared_apply_aspect :: proc(
	size: ^Intrinsic_Size,
	sizing: Prepared_Size,
	constraints: Intrinsic_Constraints,
) {
	assert(size != nil && size.w >= 0 && size.h >= 0, "prepared aspect: invalid size")
	ratio := sizing.aspect
	if ratio.width == 0 do return
	width_explicit := prepared_axis_explicit(sizing.width)
	height_explicit := prepared_axis_explicit(sizing.height)
	if width_explicit && height_explicit do return
	if width_explicit {
		size.h = i32(i64(size.w) * i64(ratio.height) / i64(ratio.width))
	} else if height_explicit {
		size.w = i32(i64(size.h) * i64(ratio.width) / i64(ratio.height))
	} else {
		width := size.w
		height := i32(i64(width) * i64(ratio.height) / i64(ratio.width))
		if constraints.max_h > 0 && height > constraints.max_h {
			height = constraints.max_h
			width = i32(i64(height) * i64(ratio.width) / i64(ratio.height))
		}
		size.w = width
		size.h = height
	}
	size^ = intrinsic_constrain(size^, constraints)
}

@(private = "file")
prepared_axis_explicit :: proc(track: Track) -> bool {
	return track.kind != .Fit || track.basis > 0 || track.min_size > 0 || track.max_size > 0
}

@(private = "file")
prepared_axis_size :: proc(u: ^Ui, track: Track, natural, available: i32) -> i32 {
	assert(u != nil && natural >= 0 && available >= 0, "prepared_axis_size: invalid argument")
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	result := natural
	switch track.kind {
	case .Fit:
		if track.basis > 0 do result = ui_frame_sc(u.frame, track.basis)
	case .Hug:
		result = natural
	case .Fixed:
		result = ui_frame_sc(u.frame, track.basis)
	case .Grow:
		assert(available > 0, "prepared_axis_size: grow needs finite bound")
		result = available
	case .Percent:
		assert(available > 0, "prepared_axis_size: percent needs finite bound")
		result = i32(f32(available) * track.percent)
	}
	result = max(result, minimum)
	if maximum > 0 do result = min(result, maximum)
	return result
}

@(private = "file")
prepared_assign_widths :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_assign_widths: invalid argument")
	root := &prepared_nodes(prepared)[prepared.root]
	root.rect = {
		w = root.size.w,
		h = max(root.size.h, 1),
	}
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.width_assignment_visits += 1
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_place_children(u, prepared, index, true)
		} else if node.kind == .Flow {
			prepared_place_flow(u, prepared, index)
		} else if node.kind == .Grid {
			prepared_place_grid(u, prepared, index)
		} else if node.kind == .Grid_Cell {
			prepared_place_grid_cell(prepared, index)
		} else if node.kind == .Scroll {
			prepared_place_scroll(u, prepared, index, false)
		}
	}
}

@(private = "file")
prepared_measure_heights :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_heights: invalid argument")
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_measure_visits += 1
		node := &prepared_nodes(prepared)[index]
		if !prepared_kind_is_container(node.kind) {
			if prepared_leaf_needs_width_measure(node, node.rect.w) {
				prepared_measure_leaf(u, node, node.rect.w)
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_leaf_measures += 1
			}
			node.measured_width = node.rect.w
			node.measure_flags += {.Width_Valid}
			node.size.w = prepared_axis_size(
				u,
				node.sizing.width,
				node.size.w,
				prepared.constraints.max_w,
			)
			node.size.h = prepared_axis_size(
				u,
				node.sizing.height,
				node.size.h,
				prepared.constraints.max_h,
			)
			prepared_apply_aspect(&node.size, node.sizing, prepared.constraints)
		}
	}
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_measure_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, true)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, true)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, true)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, true)
		} else {
			continue
		}
		prepared_resolve_node_size(u, prepared, node)
	}
}

@(private = "file")
prepared_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_place: invalid argument")
	assert(prepared.count > 0 && prepared.count <= i32(prepared_capacity(prepared)))
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED {
			u.frame.prepared_telemetry.placement_node_visits += 1
			u.frame.prepared_telemetry.placed_nodes += 1
		}
		node := &prepared_nodes(prepared)[index]
		node.target_rect = node.rect
		if node.kind == .Attachment {
			prepared_place_attachment(u, prepared, index)
		} else {
			prepared_apply_transition(u, node)
			prepared_place_container(u, prepared, index)
		}
	}
}

@(private = "file")
prepared_place_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	if node.kind == .Row || node.kind == .Column {
		prepared_place_children(u, prepared, index, false)
	} else if node.kind == .Flow {
		prepared_place_flow(u, prepared, index)
	} else if node.kind == .Grid {
		prepared_place_grid(u, prepared, index)
	} else if node.kind == .Grid_Cell {
		prepared_place_grid_cell(prepared, index)
	} else if node.kind == .Scroll {
		prepared_place_scroll(u, prepared, index, true)
	}
}

@(private = "file")
prepared_place_scroll :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, interactive: bool) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Scroll && node.scroll.state != nil, "prepared scroll place: invalid node")
	assert(
		node.first_child >= 0 && node.first_child == node.last_child,
		"prepared scroll place: child count",
	)
	state := node.scroll.state
	if interactive {
		state.viewport_w = node.rect.w
		state.viewport_h = node.rect.h
		content_size := state.content_h
		viewport_size := node.rect.h
		if node.scroll.axis == .Horizontal {
			content_size = state.content_w
			viewport_size = node.rect.w
		}
		maximum := max(content_size - viewport_size, 0)
		mouse := get_mouse_position(u.frame)
		screen := frame_rect_to_screen(u.frame, rect_f32(node.rect))
		if node.scroll.focus.focus == nil && slot_visible(node.rect) {
			node.scroll.focus = focus(u, node.scroll.id)
		}
		focus_opt_click(
			u.frame,
			node.scroll.focus,
			node.rect.x,
			node.rect.y,
			node.rect.w,
			node.rect.h,
		)
		if point_in_rect(mouse, screen) && !route_occluded(u.frame, mouse) {
			wheel := get_mouse_wheel_move_v(u.frame)
			delta := wheel.y
			if node.scroll.axis == .Horizontal && wheel.x != 0 do delta = wheel.x
			when ODIN_OS == .Windows do delta *= 5
			state.offset -= delta * f32(ui_frame_sc(u.frame, 24))
		}
		if node.scroll.keyboard && focus_opt_focused(node.scroll.focus) {
			prepared_scroll_keyboard(u.frame, state, viewport_size, content_size, node.scroll.axis)
		}
		state.offset = clamp(state.offset, 0, f32(maximum))
	}
	content := rect_inset(node.rect, insets_of(u, node.scroll.padding))
	child := &prepared_nodes(prepared)[node.first_child]
	if node.scroll.axis == .Horizontal {
		child.rect = {content.x - i32(state.offset), content.y, child.size.w, content.h}
	} else {
		child.rect = {content.x, content.y - i32(state.offset), content.w, child.size.h}
	}
}

@(private = "file")
prepared_scroll_keyboard :: proc(
	frame: ^Ui_Frame,
	state: ^Prepared_Scroll_State,
	viewport_size, content_size: i32,
	axis: Scroll_Axis,
) {
	assert(
		frame != nil && state != nil && viewport_size >= 0 && content_size >= 0,
		"prepared scroll keyboard: invalid argument",
	)
	step := f32(ui_frame_metrics(frame).LINE_HEIGHT)
	if axis == .Horizontal {
		if is_key_pressed_or_repeat(frame, .RIGHT) do state.offset += step
		if is_key_pressed_or_repeat(frame, .LEFT) do state.offset -= step
	} else {
		if is_key_pressed_or_repeat(frame, .DOWN) do state.offset += step
		if is_key_pressed_or_repeat(frame, .UP) do state.offset -= step
	}
	if is_key_pressed_or_repeat(frame, .PAGE_DOWN) do state.offset += f32(viewport_size)
	if is_key_pressed_or_repeat(frame, .PAGE_UP) do state.offset -= f32(viewport_size)
	if is_key_pressed(frame, .HOME) do state.offset = 0
	if is_key_pressed(frame, .END) do state.offset = f32(max(content_size - viewport_size, 0))
}

prepared_apply_transition :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_apply_transition: invalid argument")
	transition := node.sizing.transition
	if node.kind == .Attachment do transition = node.attachment.transition
	if transition.state != nil {
		node.rect = transition_rect(
			u.frame,
			transition.state,
			node.target_rect,
			transition.options,
		)
	}
}

@(private = "file")
prepared_place_attachment :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil && index > 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Attachment && node.first_child == node.last_child)
	assert(node.first_child > index && node.first_child < prepared.count)
	target := prepared_attachment_target(u, prepared, index)
	width, height := node.size.w, node.size.h
	target_point := prepared_attachment_point(target, node.attachment.target_point)
	self_point := prepared_attachment_point({w = width, h = height}, node.attachment.self_point)
	x := target_point.x - self_point.x + ui_frame_sc(u.frame, node.attachment.offset_x)
	y := target_point.y - self_point.y + ui_frame_sc(u.frame, node.attachment.offset_y)
	node.target_rect = {x, y, width, height}
	if node.attachment.clamp_to_viewport {
		node.target_rect.x = clamp(node.target_rect.x, 0, max(u.screen_w - width, 0))
		node.target_rect.y = clamp(node.target_rect.y, 0, max(u.screen_h - height, 0))
	}
	node.rect = node.target_rect
	prepared_apply_transition(u, node)
	prepared_nodes(prepared)[node.first_child].rect = node.rect
}

@(private = "file")
prepared_attachment_target :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) -> Rect_I32 {
	assert(u != nil && prepared != nil && index > 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	switch node.attachment.target_kind {
	case .Parent:
		return prepared_screen_rect(u, prepared_nodes(prepared)[node.parent].rect)
	case .Root:
		return prepared_screen_rect(u, prepared_nodes(prepared)[prepared.root].rect)
	case .Handle:
		target := i32(node.attachment.target)
		assert(target >= 0 && target < index, "prepared attachment: invalid handle")
		assert(
			!prepared_is_ancestor(prepared, index, target),
			"prepared attachment: descendant target",
		)
		return prepared_screen_rect(u, prepared_nodes(prepared)[target].rect)
	case .Screen_Rect:
		return node.attachment.target_screen
	case .Viewport:
		return {0, 0, u.screen_w, u.screen_h}
	}
	unreachable()
}

@(private = "file")
prepared_screen_rect :: proc(u: ^Ui, rect: Rect_I32) -> Rect_I32 {
	assert(u != nil && u.open && u.frame != nil, "prepared_screen_rect: invalid UI")
	value := frame_rect_to_screen(u.frame, rect_f32(rect))
	return {i32(value.x), i32(value.y), rect.w, rect.h}
}

@(private = "file")
prepared_is_ancestor :: proc(prepared: ^Prepared_Ui, ancestor, node: i32) -> bool {
	assert(prepared != nil && ancestor >= 0 && node >= 0)
	cursor := node
	for _ in 0 ..< MAX_LAYOUT_DEPTH {
		if cursor < 0 do return false
		if cursor == ancestor do return true
		cursor = prepared_nodes(prepared)[cursor].parent
	}
	assert(cursor < 0, "prepared_is_ancestor: depth bound")
	return false
}

@(private = "file")
prepared_attachment_point :: proc(rect: Rect_I32, point: Attachment_Point) -> [2]i32 {
	x, y := rect.x, rect.y
	switch point {
	case .Top, .Center, .Bottom:
		x += rect.w / 2
	case .Top_Right, .Right, .Bottom_Right:
		x += rect.w
	case .Top_Left, .Left, .Bottom_Left:
	}
	switch point {
	case .Left, .Center, .Right:
		y += rect.h / 2
	case .Bottom_Left, .Bottom, .Bottom_Right:
		y += rect.h
	case .Top_Left, .Top, .Top_Right:
	}
	return {x, y}
}

@(private = "file")
prepared_flow_line_end :: proc(
	prepared: ^Prepared_Ui,
	first: i32,
	width, gap: i32,
) -> (
	end: i32,
	count, used, height: i32,
) {
	assert(prepared != nil && first >= 0 && first < prepared.count)
	assert(width >= 0 && gap >= 0, "prepared flow line: invalid bounds")
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		value := &prepared_nodes(prepared)[child]
		if value.kind == .Attachment {
			child = value.next_sibling
			continue
		}
		item_width := value.size.w
		if value.track.kind == .Grow do item_width = ui_frame_sc(prepared.u.frame, value.track.min_size)
		before := gap if count > 0 else 0
		if count > 0 && i64(used) + i64(before) + i64(item_width) > i64(width) do break
		used = min(width, used + before + item_width)
		height = max(height, value.size.h)
		count += 1
		child = value.next_sibling
	}
	assert(count > 0, "prepared flow line: empty line")
	return child, count, used, height
}

@(private = "file")
prepared_flow_grow_sizes :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	first, end, free: i32,
	result: ^[MAX_FLOW_GROW_ITEMS]i32,
) -> i32 {
	assert(u != nil && prepared != nil && result != nil, "prepared flow grow: invalid argument")
	tracks: [MAX_FLOW_GROW_ITEMS]Track
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 || child == end do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment && value.track.kind == .Grow {
			assert(count < MAX_FLOW_GROW_ITEMS, "prepared flow grow: line capacity exceeded")
			tracks[count] = prepared_scale_track(u, value.track)
			count += 1
		}
		child = value.next_sibling
	}
	if count > 0 do _ = track_resolve(tracks[:count], free, 0, result[:])
	return count
}

@(private = "file")
prepared_place_flow_line :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	node: ^Prepared_Node,
	first, end, count, used, height, y: i32,
	content: Rect_I32,
) {
	assert(
		u != nil && prepared != nil && node != nil,
		"prepared flow place line: invalid argument",
	)
	gap := space_px(u, node.flow.gap_x)
	free := max(content.w - used, 0)
	grow_sizes: [MAX_FLOW_GROW_ITEMS]i32
	grow_count := prepared_flow_grow_sizes(u, prepared, first, end, free, &grow_sizes)
	resolved_used := content.w if grow_count > 0 else used
	leftover := max(content.w - resolved_used, 0)
	x := content.x
	between: i32
	if node.flow.justify == .Center do x += leftover / 2
	if node.flow.justify == .End do x += leftover
	if node.flow.justify == .Space_Between && count > 1 do between = leftover
	child, item_index, grow_index := first, i32(0), i32(0)
	for _ in 0 ..< prepared.count {
		if child < 0 || child == end do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			width := value.size.w
			if value.track.kind == .Grow {
				width = grow_sizes[grow_index]
				grow_index += 1
			}
			offset_y: i32
			if node.flow.align == .Center do offset_y = (height - value.size.h) / 2
			if node.flow.align == .End do offset_y = height - value.size.h
			value.rect = {x, y + offset_y, min(width, content.w), value.size.h}
			x += width
			if item_index + 1 < count {
				x += gap
				if between > 0 {
					share := i64(item_index + 1) * i64(between) / i64(count - 1)
					before := i64(item_index) * i64(between) / i64(count - 1)
					x += i32(share - before)
				}
			}
			item_index += 1
		}
		child = value.next_sibling
	}
	assert(grow_index == grow_count && item_index == count, "prepared flow place line: incomplete")
}

@(private = "file")
prepared_place_flow :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_flow: invalid argument")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.flow.padding))
	child := node.first_child
	y := content.y
	for _ in 0 ..< prepared.count {
		for child >= 0 && prepared_nodes(prepared)[child].kind == .Attachment {
			child = prepared_nodes(prepared)[child].next_sibling
		}
		if child < 0 do break
		end, count, used, height := prepared_flow_line_end(
			prepared,
			child,
			content.w,
			space_px(u, node.flow.gap_x),
		)
		prepared_place_flow_line(u, prepared, node, child, end, count, used, height, y, content)
		y += height + space_px(u, node.flow.gap_y)
		child = end
	}
	assert(child < 0, "prepared_place_flow: child bound")
}

@(private = "file")
prepared_grid_items :: proc(
	prepared: ^Prepared_Ui,
	node: ^Prepared_Node,
	indices: ^[MAX_GRID_CELLS]i32,
	placements: ^[MAX_GRID_CELLS]Grid_Placement,
) -> i32 {
	assert(prepared != nil && node != nil, "prepared grid items: invalid argument")
	assert(indices != nil && placements != nil, "prepared grid items: nil output")
	count: i32
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			assert(count < MAX_GRID_CELLS, "prepared grid items: capacity exceeded")
			indices[count] = child
			placements[count] =
				value.grid_cell.placement if value.kind == .Grid_Cell else {-1, -1, 1, 1}
			count += 1
		}
		child = value.next_sibling
	}
	assert(child < 0, "prepared grid items: child bound")
	return count
}

@(private = "file")
prepared_place_track_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, content: Rect_I32) {
	assert(u != nil && prepared != nil, "prepared track grid: invalid argument")
	node := &prepared_nodes(prepared)[index]
	column_count := len(node.grid.column_tracks)
	indices: [MAX_GRID_CELLS]i32
	placements: [MAX_GRID_CELLS]Grid_Placement
	resolved: [MAX_GRID_CELLS]Grid_Resolved_Placement
	count := prepared_grid_items(prepared, node, &indices, &placements)
	row_count := len(node.grid.row_tracks)
	if row_count == 0 {
		row_count = min((int(count) + column_count - 1) / column_count, MAX_GRID_TRACKS)
	}
	row_count = max(row_count, 1)
	columns: [MAX_GRID_TRACKS]Track
	rows: [MAX_GRID_TRACKS]Track
	for track, track_index in node.grid.column_tracks {
		columns[track_index] = prepared_scale_track(u, track)
	}
	for track, track_index in node.grid.row_tracks {
		rows[track_index] = prepared_scale_track(u, track)
	}
	if len(node.grid.row_tracks) == 0 {
		row_height := fixed(ui_frame_sc(u.frame, node.grid.row_height))
		for track_index in 0 ..< row_count do rows[track_index] = row_height
	}
	for item_index in 0 ..< count {
		placement := placements[item_index]
		placement.column_span = max(placement.column_span, 1)
		placement.row_span = max(placement.row_span, 1)
		if placement.column < 0 || placement.column_span != 1 do continue
		item := &prepared_nodes(prepared)[indices[item_index]]
		column := &columns[placement.column]
		if column.kind == .Fit || column.kind == .Hug do column.basis = max(column.basis, item.size.w)
	}
	column_sizes: [MAX_GRID_TRACKS]i32
	row_sizes: [MAX_GRID_TRACKS]i32
	_ = track_resolve(
		columns[:column_count],
		content.w,
		space_px(u, node.grid.gap_x),
		column_sizes[:],
	)
	_ = track_resolve(rows[:row_count], content.h, space_px(u, node.grid.gap_y), row_sizes[:])
	unplaced := grid_auto_place(
		placements[:count],
		i32(column_count),
		i32(row_count),
		node.grid.auto_flow,
		resolved[:],
	)
	for _ in 0 ..< unplaced do ui_frame_record_layout_overflow(u.frame)
	for item_index in 0 ..< count {
		item := &prepared_nodes(prepared)[indices[item_index]]
		if resolved[item_index].placed {
			item.rect = grid_span_rect(
				content,
				column_sizes[:column_count],
				row_sizes[:row_count],
				space_px(u, node.grid.gap_x),
				space_px(u, node.grid.gap_y),
				resolved[item_index],
			)
		} else {
			item.rect = {content.x, content.y, 0, 0}
		}
	}
}

@(private = "file")
prepared_place_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_grid: invalid argument")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.grid.padding))
	if len(node.grid.column_tracks) > 0 {
		prepared_place_track_grid(u, prepared, index, content)
		return
	}
	grid: Grid
	grid_begin(
		&grid,
		content,
		node.grid.columns,
		ui_frame_sc(u.frame, node.grid.row_height),
		space_px(u, node.grid.gap_x),
		space_px(u, node.grid.gap_y),
	)
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.child_run_visits += 1
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment do value.rect = grid_next(&grid)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_place_grid: child bound")
	_ = grid_end(&grid)
}

@(private = "file")
prepared_place_grid_cell :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Grid_Cell && node.first_child == node.last_child)
	child := &prepared_nodes(prepared)[node.first_child]
	width := child.size.w
	height := child.size.h
	if node.grid_cell.align_x == .Stretch do width = node.rect.w
	if node.grid_cell.align_y == .Stretch do height = node.rect.h
	x := node.rect.x
	y := node.rect.y
	if node.grid_cell.align_x == .Center do x += (node.rect.w - width) / 2
	if node.grid_cell.align_x == .End do x += node.rect.w - width
	if node.grid_cell.align_y == .Center do y += (node.rect.h - height) / 2
	if node.grid_cell.align_y == .End do y += node.rect.h - height
	child.rect = {x, y, min(width, node.rect.w), min(height, node.rect.h)}
}

@(private = "file")
prepared_place_children :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, widths_only: bool) {
	assert(u != nil && prepared != nil, "prepared_place_children: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_place_children: index out of range")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.container.padding))
	children: [MAX_LAYOUT_FLEX]i32
	tracks: [MAX_LAYOUT_FLEX]Track
	count := prepared_children(prepared, node.first_child, &children)
	if count == 0 do return
	for child_index in 0 ..< count {
		child := &prepared_nodes(prepared)[children[child_index]]
		tracks[child_index] = prepared_track_px(u, child, node.kind)
	}
	layout: Layout
	layout_begin(&layout, content.x, content.y, content.w, content.h)
	layout_push_rect(
		&layout,
		node.kind == .Row ? .Row : .Column,
		content,
		space_px(u, node.container.gap),
		node.container.align,
	)
	axis: Flex_Axis = .Row if node.kind == .Row else .Column
	flex_begin(&layout, tracks[:count], node.container.justify, axis)
	for child_index in 0 ..< count {
		child := &prepared_nodes(prepared)[children[child_index]]
		cross_size := child.size.h if node.kind == .Row else child.size.w
		rect := flex_next_sized(&layout, cross_size)
		if widths_only {
			child.rect.w = rect.w
			child.rect.h = max(rect.h, child.size.h)
		} else {
			child.rect = rect
		}
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.width_assignments += 1
	}
	flex_end(&layout)
	layout_pop(&layout)
	layout_end(&layout)
}

@(private = "file")
prepared_children :: proc(
	prepared: ^Prepared_Ui,
	first: i32,
	result: ^[MAX_LAYOUT_FLEX]i32,
) -> i32 {
	assert(prepared != nil && result != nil, "prepared_children: invalid argument")
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_children: bad child")
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			assert(count < MAX_LAYOUT_FLEX, "prepared_children: too many children")
			result[count] = child
			count += 1
		}
		child = value.next_sibling
	}
	assert(child < 0, "prepared_children: too many children")
	return count
}

@(private = "file")
prepared_scale_track :: proc(u: ^Ui, track: Track) -> Track {
	assert(u != nil && u.frame != nil, "prepared scale track: invalid UI")
	assert(track.min_size >= 0 && (track.max_size == 0 || track.max_size >= track.min_size))
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(ui_frame_sc(u.frame, track.basis), minimum, maximum)
	case .Hug:
		return hug(ui_frame_sc(u.frame, track.basis), minimum, maximum)
	case .Grow:
		return grow(track.weight, minimum, maximum)
	case .Fixed:
		return fixed(ui_frame_sc(u.frame, track.basis))
	case .Percent:
		return percent(track.percent, minimum, maximum)
	}
	unreachable()
}

@(private = "file")
prepared_track_px :: proc(u: ^Ui, node: ^Prepared_Node, parent_kind: Prepared_Kind) -> Track {
	assert(u != nil && node != nil, "prepared_track_px: invalid argument")
	assert(parent_kind == .Row || parent_kind == .Column, "prepared_track_px: invalid parent")
	track := node.track
	if track.kind == .Fit && track.basis == 0 && track.min_size == 0 && track.max_size == 0 {
		basis := node.size.w if parent_kind == .Row else node.size.h
		assert(basis >= 0, "prepared_track_px: negative intrinsic basis")
		return hug(basis)
	}
	if track.kind == .Hug {
		basis := node.size.w if parent_kind == .Row else node.size.h
		track.basis = basis
		track.min_size = ui_frame_sc(u.frame, track.min_size)
		track.max_size = ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
		return track
	}
	return prepared_scale_track(u, track)
}

Prepared_Render_Frame :: struct {
	index:      i32,
	next_child: i32,
}

@(private = "file")
prepared_render_tree :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_render_tree: invalid argument")
	root := &prepared_nodes(prepared)[prepared.root]
	assert(prepared_kind_is_container(root.kind), "prepared_render_tree: leaf root")
	stack: [MAX_LAYOUT_DEPTH]Prepared_Render_Frame
	prepared_render_enter(u, root)
	when UI_TELEMETRY_ENABLED {
		u.frame.prepared_telemetry.render_node_visits += 1
		u.frame.prepared_telemetry.rendered_nodes += 1
		if !prepared.direct_geometry do u.frame.prepared_telemetry.generic_fallback_nodes += 1
	}
	stack[0] = {
		index      = prepared.root,
		next_child = root.first_child,
	}
	depth := 1
	for depth > 0 {
		frame := &stack[depth - 1]
		if frame.next_child < 0 {
			prepared_render_exit(u, &prepared_nodes(prepared)[frame.index])
			depth -= 1
			continue
		}
		child_index := frame.next_child
		assert(child_index >= 0 && child_index < prepared.count, "prepared_render_tree: bad child")
		child := &prepared_nodes(prepared)[child_index]
		when UI_TELEMETRY_ENABLED {
			u.frame.prepared_telemetry.render_node_visits += 1
			u.frame.prepared_telemetry.rendered_nodes += 1
			if !prepared.direct_geometry do u.frame.prepared_telemetry.generic_fallback_nodes += 1
		}
		frame.next_child = child.next_sibling
		if prepared_kind_is_container(child.kind) {
			assert(depth < MAX_LAYOUT_DEPTH, "prepared_render_tree: depth full")
			prepared_render_enter(u, child)
			stack[depth] = {
				index      = child_index,
				next_child = child.first_child,
			}
			depth += 1
		} else {
			prepared_render_leaf(u, child)
		}
	}
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

@(private = "file")
prepared_render_enter :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_enter: invalid argument")
	if node.kind == .Attachment {
		claim := Rectangle{}
		if node.attachment.claim {
			claim = rect_f32(prepared_rect_union(node.rect, node.target_rect))
		}
		layer_begin(u.frame, node.attachment.z, claim)
		return
	}
	if node.kind == .Scroll {
		state := node.scroll.state
		maximum := max(state.content_h - state.viewport_h, 0)
		if node.scroll.axis == .Horizontal do maximum = max(state.content_w - state.viewport_w, 0)
		semantic_push(
			u.frame,
			.Pane,
			node.rect,
			"Scrollable content",
			focus = node.scroll.focus,
			value = state.offset,
			lo = 0,
			hi = f32(maximum),
			widget = node.scroll.id,
		)
		begin_scissor_mode(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
		return
	}
	effects := prepared_container_effects(node)
	if effects.surface.enabled {
		assert(effects.background.a == 0, "prepared container: mixed surface and background")
		assert(effects.border == .None, "prepared container: mixed surface and border")
		draw_surface(
			u.frame,
			rect_f32(node.rect),
			effects.surface.kind,
			effects.surface.state,
			effects.surface.radius,
			effects.surface.border,
			effects.surface.elevation,
		)
	}
	if effects.background.a > 0 {
		draw_rounded_fill(u.frame, rect_f32(node.rect), effects.radius, effects.background)
	}
	if effects.border != .None && effects.border_color.a > 0 {
		draw_rounded_border(
			u.frame,
			rect_f32(node.rect),
			effects.radius,
			effects.border,
			effects.border_color,
		)
	}
	if effects.clip do begin_scissor_mode(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
}

@(private = "file")
prepared_render_exit :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_exit: invalid argument")
	if node.kind == .Attachment {
		layer_end(u.frame)
		return
	}
	if node.kind == .Scroll {
		end_scissor_mode(u.frame)
		state := node.scroll.state
		if node.scroll.axis == .Horizontal &&
		   node.scroll.bar &&
		   state.content_w > state.viewport_w {
			scrollbar_offset := scrollbar_horizontal_ex(
				u.frame,
				&state.scrollbar,
				node.rect.x + ui_frame_sc(u.frame, 2),
				node.rect.y + node.rect.h - ui_frame_sc(u.frame, 9),
				node.rect.w - ui_frame_sc(u.frame, 4),
				ui_frame_sc(u.frame, 5),
				int(state.content_w),
				int(state.viewport_w),
				int(state.offset),
			)
			if state.scrollbar.dragging do state.offset = f32(scrollbar_offset)
		} else if node.scroll.axis == .Vertical &&
		   node.scroll.bar &&
		   state.content_h > state.viewport_h {
			scrollbar_offset := scrollbar_ex(
				u.frame,
				&state.scrollbar,
				node.rect.x + node.rect.w - ui_frame_sc(u.frame, 9),
				node.rect.y + ui_frame_sc(u.frame, 2),
				ui_frame_sc(u.frame, 5),
				node.rect.h - ui_frame_sc(u.frame, 4),
				int(state.content_h),
				int(state.viewport_h),
				int(state.offset),
			)
			if state.scrollbar.dragging do state.offset = f32(scrollbar_offset)
		} else {
			state.scrollbar = {}
		}
		if focus_opt_focused(node.scroll.focus) {
			draw_focus_ring(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
		}
		return
	}
	if prepared_container_effects(node).clip do end_scissor_mode(u.frame)
}

@(private = "file")
prepared_container_effects :: proc(node: ^Prepared_Node) -> Prepared_Container_Effects {
	assert(node != nil && prepared_kind_is_container(node.kind), "prepared effects: invalid node")
	switch node.kind {
	case .Row, .Column:
		return node.container.effects
	case .Flow:
		return node.flow.effects
	case .Grid:
		return node.grid.effects
	case .Grid_Cell:
		return {}
	case .Attachment,
	     .Scroll,
	     .Label,
	     .Button,
	     .Checkbox,
	     .Radio,
	     .Slider,
	     .Text_Input,
	     .Progress,
	     .Separator,
	     .Spacer,
	     .Table_Cell,
	     .Composite,
	     .Custom:
		unreachable()
	}
	unreachable()
}

@(private = "file")
prepared_render_leaf :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_leaf: invalid argument")
	switch node.kind {
	case .Label:
		prepared_render_label(u, node)
	case .Button:
		node.activated = button_spec_at(u, node.button, node.rect)
	case .Checkbox:
		node.activated = checkbox_spec_at(u, node.checkbox, node.rect)
	case .Radio:
		node.activated = radio_spec_at(u, node.radio, node.rect)
	case .Slider:
		node.activated = slider_spec_at(u, node.slider, node.rect)
	case .Text_Input:
		node.activated = prepared_text_input_at(u, node.text_input, node.rect)
	case .Progress:
		prepared_progress_at(u, node.progress, node.rect)
	case .Separator:
		prepared_separator_at(u, node.rect)
	case .Spacer:
	case .Table_Cell:
		prepared_table_cell_at(u, node.table_cell, node.rect)
	case .Composite:
		node.activated = prepared_composite_at(u, node.composite, node.rect)
	case .Custom:
		node.activated = node.custom.render(u, node.rect, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Grid_Cell, .Attachment, .Scroll:
		unreachable()
	}
	if node.activation != nil {
		node.activation^ = node.activation^ || node.activated
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.activation_outputs += 1
	}
}

@(private = "file")
prepared_rect_union :: proc(a, b: Rect_I32) -> Rect_I32 {
	x0 := min(i64(a.x), i64(b.x))
	y0 := min(i64(a.y), i64(b.y))
	x1 := max(i64(a.x) + i64(a.w), i64(b.x) + i64(b.w))
	y1 := max(i64(a.y) + i64(a.h), i64(b.y) + i64(b.h))
	assert(x0 >= i64(min(i32)) && y0 >= i64(min(i32)))
	assert(x1 <= i64(max(i32)) && y1 <= i64(max(i32)))
	return {i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0)}
}

@(private = "file")
prepared_render_label :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_label: invalid argument")
	assert(node.kind == .Label && node.label.text != "", "prepared_render_label: invalid node")
	if !slot_visible(node.rect) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	if node.label.wrap {
		_ = text_wrapped(
			u.frame,
			node.label.text,
			node.rect.x,
			node.rect.y,
			node.rect.w,
			node.label.role,
			node.label.ink,
		)
	} else {
		font_size := text_role_size(u.frame, node.label.role)
		draw_text_string_frame(
			u.frame,
			node.label.text,
			node.rect.x,
			node.rect.y + (node.rect.h - font_size) / 2,
			font_size,
			text_ink(u.frame, node.label.ink),
		)
	}
	semantic_push(u.frame, .Label, node.rect, node.label.text, {})
}
