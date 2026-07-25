package term

// Term_Instance lifecycle: spawn PTY shell + libvterm terminal emulator.
// Rendering is app-side (a raylib cell-grid renderer draws the screen from
// vterm_screen_get_cell + the scrollback buffer); this package stays
// raylib-free apart from term_input.odin's key handling.

import lv "../libvterm"
import "../pty"
import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Maximum number of scrollback lines retained per terminal instance.
TERM_SCROLLBACK_MAX :: 5000
TERM_OUTPUT_CHUNK_SIZE :: 65532
TERM_OUTPUT_QUEUE_CAP :: 16

Term_Output_Chunk :: struct {
	data: [TERM_OUTPUT_CHUNK_SIZE]u8,
	len:  int,
}

// Term_Instance bundles a libvterm VTerm, a POSIX PTY, and bookkeeping used
// by the render / input / pump layers.
Term_Instance :: struct {
	vt:             lv.VTerm,
	screen:         lv.VTermScreen,
	state:          lv.VTermState,
	callbacks:      lv.VTerm_Screen_Callbacks,
	pty:            pty.Pty,
	cols:           u16,
	rows:           u16,
	pty_running:    bool,
	reader_running: bool,
	reader_thread:  ^thread.Thread,
	wake:           proc "contextless" (),
	output_mutex:   sync.Mutex,
	output_queue:   [TERM_OUTPUT_QUEUE_CAP]Term_Output_Chunk,
	output_head:    int,
	output_count:   int,
	output_eof:     bool,
	cursor_visible: bool,
	cursor_blink:   bool,
	altscreen:      bool,
	read_buf:       [65536]u8,
	title:          string, // heap-owned; freed in term_destroy

	// Incomplete trailing UTF-8 sequence held back between PTY reads so a
	// multi-byte character is never split across vterm_input_write calls.
	utf8_hold:      [4]u8,
	utf8_hold_len:  int,

	// Scrollback: lines pushed off the top of the normal screen.
	// Each entry is a heap-owned row of cells captured via sb_pushline.
	sb_lines:       [dynamic][]lv.VTerm_Screen_Cell,
	// How many lines the view is scrolled back (0 = live view).
	sb_view_offset: int,
	// Count of scrollback lines evicted at the cap. Content-absolute row
	// indices (used by text selection) are sb_base + scrollback index, so
	// they stay stable when old lines are dropped.
	sb_base:        int,

	// Owner of all emulator heap state (title, scrollback rows, sb_lines
	// backing). Captured in term_init_emulator; the C callbacks re-enter
	// Odin with default_context(), so they must restore this allocator or
	// alloc/free pairs split across allocators (bad frees under tracking
	// allocators, mismatches for custom-allocator embedders).
	allocator:      runtime.Allocator,
}

// _screen_settermprop captures title changes and cursor visibility updates.
// libvterm calls this via the registered VTermScreenCallbacks pointer.
@(private = "file")
_screen_settermprop :: proc "c" (
	prop: lv.VTerm_Prop,
	val: ^lv.VTerm_Value,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	ts := cast(^Term_Instance)user
	context.allocator = ts.allocator
	#partial switch prop {
	case .Title:
		frag := &val.string
		if !lv.vterm_str_frag_final(frag) do return 1
		n := lv.vterm_str_frag_len(frag)
		new_title: string
		if n > 0 {
			new_title = string(([^]u8)(frag.str)[:n])
		}
		if new_title != ts.title {
			if len(ts.title) > 0 {
				delete(ts.title)
			}
			ts.title = strings.clone(new_title)
		}
	case .Cursorvisible:
		ts.cursor_visible = val.boolean != 0
	case .Cursorblink:
		ts.cursor_blink = val.boolean != 0
	case .Altscreen:
		ts.altscreen = val.boolean != 0
	case:
	}
	return 1
}

// _screen_sb_pushline captures a line scrolled off the top of the normal
// screen into the instance's scrollback buffer.
@(private = "file")
_screen_sb_pushline :: proc "c" (
	cols: c.int,
	cells: [^]lv.VTerm_Screen_Cell,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	ts := cast(^Term_Instance)user
	context.allocator = ts.allocator
	line := make([]lv.VTerm_Screen_Cell, int(cols))
	copy(line, cells[:int(cols)])
	if len(ts.sb_lines) >= TERM_SCROLLBACK_MAX {
		delete(ts.sb_lines[0])
		ordered_remove(&ts.sb_lines, 0)
		ts.sb_base += 1
	}
	append(&ts.sb_lines, line)
	// Pin the view while scrolled back so live output does not slide the
	// content (or an in-progress selection) beneath the viewport.
	if ts.sb_view_offset > 0 {
		ts.sb_view_offset = min(ts.sb_view_offset + 1, len(ts.sb_lines))
	}
	return 1
}

