#+build windows
package pty

// Windows ConPTY implementation for terminal emulation.
// Uses CreatePseudoConsole (Windows 10 1809+) to spawn a shell with a proper
// console environment, then pipes I/O through handles.

import "core:c"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

// ConPTY handle type (HPCON).
HPCON :: distinct rawptr

// COORD structure for console dimensions.
COORD :: struct {
	X: win32.SHORT,
	Y: win32.SHORT,
}

// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016.
// (PROC_THREAD_ATTRIBUTE_INPUT | (22 << 16) | 0x00020000)
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

// Startup info extended structure.
STARTUPINFOEXW :: struct {
	StartupInfo:     win32.STARTUPINFOW,
	lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
}

LPPROC_THREAD_ATTRIBUTE_LIST :: distinct rawptr

// STILL_ACTIVE constant for GetExitCodeProcess.
STILL_ACTIVE :: 259

// Foreign imports from kernel32.dll.
foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	CreatePseudoConsole :: proc(size: COORD, hInput: win32.HANDLE, hOutput: win32.HANDLE, dwFlags: win32.DWORD, phPC: ^HPCON) -> win32.HRESULT ---

	ClosePseudoConsole :: proc(hPC: HPCON) ---

	ResizePseudoConsole :: proc(hPC: HPCON, size: COORD) -> win32.HRESULT ---

	InitializeProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwAttributeCount: win32.DWORD, dwFlags: win32.DWORD, lpSize: ^c.size_t) -> win32.BOOL ---

	UpdateProcThreadAttribute :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwFlags: win32.DWORD, attribute: win32.DWORD_PTR, lpValue: rawptr, cbSize: c.size_t, lpPreviousValue: rawptr, lpReturnSize: ^c.size_t) -> win32.BOOL ---

	DeleteProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST) ---

	PeekNamedPipe :: proc(hNamedPipe: win32.HANDLE, lpBuffer: rawptr, nBufferSize: win32.DWORD, lpBytesRead: ^win32.DWORD, lpTotalBytesAvail: ^win32.DWORD, lpBytesLeftThisMessage: ^win32.DWORD) -> win32.BOOL ---
}

// Pty bundles the ConPTY handle, I/O pipes, and child process.
Pty :: struct {
	hpc:        HPCON,
	pipe_in_w:  win32.HANDLE, // Write end → child stdin
	pipe_out_r: win32.HANDLE, // Read end ← child stdout
	hProcess:   win32.HANDLE,
	hThread:    win32.HANDLE,
	cols:       u16,
	rows:       u16,
}

spawn :: proc(shell: cstring, cols: u16, rows: u16, workdir: cstring = nil) -> (Pty, bool) {
	p: Pty
	p.cols = cols
	p.rows = rows

	// Create pipes for ConPTY I/O.
	sa := win32.SECURITY_ATTRIBUTES {
		nLength        = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}

	pipe_in_r, pipe_in_w: win32.HANDLE // Parent writes → child reads
	pipe_out_r, pipe_out_w: win32.HANDLE // Child writes → parent reads

	if !win32.CreatePipe(&pipe_in_r, &pipe_in_w, &sa, 0) {
		return {}, false
	}
	if !win32.CreatePipe(&pipe_out_r, &pipe_out_w, &sa, 0) {
		win32.CloseHandle(pipe_in_r)
		win32.CloseHandle(pipe_in_w)
		return {}, false
	}

	// Make parent-side handles non-inheritable.
	win32.SetHandleInformation(pipe_in_w, win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(pipe_out_r, win32.HANDLE_FLAG_INHERIT, 0)

	// Create pseudo console.
	size := COORD {
		X = win32.SHORT(cols),
		Y = win32.SHORT(rows),
	}
	hr := CreatePseudoConsole(size, pipe_in_r, pipe_out_w, 0, &p.hpc)
	if hr != 0 {
		win32.CloseHandle(pipe_in_r)
		win32.CloseHandle(pipe_in_w)
		win32.CloseHandle(pipe_out_r)
		win32.CloseHandle(pipe_out_w)
		return {}, false
	}

	// Child-side pipe ends are now owned by ConPTY; close our copies.
	win32.CloseHandle(pipe_in_r)
	win32.CloseHandle(pipe_out_w)

	// Initialize thread attribute list for PSEUDOCONSOLE.
	attr_size: c.size_t = 0
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	attr_list := cast(LPPROC_THREAD_ATTRIBUTE_LIST)win32.HeapAlloc(
		win32.GetProcessHeap(),
		0,
		attr_size,
	)
	if attr_list == nil {
		ClosePseudoConsole(p.hpc)
		win32.CloseHandle(pipe_in_w)
		win32.CloseHandle(pipe_out_r)
		return {}, false
	}

	if !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) {
		win32.HeapFree(win32.GetProcessHeap(), 0, attr_list)
		ClosePseudoConsole(p.hpc)
		win32.CloseHandle(pipe_in_w)
		win32.CloseHandle(pipe_out_r)
		return {}, false
	}

	if !UpdateProcThreadAttribute(
		attr_list,
		0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		p.hpc,
		size_of(HPCON),
		nil,
		nil,
	) {
		DeleteProcThreadAttributeList(attr_list)
		win32.HeapFree(win32.GetProcessHeap(), 0, attr_list)
		ClosePseudoConsole(p.hpc)
		win32.CloseHandle(pipe_in_w)
		win32.CloseHandle(pipe_out_r)
		return {}, false
	}

	// Prepare extended startup info.
	si: STARTUPINFOEXW
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	si.lpAttributeList = attr_list

	pi: win32.PROCESS_INFORMATION

	// Command line: spawn the shell.
	shell_str := string(shell)
	cmd_line := strings.clone_to_cstring(shell_str, context.temp_allocator)
	cmd_line_w := win32.utf8_to_wstring(string(cmd_line), context.temp_allocator)

	working_dir_w: win32.wstring = nil
	if workdir != nil && len(string(workdir)) > 0 {
		working_dir_w = win32.utf8_to_wstring(string(workdir), context.temp_allocator)
	}

	// EXTENDED_STARTUPINFO_PRESENT required for attribute list.
	EXTENDED_STARTUPINFO_PRESENT :: 0x00080000

	ok := win32.CreateProcessW(
		nil, // lpApplicationName
		cmd_line_w, // lpCommandLine
		nil, // lpProcessAttributes
		nil, // lpThreadAttributes
		false, // bInheritHandles — ConPTY handles inheritance itself
		EXTENDED_STARTUPINFO_PRESENT, // dwCreationFlags
		nil, // lpEnvironment
		working_dir_w, // lpCurrentDirectory
		&si.StartupInfo,
		&pi,
	)

	DeleteProcThreadAttributeList(attr_list)
	win32.HeapFree(win32.GetProcessHeap(), 0, attr_list)

	if !ok {
		ClosePseudoConsole(p.hpc)
		win32.CloseHandle(pipe_in_w)
		win32.CloseHandle(pipe_out_r)
		return {}, false
	}

	p.pipe_in_w = pipe_in_w
	p.pipe_out_r = pipe_out_r
	p.hProcess = pi.hProcess
	p.hThread = pi.hThread

	return p, true
}

