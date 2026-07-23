package libvterm

// Odin bindings for libvterm 0.3.3 — the VT220/xterm terminal emulator library
// used by vim/neovim.
//
// See: https://www.leonerd.org.uk/code/libvterm/
// Source vendored at: ingot/vendor/libvterm/ (rebuild the static libs with
// ingot/scripts/build-libvterm.sh / .bat).

import "core:c"

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

VTerm :: distinct rawptr
VTermState :: distinct rawptr
VTermScreen :: distinct rawptr

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

VTERM_MAX_CHARS_PER_CELL :: 6

VTERM_COLOR_RGB :: u8(0x00)
VTERM_COLOR_INDEXED :: u8(0x01)
VTERM_COLOR_TYPE_MASK :: u8(0x01)
VTERM_COLOR_DEFAULT_FG :: u8(0x02)
VTERM_COLOR_DEFAULT_BG :: u8(0x04)

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

VTerm_Pos :: struct {
	row: c.int,
	col: c.int,
}

VTerm_Rect :: struct {
	start_row: c.int,
	end_row:   c.int,
	start_col: c.int,
	end_col:   c.int,
}

// Tagged union: 4 bytes total (largest member is {type,r,g,b}: 4 bytes).
VTerm_Color :: struct #raw_union {
	type:    u8,
	rgb:     struct {
		type:  u8,
		red:   u8,
		green: u8,
		blue:  u8,
	},
	indexed: struct {
		type: u8,
		idx:  u8,
	},
}

// Bit-packed cell attributes. The C definition uses consecutive unsigned int
// bitfields totalling 18 bits inside a 32-bit storage unit.
VTerm_Screen_Cell_Attrs :: bit_field u32 {
	bold:      u32 | 1,
	underline: u32 | 2,
	italic:    u32 | 1,
	blink:     u32 | 1,
	reverse:   u32 | 1,
	conceal:   u32 | 1,
	strike:    u32 | 1,
	font:      u32 | 4,
	dwl:       u32 | 1,
	dhl:       u32 | 2,
	small:     u32 | 1,
	baseline:  u32 | 2,
}

// Screen cell: 40 bytes on 64-bit platforms (see vterm.h).
// chars: 6×4=24, width: 1, pad: 3, attrs: 4, fg: 4, bg: 4.
VTerm_Screen_Cell :: struct {
	chars: [VTERM_MAX_CHARS_PER_CELL]u32,
	width: i8,
	_pad:  [3]u8,
	attrs: VTerm_Screen_Cell_Attrs,
	fg:    VTerm_Color,
	bg:    VTerm_Color,
}

// VTermProp enum values.
VTerm_Prop :: enum c.int {
	Cursorvisible = 1,
	Cursorblink,
	Altscreen,
	Title,
	Iconname,
	Reverse,
	Cursorshape,
	Mouse,
	Focusreport,
}

// VTermStringFragment: C bitfield layout.
// str: 8 bytes, then a 64-bit storage unit with bits 0-29=len, 30=initial, 31=final.
VTerm_String_Fragment :: struct {
	str:   cstring,
	_bits: u64,
}

// VTermValue tagged union. The string member determines the size (16 bytes).
VTerm_Value :: struct #raw_union {
	boolean: c.int,
	number:  c.int,
	string:  VTerm_String_Fragment,
	color:   VTerm_Color,
}

// Screen callback table (function pointers; nil = unused).
VTerm_Screen_Callbacks :: struct {
	damage:      #type proc "c" (rect: VTerm_Rect, user: rawptr) -> c.int,
	moverect:    #type proc "c" (dest, src: VTerm_Rect, user: rawptr) -> c.int,
	movecursor:  #type proc "c" (pos, oldpos: VTerm_Pos, visible: c.int, user: rawptr) -> c.int,
	settermprop: #type proc "c" (prop: VTerm_Prop, val: ^VTerm_Value, user: rawptr) -> c.int,
	bell:        #type proc "c" (user: rawptr) -> c.int,
	resize:      #type proc "c" (rows, cols: c.int, user: rawptr) -> c.int,
	sb_pushline: #type proc "c" (cols: c.int, cells: [^]VTerm_Screen_Cell, user: rawptr) -> c.int,
	sb_popline:  #type proc "c" (cols: c.int, cells: [^]VTerm_Screen_Cell, user: rawptr) -> c.int,
	sb_clear:    #type proc "c" (user: rawptr) -> c.int,
}

// ---------------------------------------------------------------------------
// Helper inlines (mirror C macros)
// ---------------------------------------------------------------------------

