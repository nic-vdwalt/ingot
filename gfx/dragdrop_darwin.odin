#+build darwin
package gfx

import NS "core:sys/darwin/Foundation"
import "base:intrinsics"

foreign import dd_objc "system:objc"
@(default_calling_convention = "c")
foreign dd_objc {
	objc_allocateClassPair :: proc(superclass: rawptr, name: cstring, extra_bytes: uint) -> rawptr ---
	objc_registerClassPair :: proc(class: rawptr) ---
	objc_disposeClassPair   :: proc(class: rawptr) ---
	object_setClass         :: proc(object, class: rawptr) -> rawptr ---
}

Drag_Op_Proc :: #type proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> u64
Drag_Void_Proc :: #type proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id)
Drag_Bool_Proc :: #type proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> NS.BOOL

NS_DRAG_OP_COPY :: 1

@(private = "file") g_dd_orig_entered: Drag_Op_Proc
@(private = "file") g_dd_orig_updated: Drag_Op_Proc
@(private = "file") g_dd_orig_exited: Drag_Void_Proc
@(private = "file") g_dd_orig_ended: Drag_Void_Proc
@(private = "file") g_dd_orig_perform: Drag_Bool_Proc
@(private = "file") g_dd_view: rawptr
@(private = "file") g_dd_original_class: rawptr
@(private = "file") g_dd_subclass: rawptr

@(private = "file")
dd_entered_hook :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> u64 {
	_drop_hover_stage(true)
	_idle_note_activity(&g.idle)
	if g_dd_orig_entered != nil do return g_dd_orig_entered(self, cmd, sender)
	return NS_DRAG_OP_COPY
}

@(private = "file")
dd_updated_hook :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> u64 {
	_drop_hover_stage(true)
	if g_dd_orig_updated != nil do return g_dd_orig_updated(self, cmd, sender)
	return NS_DRAG_OP_COPY
}

@(private = "file")
dd_exited_hook :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	_drop_hover_stage(false)
	_idle_note_activity(&g.idle)
	if g_dd_orig_exited != nil do g_dd_orig_exited(self, cmd, sender)
}

@(private = "file")
dd_ended_hook :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	_drop_hover_stage(false)
	_idle_note_activity(&g.idle)
	if g_dd_orig_ended != nil do g_dd_orig_ended(self, cmd, sender)
}

@(private = "file")
dd_perform_hook :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> NS.BOOL {
	_drop_hover_stage(false)
	_idle_note_activity(&g.idle)
	if g_dd_orig_perform != nil do return g_dd_orig_perform(self, cmd, sender)
	return false
}

@(private)
platform_dragdrop_init :: proc() {
	if g_dd_subclass != nil do return
	window := cast(^IME_NS_Window)GetWindowHandle()
	if window == nil do return
	view := intrinsics.objc_send(NS.id, window, "contentView")
	if view == nil do return
	original_class := rawptr(NS.object_getClass(view))
	if original_class == nil do return
	subclass := objc_allocateClassPair(original_class, "IngotDropContentView", 0)
	if subclass == nil do return
	if !dd_install_methods(original_class, subclass) {
		objc_disposeClassPair(subclass)
		return
	}
	objc_registerClassPair(subclass)
	g_dd_view = rawptr(view)
	g_dd_original_class = original_class
	g_dd_subclass = subclass
	object_setClass(g_dd_view, g_dd_subclass)
}

@(private = "file")
dd_install_methods :: proc(original_class, subclass: rawptr) -> bool {
	g_dd_orig_entered = dd_original_op(original_class, "draggingEntered:")
	g_dd_orig_updated = dd_original_op(original_class, "draggingUpdated:")
	g_dd_orig_exited = dd_original_void(original_class, "draggingExited:")
	g_dd_orig_ended = dd_original_void(original_class, "draggingEnded:")
	g_dd_orig_perform = dd_original_bool(original_class, "performDragOperation:")
	if g_dd_orig_entered == nil || g_dd_orig_perform == nil do return false
	class := NS.Class(subclass)
	NS.class_addMethod(class, NS.sel_registerName("draggingEntered:"), cast(NS.IMP)dd_entered_hook, "Q@:@")
	NS.class_addMethod(class, NS.sel_registerName("draggingUpdated:"), cast(NS.IMP)dd_updated_hook, "Q@:@")
	NS.class_addMethod(class, NS.sel_registerName("draggingExited:"), cast(NS.IMP)dd_exited_hook, "v@:@")
	NS.class_addMethod(class, NS.sel_registerName("draggingEnded:"), cast(NS.IMP)dd_ended_hook, "v@:@")
	NS.class_addMethod(class, NS.sel_registerName("performDragOperation:"), cast(NS.IMP)dd_perform_hook, "B@:@")
	return true
}

@(private = "file")
dd_original_op :: proc(class: rawptr, name: cstring) -> Drag_Op_Proc {
	method := NS.class_getInstanceMethod(NS.Class(class), NS.sel_registerName(name))
	if method == nil do return nil
	return cast(Drag_Op_Proc)NS.method_getImplementation(method)
}

@(private = "file")
dd_original_void :: proc(class: rawptr, name: cstring) -> Drag_Void_Proc {
	method := NS.class_getInstanceMethod(NS.Class(class), NS.sel_registerName(name))
	if method == nil do return nil
	return cast(Drag_Void_Proc)NS.method_getImplementation(method)
}

@(private = "file")
dd_original_bool :: proc(class: rawptr, name: cstring) -> Drag_Bool_Proc {
	method := NS.class_getInstanceMethod(NS.Class(class), NS.sel_registerName(name))
	if method == nil do return nil
	return cast(Drag_Bool_Proc)NS.method_getImplementation(method)
}

@(private)
platform_dragdrop_tick :: proc() {
	if g_dd_subclass == nil do platform_dragdrop_init()
}

@(private)
platform_dragdrop_shutdown :: proc() {
	if g_dd_view != nil && g_dd_original_class != nil do object_setClass(g_dd_view, g_dd_original_class)
	if g_dd_subclass != nil do objc_disposeClassPair(g_dd_subclass)
	g_dd_orig_entered, g_dd_orig_updated = nil, nil
	g_dd_orig_exited, g_dd_orig_ended, g_dd_orig_perform = nil, nil, nil
	g_dd_view, g_dd_original_class, g_dd_subclass = nil, nil, nil
	_drop_hover_stage(false)
}