read_bytes :: proc(p: ^Pty, buf: []u8) -> (n: int, eof: bool) {
	if p.pipe_out_r == nil do return 0, true

	// Non-blocking check: see if data is available.
	avail: win32.DWORD
	if !PeekNamedPipe(p.pipe_out_r, nil, 0, nil, &avail, nil) {
		return 0, true // Pipe broken → EOF
	}
	if avail == 0 {
		// Check if process has exited.
		exit_code: win32.DWORD
		if win32.GetExitCodeProcess(p.hProcess, &exit_code) {
			if exit_code != STILL_ACTIVE {
				return 0, true
			}
		}
		return 0, false // No data available, not EOF
	}

	// Read available data.
	to_read := min(win32.DWORD(len(buf)), avail)
	bytes_read: win32.DWORD
	if !win32.ReadFile(p.pipe_out_r, raw_data(buf), to_read, &bytes_read, nil) {
		return 0, true
	}
	return int(bytes_read), false
}

drain :: proc(p: ^Pty, buf: []u8) -> (data: []u8, eof: bool) {
	total := 0
	for total < len(buf) {
		n, e := read_bytes(p, buf[total:])
		total += n
		if e do return buf[:total], true
		if n == 0 do break
	}
	return buf[:total], false
}

write_bytes :: proc(p: ^Pty, data: []u8) {
	if len(data) == 0 || p.pipe_in_w == nil do return
	written: win32.DWORD
	win32.WriteFile(p.pipe_in_w, raw_data(data), win32.DWORD(len(data)), &written, nil)
}

write_byte :: proc(p: ^Pty, b: u8) {
	buf := [1]u8{b}
	if p.pipe_in_w != nil {
		written: win32.DWORD
		win32.WriteFile(p.pipe_in_w, &buf[0], 1, &written, nil)
	}
}

write_string :: proc(p: ^Pty, s: string) {
	if len(s) == 0 || p.pipe_in_w == nil do return
	written: win32.DWORD
	win32.WriteFile(p.pipe_in_w, raw_data(s), win32.DWORD(len(s)), &written, nil)
}

resize :: proc(p: ^Pty, cols: u16, rows: u16) {
	if p.hpc == nil do return
	if cols == p.cols && rows == p.rows do return
	p.cols = cols
	p.rows = rows
	size := COORD {
		X = win32.SHORT(cols),
		Y = win32.SHORT(rows),
	}
	ResizePseudoConsole(p.hpc, size)
}

destroy :: proc(p: ^Pty) {
	// Signal ConPTY to stop FIRST so the conhost I/O threads drain cleanly
	// before we close the pipes they are reading/writing (matches the Windows
	// Terminal sample teardown order from Microsoft's ConPTY documentation).
	if p.hpc != nil {
		ClosePseudoConsole(p.hpc)
		p.hpc = nil
	}
	// Safe to close pipes now that ConPTY has been signalled.
	if p.pipe_in_w != nil {
		win32.CloseHandle(p.pipe_in_w)
		p.pipe_in_w = nil
	}
	if p.pipe_out_r != nil {
		win32.CloseHandle(p.pipe_out_r)
		p.pipe_out_r = nil
	}
	// Terminate child and wait up to 2 s for it to exit before closing handles.
	if p.hProcess != nil {
		win32.TerminateProcess(p.hProcess, 0)
		win32.WaitForSingleObject(p.hProcess, 2000)
		win32.CloseHandle(p.hProcess)
		p.hProcess = nil
	}
	if p.hThread != nil {
		win32.CloseHandle(p.hThread)
		p.hThread = nil
	}
}

get_default_shell :: proc() -> cstring {
	// Prefer PowerShell, fall back to cmd.exe.
	buf: [512]u8
	comspec := os.get_env_buf(buf[:], "ComSpec")
	if len(comspec) > 0 {
		@(static) shell_buf: [512]u8
		copy(shell_buf[:], comspec)
		shell_buf[len(comspec)] = 0
		return cstring(&shell_buf[0])
	}
	return "cmd.exe"
}
