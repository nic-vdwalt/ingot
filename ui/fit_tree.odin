package ui

Fit_Kind :: enum u8 {
	Row,
	Column,
	Label,
	Button,
	Custom,
}

Fit_Button_Key_Kind :: enum u8 {
	Widget,
	String,
	U64,
	Spec,
}

Fit_Label_Options :: struct {
	role:  Text_Role,
	ink:   Ink,
	wrap:  bool,
	track: Track,
}

Fit_Button_Options :: struct {
	style:       Btn_Style,
	disabled:    bool,
	web_form_id: string,
	track:       Track,
	activated:   ^bool,
}

Fit_Custom_Options :: struct {
	track:     Track,
	activated: ^bool,
}

Fit_Button :: struct {
	key_kind: Fit_Button_Key_Kind,
	widget:   Widget_Id,
	key:      string,
	key_u64:  u64,
	label:    string,
	options:  Button_Options,
	spec:     Button_Spec,
}

Fit_Node :: struct {
	kind:      Fit_Kind,
	track:     Track,
	container: Prepared_Container_Options,
	label:     Label_Spec,
	button:    Fit_Button,
	custom:    Prepared_Custom,
	activated: ^bool,
	children:  []Fit_Node,
}

@(private = "file")
Fit_Walk_Item :: struct {
	node: ^Fit_Node,
	exit: bool,
}

fit_row :: proc(options: Prepared_Container_Options, children: []Fit_Node) -> Fit_Node {
	assert(len(children) <= MAX_LAYOUT_FLEX, "fit_row: too many direct children")
	return {kind = .Row, track = options.track, container = options, children = children}
}

fit_column :: proc(options: Prepared_Container_Options, children: []Fit_Node) -> Fit_Node {
	assert(len(children) <= MAX_LAYOUT_FLEX, "fit_column: too many direct children")
	return {kind = .Column, track = options.track, container = options, children = children}
}

fit_label :: proc(text: string, options: Fit_Label_Options = {}) -> Fit_Node {
	assert(text != "", "fit_label: empty text")
	return {
		kind = .Label,
		track = options.track,
		label = {text = text, role = options.role, ink = options.ink, wrap = options.wrap},
	}
}

@(private = "package")
fit_button_string :: proc(key, label: string, options: Fit_Button_Options = {}) -> Fit_Node {
	assert(key != "" && label != "", "fit_button_string: invalid button")
	return fit_button_node(.String, WIDGET_ID_NONE, key, 0, label, options)
}

@(private = "package")
fit_button_u64 :: proc(key: u64, label: string, options: Fit_Button_Options = {}) -> Fit_Node {
	assert(label != "", "fit_button_u64: empty label")
	return fit_button_node(.U64, WIDGET_ID_NONE, "", key, label, options)
}

@(private = "package")
fit_button_id :: proc(
	widget: Widget_Id,
	label: string,
	options: Fit_Button_Options = {},
) -> Fit_Node {
	assert(widget != WIDGET_ID_NONE && label != "", "fit_button_id: invalid button")
	return fit_button_node(.Widget, widget, "", 0, label, options)
}

@(private = "package")
fit_button_spec :: proc(spec: Button_Spec, track: Track = {}, activated: ^bool = nil) -> Fit_Node {
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "fit_button_spec: invalid spec")
	return {
		kind = .Button,
		track = track,
		button = {key_kind = .Spec, spec = spec},
		activated = activated,
	}
}

@(private = "package")
fit_button_string_active :: proc(key, label: string, activated: ^bool) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_string(key, label, Fit_Button_Options{activated = activated})
}

@(private = "package")
fit_button_string_styled_active :: proc(
	key, label: string,
	style: Btn_Style,
	activated: ^bool,
) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_string(key, label, {style = style, activated = activated})
}

@(private = "package")
fit_button_u64_active :: proc(key: u64, label: string, activated: ^bool) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_u64(key, label, Fit_Button_Options{activated = activated})
}

