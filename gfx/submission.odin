package gfx

import "base:runtime"
import "core:sync"
import wg "vendor:wgpu"

MAX_IN_FLIGHT_SUBMISSIONS :: 64
#assert(size_of(u64) == 8)

// At sixty submissions per second, a 64-bit identity cannot wrap in any physical runtime.
@(private)
g_submission_id_next: u64 = 1

Submission_Ticket :: struct {
	id:       u64,
	epoch:    u64,
	active:   bool,
	complete: bool,
	failed:   bool,
}

Submission_Tracker :: struct {
	tickets:   [MAX_IN_FLIGHT_SUBMISSIONS]Submission_Ticket,
	head:      u32,
	count:     u32,
	completed: u64,
}

@(private)
_submission_init :: proc(tracker: ^Submission_Tracker) {
	assert(tracker != nil)
	tracker^ = {}
	assert(tracker.count == 0)
}

@(private)
_submission_shutdown :: proc(tracker: ^Submission_Tracker) {
	assert(tracker != nil)
	_submission_poll(tracker)
	assert(tracker.count <= MAX_IN_FLIGHT_SUBMISSIONS)
}

@(private)
_submission_reserve :: proc(tracker: ^Submission_Tracker) -> u64 {
	assert(tracker != nil)
	_submission_poll(tracker)
	if tracker.count >= MAX_IN_FLIGHT_SUBMISSIONS {
		_stats_submission_tracking_failure()
		return 0
	}

	index := (tracker.head + tracker.count) % MAX_IN_FLIGHT_SUBMISSIONS
	ticket := &tracker.tickets[index]
	assert(!ticket.active)
	assert(g_submission_id_next != 0)
	ticket^ = {
		id     = g_submission_id_next,
		epoch  = g.epoch,
		active = true,
	}
	g_submission_id_next += 1
	ensure(g_submission_id_next != 0, "submission identity exhausted")
	tracker.count += 1
	assert(tracker.count <= MAX_IN_FLIGHT_SUBMISSIONS)
	return ticket.id
}

@(private)
_submission_commit :: proc(tracker: ^Submission_Tracker, ticket_id: u64) -> bool {
	assert(tracker != nil)
	assert(g.queue != nil)
	ticket := _submission_find(tracker, ticket_id)
	if ticket == nil do return false
	wg.QueueOnSubmittedWorkDone(
		g.queue,
		{
			mode = .AllowSpontaneos,
			callback = _submission_done,
			userdata1 = tracker,
			userdata2 = rawptr(uintptr(ticket.id)),
		},
	)
	return true
}

@(private)
_submission_rollback :: proc(tracker: ^Submission_Tracker, ticket_id: u64) -> bool {
	assert(tracker != nil)
	if tracker.count == 0 || ticket_id == 0 do return false
	index := (tracker.head + tracker.count - 1) % MAX_IN_FLIGHT_SUBMISSIONS
	ticket := &tracker.tickets[index]
	if !ticket.active || ticket.id != ticket_id do return false
	ticket^ = {}
	tracker.count -= 1
	assert(tracker.count < MAX_IN_FLIGHT_SUBMISSIONS)
	return true
}

@(private)
_submission_track :: proc(tracker: ^Submission_Tracker) -> u64 {
	ticket := _submission_reserve(tracker)
	if ticket == 0 do return 0
	if !_submission_commit(tracker, ticket) {
		assert(_submission_rollback(tracker, ticket))
		return 0
	}
	return ticket
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
	tracker := cast(^Submission_Tracker)userdata1
	id := u64(uintptr(userdata2))
	if tracker == nil || id == 0 do return
	ticket := _submission_find(tracker, id)
	if ticket == nil || ticket.epoch != g.epoch do return
	assert(ticket.id == id)
	sync.atomic_store(&ticket.failed, status != .Success)
	sync.atomic_store(&ticket.complete, true)
}
