package ui

TREE_ITEM_COUNT_MAX :: 256
TREE_DEPTH_MAX :: 16

Tree_Item :: struct {
	id:           u64,
	label:        string,
	description:  string,
	depth:        int,
	has_children: bool,
	expanded:     ^bool,
	disabled:     bool,
}

Tree_State :: struct {
	listbox:       Listbox_State,
	selected_index: int,
	initialized:   bool,
}

Tree_Config :: struct {
	rect:         Rect_I32,
	label:        string,
	stable_id:    string,
	items:        []Tree_Item,
	selected:     ^u64,
	row_height:   i32,
	indent:       i32,
	page_rows:    int,
	wrap:         bool,
	hover_select: bool,
	keys:         Listbox_Keys,
}

Tree_Result :: struct {
	selection_changed: bool,
	expanded_changed:  bool,
	activated:         bool,
	activated_id:      u64,
	reveal:            bool,
	reveal_index:      int,
}

tree_selected_index :: proc(items: []Tree_Item, selected: u64) -> int {
	for item, index in items do if item.id == selected do return index
	return -1
}

tree_parent_index :: proc(items: []Tree_Item, index: int) -> int {
	assert(index >= 0 && index < len(items), "tree_parent_index: index out of range")
	depth := items[index].depth
	if depth == 0 do return -1
	for step in 1 ..= index {
		candidate := index - step
		if items[candidate].depth == depth - 1 do return candidate
	}
	return -1
}

tree_first_child_index :: proc(items: []Tree_Item, index: int) -> int {
	assert(index >= 0 && index < len(items), "tree_first_child_index: index out of range")
	child := index + 1
	if child < len(items) && items[child].depth == items[index].depth + 1 do return child
	return -1
}

@(private = "file")
tree_validate :: proc(items: []Tree_Item) {
	assert(len(items) <= TREE_ITEM_COUNT_MAX, "tree: too many items")
	for item, index in items {
		assert(item.id != 0 && item.label != "", "tree: invalid item")
		assert(item.depth >= 0 && item.depth < TREE_DEPTH_MAX, "tree: depth out of range")
		assert(item.has_children == (item.expanded != nil), "tree: expansion state mismatch")
		if index == 0 do assert(item.depth == 0, "tree: first item is not a root")
		if index > 0 do assert(item.depth <= items[index - 1].depth + 1, "tree: invalid depth jump")
		for previous in 0 ..< index do assert(items[previous].id != item.id, "tree: duplicate id")
	}
}

@(private = "file")
tree_first_enabled :: proc(items: []Tree_Item) -> int {
	for item, index in items do if !item.disabled do return index
	return -1
}

@(private = "file")
tree_row :: proc(
	frame: ^Ui_Frame,
	state: ^Tree_State,
	config: Tree_Config,
	list_config: Listbox_Config,
	index: int,
) -> Selectable_Row_Result {
	item := &config.items[index]
	rect := Rect_I32 {
		config.rect.x,
		config.rect.y + i32(index) * config.row_height,
		config.rect.w,
		config.row_height,
	}
	result := selectable_row(
		frame,
		&state.listbox,
		list_config,
		{
			rect = rect,
			label = item.label,
			stable_id = item.label,
			index = index,
			disabled = item.disabled,
			description = item.description,
		},
	)
	list_row_bg_at(frame, rect, result.selected, result.hovered)
	metrics := ui_frame_metrics(frame)
	text_x := rect.x + config.indent * i32(item.depth) + metrics.CONTROL_GAP
	if item.has_children {
		marker := "▾" if item.expanded^ else "▸"
		draw_text_string_frame(frame, marker, text_x, rect.y, metrics.FONT_SIZE_BODY, ui_frame_theme(frame).fg_secondary)
		text_x += config.indent
	}
	draw_text_string_frame(frame, item.label, text_x, rect.y, metrics.FONT_SIZE_BODY, ui_frame_theme(frame).fg_primary)
	return result
}

tree :: proc(frame: ^Ui_Frame, state: ^Tree_State, config: Tree_Config) -> Tree_Result {
	assert(frame != nil && frame.open && state != nil, "tree: invalid frame")
	assert(config.selected != nil && config.label != "" && config.stable_id != "", "tree: invalid config")
	assert(config.row_height > 0 && config.indent > 0 && config.page_rows >= 0, "tree: invalid geometry")
	tree_validate(config.items)
	result := Tree_Result{reveal_index = -1}
	if len(config.items) == 0 {
		config.selected^ = 0
		state.selected_index = -1
		return result
	}
	selected := tree_selected_index(config.items, config.selected^)
	if selected < 0 || config.items[selected].disabled do selected = tree_first_enabled(config.items)
	if selected < 0 {
		config.selected^ = 0
		state.selected_index = -1
		return result
	}
	state.selected_index = selected
	list_config := Listbox_Config {
		rect = config.rect,
		label = config.label,
		stable_id = config.stable_id,
		count = len(config.items),
		selected = &state.selected_index,
		wrap = config.wrap,
		hover_select = config.hover_select,
		keys = config.keys,
		page_rows = config.page_rows,
	}
	list_result := listbox_begin(frame, &state.listbox, list_config)
	for index in 0 ..< len(config.items) {
		row := tree_row(frame, state, config, list_config, index)
		if row.activated && !config.items[index].disabled {
			result.activated = true
			result.activated_id = config.items[index].id
		}
	}
	listbox_end(frame, &state.listbox)
	result.selection_changed = list_result.selection_changed || config.selected^ != config.items[state.selected_index].id
	config.selected^ = config.items[state.selected_index].id
	result.reveal = list_result.reveal
	result.reveal_index = list_result.reveal_index
	if listbox_keyboard_live(&state.listbox, list_config) {
		item := &config.items[state.selected_index]
		if is_key_pressed(frame, .RIGHT) && item.has_children && !item.expanded^ {
			item.expanded^ = true
			result.expanded_changed = true
		} else if is_key_pressed(frame, .LEFT) && item.has_children && item.expanded^ {
			item.expanded^ = false
			result.expanded_changed = true
		}
	}
	return result
}
