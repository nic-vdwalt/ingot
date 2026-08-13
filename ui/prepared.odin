package ui

MAX_PREPARED_NODES_DEFAULT :: 64
MAX_PREPARED_NODES_HARD :: 256
MAX_PREPARED_NODES :: #config(INGOT_PREPARED_NODE_CAP, MAX_PREPARED_NODES_DEFAULT)
#assert(MAX_PREPARED_NODES >= MAX_LAYOUT_DEPTH)
#assert(MAX_PREPARED_NODES <= MAX_PREPARED_NODES_HARD)

Prepared_Handle :: distinct i32
PREPARED_HANDLE_NONE :: Prepared_Handle(-1)

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

Prepared_Container_Effects :: struct {
	clip:         bool,
	background:   Color,
	radius:       Radius,
	border:       Border,
	border_color: Color,
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
	track:        Track,
	size:         Prepared_Size,
	effects:      Prepared_Container_Effects,
}

Prepared_Grid_Options :: struct {
	columns:      i32,
	row_height:   i32,
	gap_x, gap_y: Space,
	padding:      Space,
	track:        Track,
	size:         Prepared_Size,
	effects:      Prepared_Container_Effects,
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

Prepared_Kind :: enum u8 {
	Row,
	Column,
	Flow,
	Grid,
	Attachment,
	Label,
	Button,
	Custom,
}

Prepared_Node :: struct {
	kind:                     Prepared_Kind,
	parent, first_child:      i32,
	next_sibling, last_child: i32,
	track:                    Track,
	sizing:                   Prepared_Size,
	container:                Prepared_Container_Options,
	flow:                     Prepared_Flow_Options,
	grid:                     Prepared_Grid_Options,
	attachment:               Prepared_Attachment_Options,
	label:                    Label_Spec,
	button:                   Button_Spec,
	custom:                   Prepared_Custom,
	size:                     Intrinsic_Size,
	rect:                     Rect_I32,
	target_rect:              Rect_I32,
	activated:                bool,
}

Prepared_Ui :: struct {
	nodes:       [MAX_PREPARED_NODES]Prepared_Node,
	stack:       [MAX_LAYOUT_DEPTH]i32,
	u:           ^Ui,
	count:       i32,
	depth:       i32,
	root:        i32,
	constraints: Intrinsic_Constraints,
	open:        bool,
	measured:    bool,
	rendered:    bool,
}

prepared_begin :: proc(prepared: ^Prepared_Ui, constraints: Intrinsic_Constraints = {}) {
	assert(prepared != nil, "prepared_begin: nil description")
	assert(!prepared.open, "prepared_begin: description already open")
	assert(constraints.min_w >= 0 && constraints.min_h >= 0, "prepared_begin: invalid minimum")
	assert(constraints.max_w == 0 || constraints.max_w >= constraints.min_w)
	assert(constraints.max_h == 0 || constraints.max_h >= constraints.min_h)
	prepared.u = nil
	assert(prepared.count >= 0 && prepared.count <= MAX_PREPARED_NODES)
	prepared.count = 0
	prepared.depth = 0
	prepared.root = -1
	prepared.constraints = constraints
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
	assert(options.columns > 0, "prepared_grid_begin: invalid columns")
	assert(options.row_height >= 0, "prepared_grid_begin: invalid row height")
	handle := prepared_add(
		prepared,
		Prepared_Node{kind = .Grid, track = options.track, sizing = options.size, grid = options},
	)
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
	if prepared.nodes[index].kind == .Attachment {
		assert(index >= 0 && index < len(prepared.nodes))
		assert(prepared_child_count(prepared, prepared.nodes[index].first_child) == 1)
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
	prepared_measure_natural(u, prepared)
	root := &prepared.nodes[prepared.root]
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	dependencies := prepared_dependencies(prepared)
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
	prepared_resolve_sizes(u, prepared)
	prepared_remeasure_containers(u, prepared)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	prepared_assign_widths(u, prepared)
	prepared_measure_heights(u, prepared)
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
	assert(prepared.root < MAX_PREPARED_NODES, "prepared_render_at: root out of bounds")
	assert(prepared.root < prepared.count, "prepared_render_at: root beyond count")
	root := &prepared.nodes[prepared.root]
	if root.size.w != rect.w || root.size.h != rect.h {
		root.size.w = rect.w
		root.size.h = rect.h
		root.rect = rect
		prepared_assign_widths(u, prepared)
		prepared_measure_heights(u, prepared)
	}
	root.rect = rect
	prepared_place(u, prepared)
	prepared_render_tree(u, prepared)
	prepared.rendered = true
	prepared.open = false
}

prepared_fit :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(u != nil && u.open, "prepared_fit: frame not open")
	assert(prepared != nil && prepared.open, "prepared_fit: description not open")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_fit: invalid root")
	size := prepared.nodes[prepared.root].size
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
	return prepared.nodes[index].activated
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
	assert(prepared.count >= 0 && prepared.count < MAX_PREPARED_NODES, "prepared_add: nodes full")
	assert(
		prepared.depth >= 0 && prepared.depth <= MAX_LAYOUT_DEPTH,
		"prepared_add: invalid depth",
	)
	index := prepared.count
	value := node
	value.parent = -1
	value.first_child = -1
	value.next_sibling = -1
	value.last_child = -1
	if prepared.depth > 0 {
		parent_index := prepared.stack[prepared.depth - 1]
		assert(parent_index >= 0 && parent_index < index, "prepared_add: invalid parent")
		parent := &prepared.nodes[parent_index]
		value.parent = parent_index
		if parent.first_child < 0 {
			parent.first_child = index
		} else {
			assert(
				parent.last_child >= 0 && parent.last_child < index,
				"prepared_add: invalid sibling",
			)
			prepared.nodes[parent.last_child].next_sibling = index
		}
		parent.last_child = index
	} else {
		assert(prepared.root < 0, "prepared_add: multiple roots")
		prepared.root = index
	}
	prepared.nodes[index] = value
	prepared.count += 1
	return Prepared_Handle(index)
}

@(private = "file")
prepared_measure_natural :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_natural: invalid argument")
	assert(prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared.nodes[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if prepared_kind_is_container(node.kind) {
			prepared_measure_container(u, prepared, index, false)
		} else {
			prepared_measure_leaf(u, node, 0)
		}
	}
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
	case .Custom:
		node.size = node.custom.measure(u, {max_w = max_width}, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Attachment:
		unreachable()
	}
	assert(node.size.w >= 0 && node.size.h >= 0, "prepared_measure_leaf: invalid result")
}

@(private = "file")
prepared_measure_attachment :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared.nodes[index]
	assert(node.kind == .Attachment, "prepared_measure_attachment: wrong kind")
	assert(node.first_child >= 0 && node.first_child == node.last_child)
	node.size = prepared.nodes[node.first_child].size
}

