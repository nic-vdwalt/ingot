// Package threadhook lets an embedder route worker-thread assertion failures
// into its own crash reporter.
//
// Why this exists: a thread started with core:thread does **not** inherit the
// spawning thread's context. `core/thread._select_context_for_thread` builds a
// fresh `runtime.default_context()`, and `runtime.__init_context` then
// unconditionally resets `assertion_failure_proc` to the runtime default. So an
// `assert` that fires on a reader thread, a fetch worker, or a teardown thread
// prints to a stderr that a bundled GUI app does not have, and traps with no
// record of what failed.
//
// The alternative - assigning `thread.Thread.init_context` - is worse: supplying
// an init_context makes core:thread skip
// `_maybe_destroy_default_temp_allocator`, so every worker leaks its temporary
// arena on exit. Installing the hook from inside the thread keeps the automatic
// cleanup and changes nothing else about the thread's context.
//
// Usage: the embedder calls `set_assertion_proc` once at startup; every worker
// procedure calls `install(&context)` as its first statement.
package threadhook

import "base:runtime"
import "core:sync"

// Stored as a raw pointer so it can be published and read atomically. A
// procedure value is pointer-sized, but Odin has no atomic intrinsic for the
// procedure type itself.
@(private)
g_assertion_proc: rawptr

// set_assertion_proc publishes the handler worker threads should install.
// Passing nil restores the runtime default. Safe to call before any worker
// exists; that is the intended order.
set_assertion_proc :: proc "contextless" (handler: runtime.Assertion_Failure_Proc) {
	sync.atomic_store_explicit(&g_assertion_proc, rawptr(handler), .Release)
}

// assertion_proc returns the currently published handler, or nil if none.
assertion_proc :: proc "contextless" () -> runtime.Assertion_Failure_Proc {
	raw := sync.atomic_load_explicit(&g_assertion_proc, .Acquire)
	if raw == nil do return nil
	return runtime.Assertion_Failure_Proc(raw)
}

// install returns the handler the calling worker should adopt: the embedder's
// published handler when there is one, otherwise `current` unchanged. So
// libraries and tests keep the runtime default.
//
// It returns rather than mutates because Odin's `context` is an implicit
// parameter - a callee cannot take its address or write through it. Worker
// procedures call it as:
//
//	context.assertion_failure_proc = threadhook.install(context.assertion_failure_proc)
install :: proc "contextless" (
	current: runtime.Assertion_Failure_Proc,
) -> runtime.Assertion_Failure_Proc {
	handler := assertion_proc()
	return handler if handler != nil else current
}
