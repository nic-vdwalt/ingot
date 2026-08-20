// Minimal Odin bindings to the AccessKit C API (accesskit_c 0.22.3) - just
// the surface ingot's accessibility bridge needs: node/tree-update builders
// and the per-platform window adapters. Prebuilt static libraries ship next
// to this package (lib/<platform_arch>/, see scripts/build-accesskit.sh) so
// consumers need no extra linker flags, mirroring the libvterm package.
//
// Disable at compile time with -define:INGOT_ACCESSKIT=false; gfx guards all
// calls behind `when accesskit.ENABLED`, so opting out removes the link
// dependency entirely.
package accesskit

import "core:c"

// ENABLED is false on platforms without a committed AccessKit adapter (the web
// target uses the DOM mirror instead) and when compiled out via
// -define:INGOT_ACCESSKIT=false. Linux arm64 stays disabled until a verified
// accesskit-c archive is available for that architecture.
PLATFORM_SUPPORTED ::
	ODIN_OS == .Darwin || ODIN_OS == .Windows || (ODIN_OS == .Linux && ODIN_ARCH == .amd64)
ENABLED :: #config(INGOT_ACCESSKIT, true) && PLATFORM_SUPPORTED

#assert(!(ODIN_OS == .Linux && ODIN_ARCH != .amd64) || !ENABLED)

// ---------------------------------------------------------------------------
// Types (mirror accesskit.h; explicit ordinals for sparse enums)
// ---------------------------------------------------------------------------

Node_Id :: u64

Tree_Id :: struct {
	bytes: [16]u8,
}

// Role values are ordinals into accesskit.h's `enum accesskit_role`; only the
// roles ingot emits are named (the C enum has ~190 entries).
Role :: enum u8 {
	Unknown         = 0,
	Label           = 3,
	List_Item       = 7,
	List_Box_Option = 10,
	Menu_Item       = 11,
	Check_Box       = 15,
	Radio_Button    = 16,
	Text_Input      = 17,
	Button          = 18,
	Pane            = 20,
	List            = 24,
	Menu            = 30,
	Multiline_Input = 31,
	Password_Input  = 40,
	Combo_Box       = 56,
	Dialog          = 66,
	List_Box        = 87,
	Progress        = 101,
	Slider          = 113,
	Status          = 116,
	Tab             = 120,
	Tab_Panel       = 122,
	Window          = 133,
}

Action :: enum u8 {
	Click     = 0,
	Focus     = 1,
	Blur      = 2,
	Collapse  = 3,
	Expand    = 4,
	Custom    = 5,
	Decrement = 6,
	Increment = 7,
}

Toggled :: enum u8 {
	False = 0,
	True  = 1,
	Mixed = 2,
}

Rect :: struct {
	x0, y0: f64, // left, top
	x1, y1: f64, // right, bottom
}

Point :: struct {
	x, y: f64,
}

Text_Position :: struct {
	node:            Node_Id,
	character_index: c.size_t,
}

Text_Selection :: struct {
	anchor: Text_Position,
	focus:  Text_Position,
}

Action_Data_Tag :: enum c.int {
	Custom_Action      = 0,
	Value              = 1,
	Numeric_Value      = 2,
	Scroll_Unit        = 3,
	Scroll_Hint        = 4,
	Scroll_To_Point    = 5,
	Set_Scroll_Offset  = 6,
	Set_Text_Selection = 7,
}

Action_Data :: struct {
	tag:     Action_Data_Tag,
	using _: struct #raw_union {
		custom_action:      i32,
		value:              cstring,
		numeric_value:      f64,
		scroll_unit:        c.int,
		scroll_hint:        c.int,
		scroll_to_point:    Point,
		set_scroll_offset:  Point,
		set_text_selection: Text_Selection,
	},
}

Opt_Action_Data :: struct {
	has_value: bool,
	value:     Action_Data,
}

Action_Request :: struct {
	action:      Action,
	target_tree: Tree_Id,
	target_node: Node_Id,
	data:        Opt_Action_Data,
}

// Opaque handles.
Node :: distinct rawptr
Tree :: distinct rawptr
Tree_Update :: distinct rawptr
Macos_Subclassing_Adapter :: distinct rawptr
Macos_Queued_Events :: distinct rawptr
Windows_Subclassing_Adapter :: distinct rawptr
Windows_Queued_Events :: distinct rawptr
Unix_Adapter :: distinct rawptr

// Tree_Update_Factory builds and returns a full tree update; ownership of the
// returned update transfers to AccessKit. Called only while AT is active.
Tree_Update_Factory :: proc "c" (userdata: rawptr) -> Tree_Update

// Activation_Handler fires when assistive tech first requests the tree.
Activation_Handler :: proc "c" (userdata: rawptr) -> Tree_Update

// Action_Handler receives AT-initiated actions; the request must be freed
// with action_request_free. May be called off the main thread.
Action_Handler :: proc "c" (request: ^Action_Request, userdata: rawptr)

// Deactivation_Handler fires when AT stops consuming the tree (unix only).
Deactivation_Handler :: proc "c" (userdata: rawptr)

// ---------------------------------------------------------------------------
// Foreign library import (same relative-lib pattern as libvterm)
// ---------------------------------------------------------------------------

