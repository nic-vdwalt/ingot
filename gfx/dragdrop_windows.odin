#+build windows
package gfx

import "base:runtime"
import win "core:sys/windows"

foreign import ole32 "system:ole32.lib"

@(default_calling_convention = "system")
foreign ole32 {
	OleInitialize    :: proc(reserved: rawptr) -> win.HRESULT ---
	OleUninitialize  :: proc() ---
	RegisterDragDrop :: proc(hwnd: win.HWND, target: rawptr) -> win.HRESULT ---
	RevokeDragDrop   :: proc(hwnd: win.HWND) -> win.HRESULT ---
	ReleaseStgMedium :: proc(medium: ^DD_Storage_Medium) ---
}

DD_CF_HDROP :: 15
DD_DVASPECT_CONTENT :: 1
DD_TYMED_HGLOBAL :: 1
DD_EFFECT_NONE :: win.DWORD(0)
DD_EFFECT_COPY :: win.DWORD(1)
DD_ALL_FILES :: win.UINT(0xFFFFFFFF)

DD_Point :: struct {x, y: win.LONG}
DD_Format :: struct {
	format: u16,
	target_device: rawptr,
	aspect: win.DWORD,
	index: win.LONG,
	medium: win.DWORD,
}
DD_Storage_Medium :: struct {
	medium: win.DWORD,
	global: win.HGLOBAL,
	owner: rawptr,
}
DD_Data_VTable :: struct {
	QueryInterface: proc "system" (this: rawptr, id: win.REFIID, object: ^rawptr) -> win.HRESULT,
	AddRef: proc "system" (this: rawptr) -> win.ULONG,
	Release: proc "system" (this: rawptr) -> win.ULONG,
	GetData: proc "system" (this: rawptr, format: ^DD_Format, medium: ^DD_Storage_Medium) -> win.HRESULT,
}
DD_Data :: struct {vtable: ^DD_Data_VTable}
DD_Target_VTable :: struct {
	QueryInterface: proc "system" (this: rawptr, id: win.REFIID, object: ^rawptr) -> win.HRESULT,
	AddRef: proc "system" (this: rawptr) -> win.ULONG,
	Release: proc "system" (this: rawptr) -> win.ULONG,
	DragEnter: proc "system" (this, data: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT,
	DragOver: proc "system" (this: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT,
	DragLeave: proc "system" (this: rawptr) -> win.HRESULT,
	Drop: proc "system" (this, data: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT,
}
DD_Target :: struct {vtable: ^DD_Target_VTable}

@(private = "file") g_dd_target_id := win.GUID{
	0x00000122, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46},
}
@(private = "file") g_dd_vtable: DD_Target_VTable
@(private = "file") g_dd_target: DD_Target
@(private = "file") g_dd_hwnd: win.HWND
@(private = "file") g_dd_refs: win.ULONG = 1
@(private = "file") g_dd_registered: bool
@(private = "file") g_dd_ole_owned: bool
@(private = "file") g_dd_has_files: bool

@(private = "file")
dd_guid_equal :: proc "system" (left, right: ^win.GUID) -> bool {
	if left == nil || right == nil do return false
	if left.Data1 != right.Data1 || left.Data2 != right.Data2 || left.Data3 != right.Data3 do return false
	for i in 0 ..< len(left.Data4) {
		if left.Data4[i] != right.Data4[i] do return false
	}
	return true
}

@(private = "file")
dd_query_interface :: proc "system" (this: rawptr, id: win.REFIID, object: ^rawptr) -> win.HRESULT {
	if object == nil do return transmute(win.HRESULT)u32(0x80004003)
	if dd_guid_equal(id, win.IUnknown_UUID) || dd_guid_equal(id, &g_dd_target_id) {
		object^ = this
		dd_add_ref(this)
		return win.S_OK
	}
	object^ = nil
	return transmute(win.HRESULT)u32(0x80004002)
}

@(private = "file")
dd_add_ref :: proc "system" (this: rawptr) -> win.ULONG {
	g_dd_refs += 1
	return g_dd_refs
}

@(private = "file")
dd_release :: proc "system" (this: rawptr) -> win.ULONG {
	if g_dd_refs > 1 do g_dd_refs -= 1
	return g_dd_refs
}

@(private = "file")
dd_format :: proc() -> DD_Format {
	return {DD_CF_HDROP, nil, DD_DVASPECT_CONTENT, -1, DD_TYMED_HGLOBAL}
}

@(private = "file")
dd_get_medium :: proc(data: rawptr, medium: ^DD_Storage_Medium) -> bool {
	if data == nil || medium == nil do return false
	format := dd_format()
	object := cast(^DD_Data)data
	return !win.FAILED(object.vtable.GetData(data, &format, medium))
}

@(private = "file")
dd_drag_enter :: proc "system" (this, data: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT {
	context = runtime.default_context()
	medium: DD_Storage_Medium
	g_dd_has_files = dd_get_medium(data, &medium)
	if g_dd_has_files do ReleaseStgMedium(&medium)
	_drop_hover_stage(g_dd_has_files)
	_idle_note_activity(&g.idle)
	if effect != nil do effect^ = g_dd_has_files ? DD_EFFECT_COPY : DD_EFFECT_NONE
	return win.S_OK
}

@(private = "file")
dd_drag_over :: proc "system" (this: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT {
	if effect != nil do effect^ = g_dd_has_files ? DD_EFFECT_COPY : DD_EFFECT_NONE
	return win.S_OK
}

@(private = "file")
dd_drag_leave :: proc "system" (this: rawptr) -> win.HRESULT {
	g_dd_has_files = false
	_drop_hover_stage(false)
	_idle_note_activity(&g.idle)
	return win.S_OK
}

@(private = "file")
dd_drop :: proc "system" (this, data: rawptr, keys: win.DWORD, point: DD_Point, effect: ^win.DWORD) -> win.HRESULT {
	context = runtime.default_context()
	_drop_hover_stage(false)
	g_dd_has_files = false
	if effect != nil do effect^ = DD_EFFECT_NONE
	medium: DD_Storage_Medium
	if !dd_get_medium(data, &medium) do return win.S_OK
	defer ReleaseStgMedium(&medium)
	hdrop := win.HDROP(medium.global)
	count := min(int(win.DragQueryFileW(hdrop, DD_ALL_FILES, nil, 0)), MAX_DROPPED_FILES)
	paths: [MAX_DROPPED_FILES]string
	accepted := 0
	for i in 0 ..< count {
		length := win.DragQueryFileW(hdrop, win.UINT(i), nil, 0)
		if length == 0 || int(length) > MAX_DROPPED_PATH_BYTES do continue
		buffer := make([]u16, int(length) + 1, context.temp_allocator)
		copied := win.DragQueryFileW(hdrop, win.UINT(i), win.LPWSTR(raw_data(buffer)), length + 1)
		if copied != length do continue
		path := win.wstring_to_utf8(win.wstring(raw_data(buffer)), int(length), context.temp_allocator) or_else ""
		if len(path) > 0 {
			paths[accepted] = path
			accepted += 1
		}
	}
	if _drop_paths_replace(paths[:accepted]) && effect != nil do effect^ = DD_EFFECT_COPY
	_idle_note_activity(&g.idle)
	return win.S_OK
}

@(private)
platform_dragdrop_init :: proc() {
	result := OleInitialize(nil)
	g_dd_ole_owned = result == win.S_OK || result == win.S_FALSE
	if !g_dd_ole_owned do return
	g_dd_vtable = {dd_query_interface, dd_add_ref, dd_release, dd_drag_enter, dd_drag_over, dd_drag_leave, dd_drop}
	g_dd_target.vtable = &g_dd_vtable
	g_dd_hwnd = win.HWND(GetWindowHandle())
	if g_dd_hwnd == nil do return
	result = RegisterDragDrop(g_dd_hwnd, &g_dd_target)
	g_dd_registered = !win.FAILED(result)
	if g_dd_registered do win.DragAcceptFiles(g_dd_hwnd, false)
}

@(private)
platform_dragdrop_tick :: proc() {}

@(private)
platform_dragdrop_shutdown :: proc() {
	if g_dd_registered {
		RevokeDragDrop(g_dd_hwnd)
		win.DragAcceptFiles(g_dd_hwnd, true)
	}
	if g_dd_ole_owned do OleUninitialize()
	g_dd_hwnd = nil
	g_dd_registered = false
	g_dd_ole_owned = false
	g_dd_has_files = false
}