@(private = "file")
prepared_measure_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_container: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_measure_container: index out of range")
	node := &prepared.nodes[index]
	children: [MAX_LAYOUT_FLEX]Intrinsic_Size
	count: i32
	child := node.first_child
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		if child < 0 do break
		assert(
			child < prepared.count && count < MAX_LAYOUT_FLEX,
			"prepared_measure_container: bad child",
		)
		value := &prepared.nodes[child]
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
	assert(index >= 0 && index < prepared.count, "prepared_measure_flow: index out of range")
	node := &prepared.nodes[index]
	padding := insets_of(u, node.flow.padding)
	max_width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do max_width = node.rect.w
	assert(max_width > 0, "prepared_measure_flow: finite width required")
	content_w := max(max_width - padding.left - padding.right, 0)
	flow: Flow_Layout
	flow_begin(&flow, {w = content_w}, space_px(u, node.flow.gap_x), space_px(u, node.flow.gap_y))
	child := node.first_child
	for _ in 0 ..< MAX_PREPARED_NODES {
		if child < 0 do break
		value := &prepared.nodes[child]
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
	assert(index >= 0 && index < prepared.count, "prepared_measure_grid: index out of range")
	node := &prepared.nodes[index]
	assert(node.grid.columns > 0, "prepared_measure_grid: invalid columns")
	count := prepared_in_flow_child_count(prepared, node.first_child)
	rows := (count + node.grid.columns - 1) / node.grid.columns
	padding := insets_of(u, node.grid.padding)
	gap_y := space_px(u, node.grid.gap_y)
	row_h := ui_frame_sc(u.frame, node.grid.row_height)
	content_h := rows * row_h + max(rows - 1, 0) * gap_y
	width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do width = node.rect.w
	assert(width > 0, "prepared_measure_grid: finite width required")
	content_w := max(width - padding.left - padding.right, 0)
	node.size = intrinsic_padding(intrinsic_leaf(content_w, content_h), padding)
}