@(require_results)
vterm_color_is_indexed :: #force_inline proc "contextless" (col: ^VTerm_Color) -> bool {
	return (col.type & VTERM_COLOR_TYPE_MASK) == VTERM_COLOR_INDEXED
}

@(require_results)
vterm_color_is_rgb :: #force_inline proc "contextless" (col: ^VTerm_Color) -> bool {
	return (col.type & VTERM_COLOR_TYPE_MASK) == VTERM_COLOR_RGB
}

@(require_results)
vterm_color_is_default_fg :: #force_inline proc "contextless" (col: ^VTerm_Color) -> bool {
	return (col.type & VTERM_COLOR_DEFAULT_FG) != 0
}

@(require_results)
vterm_color_is_default_bg :: #force_inline proc "contextless" (col: ^VTerm_Color) -> bool {
	return (col.type & VTERM_COLOR_DEFAULT_BG) != 0
}

@(require_results)
vterm_str_frag_len :: #force_inline proc "contextless" (f: ^VTerm_String_Fragment) -> int {
	return int(f._bits & 0x3FFFFFFF)
}

@(require_results)
vterm_str_frag_initial :: #force_inline proc "contextless" (f: ^VTerm_String_Fragment) -> bool {
	return (f._bits >> 30) & 1 != 0
}

@(require_results)
vterm_str_frag_final :: #force_inline proc "contextless" (f: ^VTerm_String_Fragment) -> bool {
	return (f._bits >> 31) & 1 != 0
}

// ---------------------------------------------------------------------------
// Foreign library import
// ---------------------------------------------------------------------------

// Prebuilt static libraries ship next to this package so consumers need no
// extra linker flags. Linux falls back to a system-installed libvterm (build
// one with scripts/build-libvterm.sh --target linux_amd64 if preferred).
when ODIN_OS == .Linux {
	foreign import lib "system:vterm"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "lib/darwin_arm64/libvterm.a"
} else when ODIN_OS == .Darwin {
	foreign import lib "lib/darwin_amd64/libvterm.a"
} else when ODIN_OS == .Windows {
	foreign import lib "lib/windows_amd64/vterm.lib"
}

// ---------------------------------------------------------------------------
// Foreign function declarations
// ---------------------------------------------------------------------------

@(default_calling_convention = "c")
foreign lib {
	// Lifecycle.
	vterm_new :: proc(rows, cols: c.int) -> VTerm ---
	vterm_free :: proc(vt: VTerm) ---

	// Size and encoding.
	vterm_get_size :: proc(vt: VTerm, rowsp, colsp: ^c.int) ---
	vterm_set_size :: proc(vt: VTerm, rows, cols: c.int) ---
	vterm_set_utf8 :: proc(vt: VTerm, is_utf8: c.int) ---

	// Input from the PTY process → terminal emulator state.
	vterm_input_write :: proc(vt: VTerm, bytes: [^]u8, len: c.size_t) -> c.size_t ---

	// Layer accessors.
	vterm_obtain_screen :: proc(vt: VTerm) -> VTermScreen ---
	vterm_obtain_state :: proc(vt: VTerm) -> VTermState ---

	// Screen layer.
	vterm_screen_reset :: proc(screen: VTermScreen, hard: c.int) ---
	vterm_screen_enable_altscreen :: proc(screen: VTermScreen, altscreen: c.int) ---
	vterm_screen_flush_damage :: proc(screen: VTermScreen) ---
	vterm_screen_set_damage_merge :: proc(screen: VTermScreen, size: c.int) ---
	vterm_screen_set_callbacks :: proc(screen: VTermScreen, callbacks: ^VTerm_Screen_Callbacks, user: rawptr) ---
	vterm_screen_get_cell :: proc(screen: VTermScreen, pos: VTerm_Pos, cell: ^VTerm_Screen_Cell) -> c.int ---
	vterm_screen_is_eol :: proc(screen: VTermScreen, pos: VTerm_Pos) -> c.int ---
	vterm_screen_convert_color_to_rgb :: proc(screen: VTermScreen, col: ^VTerm_Color) ---
	vterm_screen_set_default_colors :: proc(screen: VTermScreen, default_fg, default_bg: ^VTerm_Color) ---

	// State layer.
	vterm_state_get_cursorpos :: proc(state: VTermState, cursorpos: ^VTerm_Pos) ---
	vterm_state_get_default_colors :: proc(state: VTermState, fg, bg: ^VTerm_Color) ---
	vterm_state_set_default_colors :: proc(state: VTermState, fg, bg: ^VTerm_Color) ---
	vterm_state_convert_color_to_rgb :: proc(state: VTermState, col: ^VTerm_Color) ---
}
