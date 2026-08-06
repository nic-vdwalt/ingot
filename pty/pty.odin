#+build linux, darwin
package pty

// POSIX PTY interface - forkpty + non-blocking I/O.
// Supports macOS and Linux. Windows uses ConPTY (see pty_windows.odin).

import "core:c"
import "core:os"

when ODIN_OS == .Darwin {
	TIOCSWINSZ :: 0x80087467
	EAGAIN :: 35
	EWOULDBLOCK :: 35
	EINTR :: 4
	O_NONBLOCK :: 0x0004
} else when ODIN_OS == .Linux {
	TIOCSWINSZ :: 0x5414
	EAGAIN :: 11
	EWOULDBLOCK :: EAGAIN
	EINTR :: 4
	O_NONBLOCK :: 0o4000
}

F_GETFL :: 3
F_SETFL :: 4
WNOHANG :: 1
PTY_DIMENSION_MAX :: u16(32767)

Pty_IO_Status :: enum u8 {
	Ok,
	Would_Block,
	Interrupted,
	Closed,
	Failed,
}

Pty :: struct {
	master_fd: c.int,
	child_pid: c.int,
	exit_seen: bool,
	exit_code: int,
}


Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

foreign import util_lib "system:util"
foreign import libc_lib "system:c"

@(default_calling_convention = "c")
foreign util_lib {
	forkpty :: proc(amaster: ^c.int, name: [^]u8, termp: rawptr, winp: rawptr) -> c.int ---
}

when ODIN_OS == .Darwin {
	@(default_calling_convention = "c")
	foreign libc_lib {
		ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
		execvp :: proc(file: cstring, argv: [^]cstring) -> c.int ---
		close :: proc(fd: c.int) -> c.int ---
		read :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		write :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
		waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
		kill :: proc(pid: c.int, sig: c.int) -> c.int ---
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) ---
		__error :: proc() -> ^c.int ---
	}

	@(private)
	errno_ptr :: proc() -> ^c.int {return __error()}
} else when ODIN_OS == .Linux {
	@(default_calling_convention = "c")
	foreign libc_lib {
		ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
		execvp :: proc(file: cstring, argv: [^]cstring) -> c.int ---
		close :: proc(fd: c.int) -> c.int ---
		read :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		write :: proc(fd: c.int, buf: rawptr, count: c.size_t) -> c.ssize_t ---
		fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
		waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
		kill :: proc(pid: c.int, sig: c.int) -> c.int ---
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) ---
		__errno_location :: proc() -> ^c.int ---
	}

	@(private)
	errno_ptr :: proc() -> ^c.int {return __errno_location()}
}

spawn :: proc(shell: cstring, cols: u16, rows: u16, workdir: cstring = nil) -> (Pty, bool) {
	if shell == nil || cols == 0 || rows == 0 do return {}, false
	if cols > PTY_DIMENSION_MAX || rows > PTY_DIMENSION_MAX do return {}, false
	master_fd: c.int
	pid := forkpty(&master_fd, nil, nil, nil)

	if pid < 0 do return {}, false

	if pid == 0 {
		if workdir != nil do chdir(workdir)
		setenv("TERM", "xterm-256color", 1)
		setenv("COLORTERM", "truecolor", 1)
		// Prefix argv[0] with '-' to spawn as a login shell (POSIX
		// convention). This causes the shell to source login startup
		// files (.zprofile, .bash_profile, etc.) so the full user PATH
		// - including Homebrew, conda, pipx, aws, etc. - is available.
		@(static) login_argv0: [256]u8
		shell_str := string(shell)
		base := shell_str
		for i := len(shell_str) - 1; i >= 0; i -= 1 {
			if shell_str[i] == '/' {
				base = shell_str[i + 1:]
				break
			}
		}
		if len(base) == 0 || len(base) > len(login_argv0) - 2 do _exit(1)
		login_argv0[0] = '-'
		n := copy(login_argv0[1:len(login_argv0) - 1], transmute([]u8)base)
		login_argv0[1 + n] = 0
		args := [?]cstring{cstring(&login_argv0[0]), nil}
		execvp(shell, raw_data(&args))
		_exit(1)
	}

	if !master_setup(master_fd, cols, rows) do return {}, false
	return Pty{master_fd = master_fd, child_pid = pid}, true
}

SPAWN_ARGV_MAX :: 256

// spawn_argv runs an arbitrary command (argv[0] resolved via PATH) directly
// on a fresh PTY, without a shell. TERM/COLORTERM are exported so children
// detect a color-capable terminal. Returns false on invalid input or fork
// failure.
spawn_argv :: proc(argv: []cstring, cols: u16, rows: u16, workdir: cstring = nil) -> (Pty, bool) {
	if len(argv) == 0 || len(argv) > SPAWN_ARGV_MAX || argv[0] == nil do return {}, false
	if cols == 0 || rows == 0 do return {}, false
	if cols > PTY_DIMENSION_MAX || rows > PTY_DIMENSION_MAX do return {}, false
	// Build the null-terminated exec vector before forking: allocating
	// between fork and exec is unsafe in a multithreaded parent.
	@(static) exec_argv: [SPAWN_ARGV_MAX + 1]cstring
	for arg, i in argv do exec_argv[i] = arg
	exec_argv[len(argv)] = nil
	master_fd: c.int
	pid := forkpty(&master_fd, nil, nil, nil)

	if pid < 0 do return {}, false

	if pid == 0 {
		if workdir != nil do chdir(workdir)
		setenv("TERM", "xterm-256color", 1)
		setenv("COLORTERM", "truecolor", 1)
		execvp(argv[0], raw_data(exec_argv[:]))
		_exit(127)
	}

	if !master_setup(master_fd, cols, rows) do return {}, false
	return Pty{master_fd = master_fd, child_pid = pid}, true
}