// _screen_sb_popline returns the most recent scrollback line to libvterm
// (used when the screen grows taller).  Returns 0 when the buffer is empty.
@(private = "file")
_screen_sb_popline :: proc "c" (
	cols: c.int,
	cells: [^]lv.VTerm_Screen_Cell,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	ts := cast(^Term_Instance)user
	context.allocator = ts.allocator
	if len(ts.sb_lines) == 0 do return 0
	line := pop(&ts.sb_lines)
	n := min(int(cols), len(line))
	copy(cells[:n], line[:n])
	blank: lv.VTerm_Screen_Cell
	blank.width = 1
	for i in n ..< int(cols) {
		cells[i] = blank
	}
	delete(line)
	if ts.sb_view_offset > len(ts.sb_lines) {
		ts.sb_view_offset = len(ts.sb_lines)
	}
	return 1
}

// _screen_sb_clear drops the entire scrollback buffer.
@(private = "file")
_screen_sb_clear :: proc "c" (user: rawptr) -> c.int {
	context = runtime.default_context()
	ts := cast(^Term_Instance)user
	context.allocator = ts.allocator
	// Advance sb_base past the dropped lines so stale content-absolute
	// selection rows resolve to nothing instead of wrong screen rows.
	ts.sb_base += len(ts.sb_lines)
	for line in ts.sb_lines {
		delete(line)
	}
	clear(&ts.sb_lines)
	ts.sb_view_offset = 0
	return 1
}

// term_init_emulator initialises the libvterm emulator state (grid, screen,
// callbacks, default colors) on an existing Term_Instance WITHOUT spawning a
// PTY. Split from term_start so hostile-input fuzzing can drive the exact
// production emulator + callback path with no shell process attached.
// Returns false if libvterm allocation fails.
term_init_emulator :: proc(
	ts: ^Term_Instance,
	cols, rows: u16,
	default_fg: [3]u8 = {220, 220, 220},
	default_bg: [3]u8 = {27, 27, 27},
) -> bool {
	if ts == nil || cols == 0 || rows == 0 do return false
	if cols > pty.PTY_DIMENSION_MAX || rows > pty.PTY_DIMENSION_MAX do return false
	ts.allocator = context.allocator
	ts.cols = cols
	ts.rows = rows
	ts.cursor_visible = true

	ts.vt = lv.vterm_new(c.int(rows), c.int(cols))
	if ts.vt == nil {
		return false
	}

	lv.vterm_set_utf8(ts.vt, 1)

	ts.screen = lv.vterm_obtain_screen(ts.vt)
	ts.state = lv.vterm_obtain_state(ts.vt)

	// Enable alt-screen support (needed for vim, less, htop, etc.).
	lv.vterm_screen_enable_altscreen(ts.screen, 1)

	// Merge damage reports at the screen level for efficiency.
	lv.vterm_screen_set_damage_merge(ts.screen, 2) // VTERM_DAMAGE_SCREEN = 2

	// Register callbacks; libvterm stores a pointer so we must keep the struct alive.
	ts.callbacks = lv.VTerm_Screen_Callbacks {
		settermprop = _screen_settermprop,
		sb_pushline = _screen_sb_pushline,
		sb_popline  = _screen_sb_popline,
		sb_clear    = _screen_sb_clear,
	}
	lv.vterm_screen_set_callbacks(ts.screen, &ts.callbacks, ts)

	// Hard reset fills all cells with the default pen.
	lv.vterm_screen_reset(ts.screen, 1)

	// Override the default pen colors so text is legible from the first
	// frame and the background matches the host app's theme.
	def_fg: lv.VTerm_Color
	def_bg: lv.VTerm_Color
	def_fg.rgb.type = lv.VTERM_COLOR_RGB
	def_fg.rgb.red = default_fg[0]
	def_fg.rgb.green = default_fg[1]
	def_fg.rgb.blue = default_fg[2]
	def_bg.rgb.type = lv.VTERM_COLOR_RGB
	def_bg.rgb.red = default_bg[0]
	def_bg.rgb.green = default_bg[1]
	def_bg.rgb.blue = default_bg[2]
	lv.vterm_screen_set_default_colors(ts.screen, &def_fg, &def_bg)
	return true
}

