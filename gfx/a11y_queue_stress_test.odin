#+build !js
package gfx

// TSan stress for the a11y action queue: AccessKit adapters may invoke the
// action callback off the main thread while the app drains from the frame
// loop. A producer thread hammers _a11y_stage (the exact staging path the
// adapter callback uses) while the main thread drains via
// PollAccessibilityAction — under -sanitize:thread any missing guard on the
// queue is flagged; under plain builds this still checks FIFO integrity and
// bounded-drop behavior.

import "core:sync"
import "core:testing"
import "core:thread"
import ak "ingot:accesskit"

@(private = "file")
Stress_Ctx :: struct {
	produced: int, // atomic
	done:     bool, // atomic
}

@(test)
a11y_action_queue_stress :: proc(t: ^testing.T) {
	ctx: Stress_Ctx

	producer :: proc(raw: rawptr) {
		c := (^Stress_Ctx)(raw)
		for i in 0 ..< 20_000 {
			_a11y_stage(.Click, ak.Node_Id(i + 2))
			sync.atomic_add(&c.produced, 1)
			if i % 64 == 0 do thread.yield()
		}
		sync.atomic_store(&c.done, true)
	}

	th := thread.create_and_start_with_data(&ctx, producer)
	defer thread.destroy(th)

	// Drain concurrently; node ids from one producer must arrive in FIFO
	// order (the queue is a mutex-guarded array, not lock-free).
	drained := 0
	last_node := ak.Node_Id(0)
	for {
		action, ok := PollAccessibilityAction()
		if ok {
			drained += 1
			testing.expect(t, action.action == ak.Action.Click, "unexpected action kind")
			testing.expect(t, action.node > last_node, "queue reordered actions")
			last_node = action.node
			continue
		}
		if sync.atomic_load(&ctx.done) do break
		thread.yield()
	}
	// Final drain after the producer stopped.
	for {
		action, ok := PollAccessibilityAction()
		if !ok do break
		drained += 1
		testing.expect(t, action.node > last_node, "queue reordered actions")
		last_node = action.node
	}

	produced := sync.atomic_load(&ctx.produced)
	testing.expect_value(t, produced, 20_000)
	// Overflow drops newest (bounded queue) — drained can be less, never more.
	testing.expect(t, drained <= produced, "drained more than produced")
	testing.expect(t, drained > 0, "nothing drained")

	thread.join(th)
}