when ENABLED {
	when ODIN_OS == .Linux {
		@(extra_linker_flags = "-Wl,--allow-multiple-definition")
		foreign import lib "lib/linux_amd64/libaccesskit.a"
	} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
		foreign import lib "lib/darwin_arm64/libaccesskit.a"
	} else when ODIN_OS == .Darwin {
		foreign import lib "lib/darwin_amd64/libaccesskit.a"
	} else when ODIN_OS == .Windows {
		@(extra_linker_flags = "/FORCE:MULTIPLE")
		foreign import lib "lib/windows_amd64/accesskit.lib"
	}

	@(default_calling_convention = "c", link_prefix = "accesskit_")
	foreign lib {
		// Node builder. node_new allocates; ownership transfers to the tree
		// update via tree_update_push_node.
		node_new :: proc(role: Role) -> Node ---
		node_free :: proc(node: Node) ---
		node_set_label_with_length :: proc(node: Node, value: [^]u8, length: c.size_t) ---
		node_set_description_with_length :: proc(node: Node, value: [^]u8, length: c.size_t) ---
		node_set_value_with_length :: proc(node: Node, value: [^]u8, length: c.size_t) ---
		node_set_bounds :: proc(node: Node, value: Rect) ---
		node_set_toggled :: proc(node: Node, value: Toggled) ---
		node_set_disabled :: proc(node: Node) ---
		node_set_read_only :: proc(node: Node) ---
		node_set_text_selection :: proc(node: Node, value: Text_Selection) ---
		node_set_expanded :: proc(node: Node, value: bool) ---
		node_set_numeric_value :: proc(node: Node, value: f64) ---
		node_set_min_numeric_value :: proc(node: Node, value: f64) ---
		node_set_max_numeric_value :: proc(node: Node, value: f64) ---
		node_set_size_of_set :: proc(node: Node, value: c.size_t) ---
		node_set_position_in_set :: proc(node: Node, value: c.size_t) ---
		node_set_selected :: proc(node: Node, value: bool) ---
		node_add_action :: proc(node: Node, action: Action) ---
		node_push_child :: proc(node: Node, child: Node_Id) ---

		// Tree + tree update.
		tree_new :: proc(root: Node_Id) -> Tree ---
		tree_free :: proc(tree: Tree) ---
		tree_update_with_capacity_and_focus :: proc(capacity: c.size_t, focus: Node_Id) -> Tree_Update ---
		tree_update_free :: proc(update: Tree_Update) ---
		tree_update_push_node :: proc(update: Tree_Update, id: Node_Id, node: Node) ---
		tree_update_set_tree :: proc(update: Tree_Update, tree: Tree) ---
		tree_update_set_focus :: proc(update: Tree_Update, focus: Node_Id) ---

		action_request_free :: proc(request: ^Action_Request) ---
	}

	when ODIN_OS == .Darwin {
		@(default_calling_convention = "c", link_prefix = "accesskit_")
		foreign lib {
			macos_subclassing_adapter_new :: proc(view: rawptr, activation_handler: Activation_Handler, activation_handler_userdata: rawptr, action_handler: Action_Handler, action_handler_userdata: rawptr) -> Macos_Subclassing_Adapter ---
			macos_subclassing_adapter_for_window :: proc(window: rawptr, activation_handler: Activation_Handler, activation_handler_userdata: rawptr, action_handler: Action_Handler, action_handler_userdata: rawptr) -> Macos_Subclassing_Adapter ---
			macos_subclassing_adapter_free :: proc(adapter: Macos_Subclassing_Adapter) ---
			macos_subclassing_adapter_update_if_active :: proc(adapter: Macos_Subclassing_Adapter, update_factory: Tree_Update_Factory, update_factory_userdata: rawptr) -> Macos_Queued_Events ---
			macos_subclassing_adapter_update_view_focus_state :: proc(adapter: Macos_Subclassing_Adapter, is_focused: bool) -> Macos_Queued_Events ---
			macos_queued_events_raise :: proc(events: Macos_Queued_Events) ---
		}
	}

	when ODIN_OS == .Windows {
		@(default_calling_convention = "c", link_prefix = "accesskit_")
		foreign lib {
			windows_subclassing_adapter_new :: proc(hwnd: rawptr, activation_handler: Activation_Handler, activation_handler_userdata: rawptr, action_handler: Action_Handler, action_handler_userdata: rawptr) -> Windows_Subclassing_Adapter ---
			windows_subclassing_adapter_free :: proc(adapter: Windows_Subclassing_Adapter) ---
			windows_subclassing_adapter_update_if_active :: proc(adapter: Windows_Subclassing_Adapter, update_factory: Tree_Update_Factory, update_factory_userdata: rawptr) -> Windows_Queued_Events ---
			windows_queued_events_raise :: proc(events: Windows_Queued_Events) ---
		}
	}

	when ODIN_OS == .Linux {
		@(default_calling_convention = "c", link_prefix = "accesskit_")
		foreign lib {
			unix_adapter_new :: proc(activation_handler: Activation_Handler, activation_handler_userdata: rawptr, action_handler: Action_Handler, action_handler_userdata: rawptr, deactivation_handler: Deactivation_Handler, deactivation_handler_userdata: rawptr) -> Unix_Adapter ---
			unix_adapter_free :: proc(adapter: Unix_Adapter) ---
			unix_adapter_set_root_window_bounds :: proc(adapter: Unix_Adapter, outer, inner: Rect) ---
			unix_adapter_update_if_active :: proc(adapter: Unix_Adapter, update_factory: Tree_Update_Factory, update_factory_userdata: rawptr) ---
			unix_adapter_update_window_focus_state :: proc(adapter: Unix_Adapter, is_focused: bool) ---
		}
	}
}