// term_free_emulator releases libvterm state, scrollback, and the title —
// everything term_destroy frees except the PTY. Counterpart of
// term_init_emulator for instances that never spawned a shell.
term_free_emulator :: proc(ts: ^Term_Instance) {
	context.allocator = ts.allocator
	lv.vterm_free(ts.vt)
	for line in ts.sb_lines {
		delete(line)
	}
	delete(ts.sb_lines)
	if len(ts.title) > 0 {
		delete(ts.title)
		ts.title = ""
	}
}

// term_start allocates and initialises a new Term_Instance, spawning the
// default shell inside a PTY sized (cols × rows).  Returns nil on failure.
// default_fg/default_bg are RGB triples used as the terminal's default pen
// (pick values matching the host app's theme).
term_start :: proc(
	workspace_path: string,
	cols, rows: u16,
	default_fg: [3]u8 = {220, 220, 220},
	default_bg: [3]u8 = {27, 27, 27},
	wake: proc "contextless" () = nil,
) -> ^Term_Instance {
	ts := new(Term_Instance)
	if !term_init_emulator(ts, cols, rows, default_fg, default_bg) {
		free(ts)
		return nil
	}

	// Spawn PTY shell.
	shell := pty.get_default_shell()
	workdir := strings.clone_to_cstring(workspace_path, context.temp_allocator)
	p, ok := pty.spawn(shell, cols, rows, workdir)
	if !ok {
		term_free_emulator(ts)
		free(ts)
		return nil
	}
	ts.pty = p
	ts.pty_running = true
	ts.wake = wake
	when !pty.INGOT_PTY_SIM {
		sync.atomic_store(&ts.reader_running, true)
		ts.reader_thread = thread.create(proc(t: ^thread.Thread) {
			term_reader_loop(cast(^Term_Instance)t.data)
		})
		if ts.reader_thread != nil {
			ts.reader_thread.data = ts
			thread.start(ts.reader_thread)
		} else {
			sync.atomic_store(&ts.reader_running, false)
			pty.destroy(&ts.pty)
			term_free_emulator(ts)
			free(ts)
			return nil
		}
	}
	return ts
}

@(private = "file")
term_reader_loop :: proc(ts: ^Term_Instance) {
	buf: [TERM_OUTPUT_CHUNK_SIZE]u8
	for sync.atomic_load(&ts.reader_running) {
		data, eof := pty.drain(&ts.pty, buf[:])
		if len(data) > 0 {
			queued := false
			for sync.atomic_load(&ts.reader_running) && !queued {
				sync.mutex_lock(&ts.output_mutex)
				if ts.output_count < TERM_OUTPUT_QUEUE_CAP {
					index := (ts.output_head + ts.output_count) % TERM_OUTPUT_QUEUE_CAP
					copy(ts.output_queue[index].data[:len(data)], data)
					ts.output_queue[index].len = len(data)
					ts.output_count += 1
					queued = true
				}
				sync.mutex_unlock(&ts.output_mutex)
				if !queued do time.sleep(time.Millisecond)
			}
			if queued && ts.wake != nil do ts.wake()
		}
		if eof {
			sync.mutex_lock(&ts.output_mutex)
			ts.output_eof = true
			sync.mutex_unlock(&ts.output_mutex)
			if ts.wake != nil do ts.wake()
			break
		}
		if len(data) == 0 do time.sleep(time.Millisecond)
	}
	sync.atomic_store(&ts.reader_running, false)
}

// term_destroy tears down the PTY and libvterm state and frees the instance.
term_destroy :: proc(ts: ^Term_Instance) {
	if ts == nil do return
	when !pty.INGOT_PTY_SIM {
		sync.atomic_store(&ts.reader_running, false)
		if ts.reader_thread != nil {
			thread.join(ts.reader_thread)
			thread.destroy(ts.reader_thread)
			ts.reader_thread = nil
		}
	}
	pty.destroy(&ts.pty)
	term_free_emulator(ts)
	free(ts)
}

// term_resize updates both the PTY window size and the libvterm grid.
// No-op if the size is unchanged.
term_resize :: proc(ts: ^Term_Instance, cols, rows: u16) {
	if ts == nil || cols == 0 || rows == 0 do return
	if cols > pty.PTY_DIMENSION_MAX || rows > pty.PTY_DIMENSION_MAX do return
	if cols == ts.cols && rows == ts.rows do return
	ts.cols = cols
	ts.rows = rows
	pty.resize(&ts.pty, cols, rows)
	lv.vterm_set_size(ts.vt, c.int(rows), c.int(cols))
}