@(private)
master_setup :: proc(master_fd: c.int, cols: u16, rows: u16) -> bool {
	flags := fcntl(master_fd, F_GETFL)
	if flags < 0 || fcntl(master_fd, F_SETFL, flags | O_NONBLOCK) < 0 {
		close(master_fd)
		return false
	}

	ws := Winsize {
		ws_col = c.ushort(cols),
		ws_row = c.ushort(rows),
	}
	ioctl(master_fd, TIOCSWINSZ, &ws)
	return true
}

// read_bytes/drain are replaced by a scripted byte source when built
// with -define:INGOT_PTY_SIM=true (pty_sim.odin) so the terminal pump
// can be fuzzed without a shell process.
when !INGOT_PTY_SIM {
	read_bytes :: proc(p: ^Pty, buf: []u8) -> (n: int, eof: bool) {
		assert(p != nil)
		r := read(p.master_fd, raw_data(buf), len(buf))
		if r > 0 {
			ensure(r <= c.ssize_t(len(buf)))
			return int(r), false
		}
		if r == 0 do return 0, true
		e := errno_ptr()^
		if e == EINTR || e == EAGAIN || e == EWOULDBLOCK do return 0, false
		return 0, true
	}

	drain :: proc(p: ^Pty, buf: []u8) -> (data: []u8, eof: bool) {
		assert(p != nil)
		total := 0
		for total < len(buf) {
			n, e := read_bytes(p, buf[total:])
			ensure(n >= 0 && n <= len(buf) - total)
			total += n
			if e do return buf[:total], true
			if n == 0 do break
		}
		return buf[:total], false
	}
}

write_bytes :: proc(p: ^Pty, data: []u8) -> (written: int, status: Pty_IO_Status) {
	assert(p != nil)
	if len(data) == 0 do return 0, .Ok
	if p.master_fd < 0 do return 0, .Closed
	n := write(p.master_fd, raw_data(data), len(data))
	if n >= 0 {
		ensure(n <= c.ssize_t(len(data)))
		return int(n), .Ok
	}
	e := errno_ptr()^
	if e == EINTR do return 0, .Interrupted
	if e == EAGAIN || e == EWOULDBLOCK do return 0, .Would_Block
	return 0, .Failed
}

write_byte :: proc(p: ^Pty, b: u8) -> (int, Pty_IO_Status) {
	assert(p != nil, "write_byte: nil p")
	buf := [1]u8{b}
	return write_bytes(p, buf[:])
}

write_string :: proc(p: ^Pty, s: string) -> (int, Pty_IO_Status) {
	return write_bytes(p, transmute([]u8)s)
}

resize :: proc(p: ^Pty, cols: u16, rows: u16) {
	assert(p != nil)
	if p.master_fd < 0 do return
	if cols == 0 || rows == 0 || cols > PTY_DIMENSION_MAX || rows > PTY_DIMENSION_MAX do return
	ws := Winsize {
		ws_col = c.ushort(cols),
		ws_row = c.ushort(rows),
	}
	ioctl(p.master_fd, TIOCSWINSZ, &ws)
}

destroy :: proc(p: ^Pty) {
	assert(p != nil)
	if p.master_fd >= 0 {
		close(p.master_fd)
		p.master_fd = -1
	}
	if p.child_pid > 0 {
		status: c.int
		reaped := waitpid(p.child_pid, &status, WNOHANG)
		if reaped == p.child_pid do p.child_pid = 0
	}
}

// child_pid_of returns the child process id, or 0 when no child is tracked.
child_pid_of :: proc(p: ^Pty) -> int {
	assert(p != nil)
	return int(p.child_pid)
}

// child_poll reaps the child without blocking. exited is true once the child
// has terminated (further calls keep returning the cached result); code is
// the exit status, or 128+signal when signal-terminated.
child_poll :: proc(p: ^Pty) -> (exited: bool, code: int) {
	assert(p != nil)
	if p.child_pid == 0 do return p.exit_seen, p.exit_code
	status: c.int
	reaped := waitpid(p.child_pid, &status, WNOHANG)
	if reaped != p.child_pid do return false, 0
	p.child_pid = 0
	p.exit_seen = true
	if status & 0x7f == 0 {
		p.exit_code = int((status >> 8) & 0xff)
	} else {
		p.exit_code = 128 + int(status & 0x7f)
	}
	return p.exit_seen, p.exit_code
}

SIGTERM :: 15
SIGKILL :: 9

// child_signal sends SIGTERM (or SIGKILL when force) to the child.
child_signal :: proc(p: ^Pty, force: bool = false) {
	assert(p != nil)
	if p.child_pid <= 0 do return
	kill(p.child_pid, SIGKILL if force else SIGTERM)
}

get_default_shell :: proc() -> cstring {
	buf: [256]u8
	shell := os.get_env_buf(buf[:], "SHELL")
	if len(shell) > 0 {
		@(static) shell_buf: [256]u8
		copy(shell_buf[:], shell)
		shell_buf[len(shell)] = 0
		return cstring(&shell_buf[0])
	}
	return "/bin/bash"
}
