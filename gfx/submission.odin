package gfx

import "base:runtime"
import "core:sync"
import wg "vendor:wgpu"

MAX_IN_FLIGHT_SUBMISSIONS :: 64

Submission_Ticket :: struct {
	id:       u64,
	active:   bool,
	complete: bool,
	failed:   bool,
}

Submission_Callback :: struct {
	tracker: ^Submission_Tracker,
	ticket:  u64,
	epoch:   u64,
}

Submission_Tracker :: struct {
	tickets:   [MAX_IN_FLIGHT_SUBMISSIONS]Submission_Ticket,
	head:      u32,
	count:     u32,
	next_id:   u64,
	completed: u64,
}

@(private)
_submission_init :: proc(tracker: ^Submission_Tracker) {
	assert(tracker != nil)
	tracker^ = {}
	tracker.next_id = 1
	assert(tracker.count == 0)
}

@(private)
_submission_shutdown :: proc(tracker: ^Submission_Tracker) {
	assert(tracker != nil)
	_submission_poll(tracker)
	assert(tracker.count <= MAX_IN_FLIGHT_SUBMISSIONS)
}

@(private)
_submission_track :: proc(tracker: ^Submission_Tracker) -> u64 {
	assert(tracker != nil)
	assert(g.queue != nil)
	_submission_poll(tracker)
	if tracker.count >= MAX_IN_FLIGHT_SUBMISSIONS {
		_stats_submission_tracking_failure()
		return 0
	}

	index := (tracker.head + tracker.count) % MAX_IN_FLIGHT_SUBMISSIONS
	ticket := &tracker.tickets[index]
	assert(!ticket.active)
	ticket^ = {
		id     = tracker.next_id,
		active = true,
	}
	tracker.next_id += 1
	tracker.count += 1
	callback := new(Submission_Callback)
	callback^ = {tracker = tracker, ticket = ticket.id, epoch = g.epoch}
	wg.QueueOnSubmittedWorkDone(
		g.queue,
		{mode = .AllowSpontaneos, callback = _submission_done, userdata1 = callback},
	)
	assert(tracker.count <= MAX_IN_FLIGHT_SUBMISSIONS)
	return ticket.id
}

@(private)
_submission_poll :: proc(tracker: ^Submission_Tracker) {
	assert(tracker != nil)
	for tracker.count > 0 {
		ticket := &tracker.tickets[tracker.head]
		assert(ticket.active)
		if !sync.atomic_load(&ticket.complete) do break
		tracker.completed = max(tracker.completed, ticket.id)
		ticket^ = {}
		tracker.head = (tracker.head + 1) % MAX_IN_FLIGHT_SUBMISSIONS
		tracker.count -= 1
	}
	assert(tracker.count <= MAX_IN_FLIGHT_SUBMISSIONS)
}

@(private)
_submission_completed :: proc(tracker: ^Submission_Tracker) -> u64 {
	assert(tracker != nil)
	_submission_poll(tracker)
	return tracker.completed
}

@(private)
_submission_find :: proc(tracker: ^Submission_Tracker, id: u64) -> ^Submission_Ticket {
	if tracker == nil || id == 0 do return nil
	for index in 0 ..< int(tracker.count) {
		ticket_index := (int(tracker.head) + index) % MAX_IN_FLIGHT_SUBMISSIONS
		ticket := &tracker.tickets[ticket_index]
		if ticket.active && ticket.id == id do return ticket
	}
	return nil
}

@(private)
_submission_done :: proc "c" (
	status: wg.QueueWorkDoneStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = runtime.default_context()
	callback := cast(^Submission_Callback)userdata1
	if callback == nil do return
	defer free(callback)
	if callback.epoch != g.epoch do return
	ticket := _submission_find(callback.tracker, callback.ticket)
	if ticket == nil do return
	sync.atomic_store(&ticket.failed, status != .Success)
	sync.atomic_store(&ticket.complete, true)
}
