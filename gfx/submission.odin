package gfx

import "core:sync"
import wg "vendor:wgpu"

MAX_IN_FLIGHT_SUBMISSIONS :: 64

Submission_Ticket :: struct {
	id:       u64,
	active:   bool,
	complete: bool,
	failed:   bool,
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
	if tracker.count >= MAX_IN_FLIGHT_SUBMISSIONS do return 0

	index := (tracker.head + tracker.count) % MAX_IN_FLIGHT_SUBMISSIONS
	ticket := &tracker.tickets[index]
	assert(!ticket.active)
	ticket^ = {id = tracker.next_id, active = true}
	tracker.next_id += 1
	tracker.count += 1
	wg.QueueOnSubmittedWorkDone(g.queue, {
		mode = .AllowSpontaneos,
		callback = _submission_done,
		userdata1 = ticket,
	})
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
_submission_done :: proc "c" (
	status: wg.QueueWorkDoneStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	ticket := (^Submission_Ticket)(userdata1)
	if ticket == nil do return
	sync.atomic_store(&ticket.failed, status != .Success)
	sync.atomic_store(&ticket.complete, true)
}
