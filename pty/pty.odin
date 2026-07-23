#+build linux, darwin
package pty

// POSIX PTY interface — forkpty + non-blocking I/O.
// Supports macOS and Linux. Windows uses ConPTY (see pty_windows.odin).

import "core:c"
import "core:os"

when ODIN_OS == .Darwin {
	TIOCSWINSZ :: 0x80087467
	EAGAIN :: 35
	EWOULDBLOCK :: 35
	O_NONBLOCK :: 0x0004
} else when ODIN_OS == .Linux {
	TIOCSWINSZ :: 0x5414
	EAGAIN :: 11
	EWOULDBLOCK :: EAGAIN
	O_NONBLOCK :: 0o4000
}

F_GETFL :: 3
F_SETFL :: 4
WNOHANG :: 1

Pty :: struct {
	master_fd: c.int,
	child_pid: c.int,
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
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) ---
		__errno_location :: proc() -> ^c.int ---
	}

	@(private)
	errno_ptr :: proc() -> ^c.int {return __errno_location()}
}

spawn :: proc(shell: cstring, cols: u16, rows: u16, workdir: cstring = nil) -> (Pty, bool) {
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
		// — including Homebrew, conda, pipx, aws, etc. — is available.
		@(static) login_argv0: [256]u8
		shell_str := string(shell)
		base := shell_str
		for i := len(shell_str) - 1; i >= 0; i -= 1 {
			if shell_str[i] == '/' {
				base = shell_str[i + 1:]
				break
			}
		}
		login_argv0[0] = '-'
		n := copy(login_argv0[1:], transmute([]u8)base)
		login_argv0[1 + n] = 0
		args := [?]cstring{cstring(&login_argv0[0]), nil}
		execvp(shell, raw_data(&args))
		_exit(1)
	}

	flags := fcntl(master_fd, F_GETFL)
	fcntl(master_fd, F_SETFL, flags | O_NONBLOCK)

	ws := Winsize {
		ws_col = c.ushort(cols),
		ws_row = c.ushort(rows),
	}
	ioctl(master_fd, TIOCSWINSZ, &ws)

	return Pty{master_fd = master_fd, child_pid = pid}, true
}

// read_bytes/drain are replaced by a scripted byte source when built
// with -define:INGOT_PTY_SIM=true (pty_sim.odin) so the terminal pump
// can be fuzzed without a shell process.
when !INGOT_PTY_SIM {
	read_bytes :: proc(p: ^Pty, buf: []u8) -> (n: int, eof: bool) {
		r := read(p.master_fd, raw_data(buf), len(buf))
		if r > 0 do return int(r), false
		if r == 0 do return 0, true
		e := errno_ptr()^
		if e == EAGAIN || e == EWOULDBLOCK do return 0, false
		return 0, true
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
}

write_bytes :: proc(p: ^Pty, data: []u8) {
	if len(data) == 0 || p.master_fd < 0 do return
	write(p.master_fd, raw_data(data), len(data))
}

write_byte :: proc(p: ^Pty, b: u8) {
	buf := [1]u8{b}
	if p.master_fd >= 0 do write(p.master_fd, &buf[0], 1)
}

write_string :: proc(p: ^Pty, s: string) {
	if len(s) == 0 || p.master_fd < 0 do return
	write(p.master_fd, raw_data(s), len(s))
}

resize :: proc(p: ^Pty, cols: u16, rows: u16) {
	if p.master_fd < 0 do return
	ws := Winsize {
		ws_col = c.ushort(cols),
		ws_row = c.ushort(rows),
	}
	ioctl(p.master_fd, TIOCSWINSZ, &ws)
}

destroy :: proc(p: ^Pty) {
	if p.master_fd >= 0 {
		close(p.master_fd)
		p.master_fd = -1
	}
	if p.child_pid > 0 {
		status: c.int
		waitpid(p.child_pid, &status, WNOHANG)
		p.child_pid = 0
	}
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