@(private = "file")
prepared_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< MAX_PREPARED_NODES {
		assert(count >= 0 && count < MAX_PREPARED_NODES, "prepared_child_count: corrupt count")
		if child < 0 do break
		count += 1
		child = prepared.nodes[child].next_sibling
	}
	assert(child < 0, "prepared_child_count: child bound")
	return count
}

@(private = "file")
prepared_in_flow_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_in_flow_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< MAX_PREPARED_NODES {
		if child < 0 do break
		if prepared.nodes[child].kind != .Attachment do count += 1
		child = prepared.nodes[child].next_sibling
	}
	assert(child < 0 && count >= 0, "prepared_in_flow_child_count: child bound")
	return count
}

Prepared_Dependencies :: struct {
	width, height: bool,
}

@(private = "file")
prepared_dependencies :: proc(prepared: ^Prepared_Ui) -> Prepared_Dependencies {
	assert(prepared != nil && prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	result: Prepared_Dependencies
	for index in 0 ..< prepared.count {
		node := prepared.nodes[index]
		result.width = result.width || prepared_axis_dependent(node.sizing.width)
		result.height = result.height || prepared_axis_dependent(node.sizing.height)
		if node.kind == .Flow || node.kind == .Grid do result.width = true
		child := node.first_child
		for _ in 0 ..< MAX_PREPARED_NODES {
			if child < 0 do break
			track := prepared.nodes[child].track
			dependent := track.kind == .Grow || track.kind == .Percent
			if node.kind == .Row do result.width = result.width || dependent
			if node.kind == .Column do result.height = result.height || dependent
			child = prepared.nodes[child].next_sibling
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
		node := &prepared.nodes[index]
		prepared_validate_size(node.sizing)
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

@(private = "file")
prepared_remeasure_containers :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_remeasure_containers: invalid argument")
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared.nodes[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, false)
		}
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
	root := &prepared.nodes[prepared.root]
	root.rect = {
		w = root.size.w,
		h = max(root.size.h, 1),
	}
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_place_children(u, prepared, index, true)
		} else if node.kind == .Flow {
			prepared_place_flow(u, prepared, index)
		} else if node.kind == .Grid {
			prepared_place_grid(u, prepared, index)
		}
	}
}

@(private = "file")
prepared_measure_heights :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_heights: invalid argument")
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		if !prepared_kind_is_container(node.kind) {
			prepared_measure_leaf(u, node, node.rect.w)
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
		index := prepared.count - 1 - offset
		node := &prepared.nodes[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, true)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, true)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, true)
		}
	}
}

@(private = "file")
prepared_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_place: invalid argument")
	assert(prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
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
	node := &prepared.nodes[index]
	if node.kind == .Row || node.kind == .Column {
		prepared_place_children(u, prepared, index, false)
	} else if node.kind == .Flow {
		prepared_place_flow(u, prepared, index)
	} else if node.kind == .Grid {
		prepared_place_grid(u, prepared, index)
	}
}

@(private = "file")
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
	node := &prepared.nodes[index]
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
	prepared.nodes[node.first_child].rect = node.rect
}