@(private = "package")
fit_button_u64_styled_active :: proc(
	key: u64,
	label: string,
	style: Btn_Style,
	activated: ^bool,
) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_u64(key, label, {style = style, activated = activated})
}

@(private = "package")
fit_button_id_active :: proc(widget: Widget_Id, label: string, activated: ^bool) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_id(widget, label, Fit_Button_Options{activated = activated})
}

@(private = "package")
fit_button_id_styled_active :: proc(
	widget: Widget_Id,
	label: string,
	style: Btn_Style,
	activated: ^bool,
) -> Fit_Node {
	assert(activated != nil, "fit_button: nil activation destination")
	return fit_button_id(widget, label, {style = style, activated = activated})
}

fit_button :: proc {
	fit_button_string,
	fit_button_string_active,
	fit_button_string_styled_active,
	fit_button_u64,
	fit_button_u64_active,
	fit_button_u64_styled_active,
	fit_button_id,
	fit_button_id_active,
	fit_button_id_styled_active,
	fit_button_spec,
}

fit_custom :: proc(spec: Prepared_Custom, options: Fit_Custom_Options = {}) -> Fit_Node {
	assert(spec.measure != nil && spec.render != nil, "fit_custom: invalid callbacks")
	return {kind = .Custom, track = options.track, custom = spec, activated = options.activated}
}

fit_nodes :: proc(u: ^Ui, capacity: int = MAX_PREPARED_NODES) -> [dynamic]Fit_Node {
	assert(u != nil && u.open && u.frame != nil, "fit_nodes: invalid UI")
	assert(capacity >= 0 && capacity <= MAX_PREPARED_NODES, "fit_nodes: capacity out of range")
	return make([dynamic]Fit_Node, 0, capacity, ui_frame_allocator(u.frame))
}

fit_tree :: proc(u: ^Ui, root: Fit_Node) -> Rect_I32 {
	assert(u != nil && u.open && u.frame != nil, "fit_tree: invalid UI")
	prepared: Prepared_Ui
	outputs: [MAX_PREPARED_NODES]^bool
	root_value := root
	prepared_begin(&prepared, intrinsic_constraints(max_w = remaining_rect(u).w))
	fit_tree_lower(u, &prepared, &root_value, &outputs)
	fit_outputs_clear(&outputs)
	rect := prepared_fit(u, &prepared)
	fit_outputs_publish(&prepared, &outputs)
	return rect
}

@(private = "package")
fit_outputs_clear :: proc(outputs: ^[MAX_PREPARED_NODES]^bool) {
	assert(outputs != nil, "fit_outputs_clear: nil outputs")
	for destination in outputs {
		if destination != nil do destination^ = false
	}
}

@(private = "package")
fit_outputs_publish :: proc(prepared: ^Prepared_Ui, outputs: ^[MAX_PREPARED_NODES]^bool) {
	assert(prepared != nil && prepared.rendered, "fit_outputs_publish: not rendered")
	assert(outputs != nil, "fit_outputs_publish: nil outputs")
	for destination, index in outputs {
		if destination != nil {
			destination^ = destination^ || prepared.nodes[index].activated
		}
	}
}

@(private = "file")
fit_button_node :: proc(
	key_kind: Fit_Button_Key_Kind,
	widget: Widget_Id,
	key: string,
	key_u64: u64,
	label: string,
	options: Fit_Button_Options,
) -> Fit_Node {
	assert(key_kind != .Spec, "fit_button_node: explicit spec uses spec overload")
	assert(label != "", "fit_button_node: empty label")
	return {
		kind = .Button,
		track = options.track,
		button = {
			key_kind = key_kind,
			widget = widget,
			key = key,
			key_u64 = key_u64,
			label = label,
			options = {
				style = options.style,
				disabled = options.disabled,
				web_form_id = options.web_form_id,
			},
		},
		activated = options.activated,
	}
}