@(private = "file")
prepared_attachment_target :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) -> Rect_I32 {
	assert(u != nil && prepared != nil && index > 0 && index < prepared.count)
	node := &prepared.nodes[index]
	switch node.attachment.target_kind {
	case .Parent:
		return prepared_screen_rect(u, prepared.nodes[node.parent].rect)
	case .Root:
		return prepared_screen_rect(u, prepared.nodes[prepared.root].rect)
	case .Handle:
		target := i32(node.attachment.target)
		assert(target >= 0 && target < index, "prepared attachment: invalid handle")
		assert(
			!prepared_is_ancestor(prepared, index, target),
			"prepared attachment: descendant target",
		)
		return prepared_screen_rect(u, prepared.nodes[target].rect)
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
		cursor = prepared.nodes[cursor].parent
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
prepared_place_flow :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_flow: invalid argument")
	node := &prepared.nodes[index]
	content := rect_inset(node.rect, insets_of(u, node.flow.padding))
	flow: Flow_Layout
	flow_begin(&flow, content, space_px(u, node.flow.gap_x), space_px(u, node.flow.gap_y))
	child := node.first_child
	for _ in 0 ..< MAX_PREPARED_NODES {
		if child < 0 do break
		value := &prepared.nodes[child]
		if value.kind != .Attachment do value.rect = flow_next(&flow, value.size.w, value.size.h)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_place_flow: child bound")
	_ = flow_end(&flow)
}

@(private = "file")
prepared_place_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_grid: invalid argument")
	node := &prepared.nodes[index]
	content := rect_inset(node.rect, insets_of(u, node.grid.padding))
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
	for _ in 0 ..< MAX_PREPARED_NODES {
		if child < 0 do break
		value := &prepared.nodes[child]
		if value.kind != .Attachment do value.rect = grid_next(&grid)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_place_grid: child bound")
	_ = grid_end(&grid)
}

@(private = "file")
prepared_place_children :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, widths_only: bool) {
	assert(u != nil && prepared != nil, "prepared_place_children: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_place_children: index out of range")
	node := &prepared.nodes[index]
	content := rect_inset(node.rect, insets_of(u, node.container.padding))
	children: [MAX_LAYOUT_FLEX]i32
	tracks: [MAX_LAYOUT_FLEX]Track
	count := prepared_children(prepared, node.first_child, &children)
	if count == 0 do return
	for child_index in 0 ..< count {
		child := &prepared.nodes[children[child_index]]
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
		child := &prepared.nodes[children[child_index]]
		cross_size := child.size.h if node.kind == .Row else child.size.w
		rect := flex_next_sized(&layout, cross_size)
		if widths_only {
			child.rect.w = rect.w
			child.rect.h = max(rect.h, child.size.h)
		} else {
			child.rect = rect
		}
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
	for _ in 0 ..< MAX_PREPARED_NODES {
		if child < 0 do break
		assert(child < prepared.count, "prepared_children: bad child")
		value := &prepared.nodes[child]
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
prepared_track_px :: proc(u: ^Ui, node: ^Prepared_Node, parent_kind: Prepared_Kind) -> Track {
	assert(u != nil && node != nil, "prepared_track_px: invalid argument")
	assert(parent_kind == .Row || parent_kind == .Column, "prepared_track_px: invalid parent")
	track := node.track
	if track.kind == .Fit && track.basis == 0 && track.min_size == 0 && track.max_size == 0 {
		basis := node.size.w if parent_kind == .Row else node.size.h
		return fit(basis)
	}
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(ui_frame_sc(u.frame, track.basis), minimum, maximum)
	case .Grow:
		return grow(track.weight, minimum, maximum)
	case .Fixed:
		return fixed(ui_frame_sc(u.frame, track.basis))
	case .Percent:
		return percent(track.percent, minimum, maximum)
	}
	unreachable()
}

Prepared_Render_Frame :: struct {
	index:      i32,
	next_child: i32,
}

@(private = "file")
prepared_render_tree :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_render_tree: invalid argument")
	root := &prepared.nodes[prepared.root]
	assert(prepared_kind_is_container(root.kind), "prepared_render_tree: leaf root")
	stack: [MAX_LAYOUT_DEPTH]Prepared_Render_Frame
	prepared_render_enter(u, root)
	stack[0] = {
		index      = prepared.root,
		next_child = root.first_child,
	}
	depth := 1
	for depth > 0 {
		frame := &stack[depth - 1]
		if frame.next_child < 0 {
			prepared_render_exit(u, &prepared.nodes[frame.index])
			depth -= 1
			continue
		}
		child_index := frame.next_child
		child := &prepared.nodes[child_index]
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

@(private = "file")
prepared_kind_is_container :: proc(kind: Prepared_Kind) -> bool {
	return kind == .Row || kind == .Column || kind == .Flow || kind == .Grid || kind == .Attachment
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
	effects := prepared_container_effects(node)
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
	case .Attachment, .Label, .Button, .Custom:
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
	case .Custom:
		node.activated = node.custom.render(u, node.rect, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Attachment:
		unreachable()
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