@(private = "file")
fit_tree_lower :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	root: ^Fit_Node,
	outputs: ^[MAX_PREPARED_NODES]^bool,
) {
	assert(u != nil && prepared != nil && root != nil && outputs != nil)
	stack: [MAX_PREPARED_NODES * 2]Fit_Walk_Item
	stack[0] = {
		node = root,
	}
	stack_count := 1
	node_count := 0
	steps := 0
	for stack_count > 0 {
		assert(steps < MAX_PREPARED_NODES * 2, "fit_tree_lower: traversal bound")
		stack_count -= 1
		item := stack[stack_count]
		if item.exit {
			prepared_container_end(prepared)
			steps += 1
			continue
		}
		assert(node_count < MAX_PREPARED_NODES, "fit_tree_lower: nodes full")
		node_count += 1
		node := item.node
		fit_tree_lower_node(u, prepared, node, outputs)
		if node.kind == .Row || node.kind == .Column {
			assert(stack_count < len(stack), "fit_tree_lower: stack full")
			stack[stack_count] = {
				node = node,
				exit = true,
			}
			stack_count += 1
			for offset in 0 ..< len(node.children) {
				index := len(node.children) - 1 - offset
				assert(stack_count < len(stack), "fit_tree_lower: stack full")
				stack[stack_count] = {
					node = &node.children[index],
				}
				stack_count += 1
			}
		}
		steps += 1
	}
	assert(prepared.depth == 0, "fit_tree_lower: unbalanced output")
	assert(node_count > 0 && node_count <= MAX_PREPARED_NODES)
}

@(private = "file")
fit_tree_lower_node :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	node: ^Fit_Node,
	outputs: ^[MAX_PREPARED_NODES]^bool,
) {
	assert(u != nil && prepared != nil && node != nil && outputs != nil)
	switch node.kind {
	case .Row, .Column:
		assert(len(node.children) <= MAX_LAYOUT_FLEX, "fit_tree_lower_node: children full")
		assert(
			node.label.text == "" && node.activated == nil,
			"fit_tree_lower_node: bad container",
		)
		if node.kind == .Row {
			_ = prepared_row_begin(prepared, node.container)
		} else {
			_ = prepared_column_begin(prepared, node.container)
		}
	case .Label:
		assert(len(node.children) == 0 && node.label.text != "", "fit_tree_lower_node: bad label")
		_ = prepared_label(prepared, node.label, node.track)
	case .Button:
		assert(len(node.children) == 0, "fit_tree_lower_node: button has children")
		handle := fit_tree_button(u, prepared, node)
		outputs[i32(handle)] = node.activated
	case .Custom:
		assert(len(node.children) == 0, "fit_tree_lower_node: custom has children")
		assert(
			node.custom.measure != nil && node.custom.render != nil,
			"fit_tree_lower_node: bad custom",
		)
		handle := prepared_custom(prepared, node.custom, node.track)
		outputs[i32(handle)] = node.activated
	}
}

@(private = "file")
fit_tree_button :: proc(u: ^Ui, prepared: ^Prepared_Ui, node: ^Fit_Node) -> Prepared_Handle {
	assert(u != nil && prepared != nil && node != nil, "fit_tree_button: invalid argument")
	assert(node.kind == .Button, "fit_tree_button: wrong kind")
	button := node.button
	switch button.key_kind {
	case .Widget:
		return prepared_button(
			prepared,
			button_spec(u, button.widget, button.label, button.options),
			node.track,
		)
	case .String:
		return prepared_button(
			prepared,
			button_spec(u, id(u, button.key), button.label, button.options),
			node.track,
		)
	case .U64:
		return prepared_button(
			prepared,
			button_spec(u, id(u, button.key_u64), button.label, button.options),
			node.track,
		)
	case .Spec:
		return prepared_button(prepared, button.spec, node.track)
	}
	unreachable()
}
