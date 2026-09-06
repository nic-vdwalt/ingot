#+build darwin
package main

import "core:sync"
import "core:time"

foreign import CoreVideo "system:CoreVideo.framework"

CV_Return :: i32
CV_Option_Flags :: u64
CV_Display_Link :: distinct rawptr
CV_Display_Link_Callback :: #type proc "c" (
	display_link: CV_Display_Link,
	now, output: rawptr,
	flags_in: CV_Option_Flags,
	flags_out: ^CV_Option_Flags,
	userdata: rawptr,
) -> CV_Return

foreign CoreVideo {
	CVDisplayLinkCreateWithActiveCGDisplays :: proc(result: ^CV_Display_Link) -> CV_Return ---
	CVDisplayLinkSetOutputCallback :: proc(
		display_link: CV_Display_Link,
		callback: CV_Display_Link_Callback,
		userdata: rawptr,
	) -> CV_Return ---
	CVDisplayLinkStart :: proc(display_link: CV_Display_Link) -> CV_Return ---
	CVDisplayLinkStop :: proc(display_link: CV_Display_Link) -> CV_Return ---
	CVDisplayLinkRelease :: proc(display_link: CV_Display_Link) ---
}

Frame_Pacer :: struct {
	link:       CV_Display_Link,
	mutex:      sync.Mutex,
	wake:       sync.Cond,
	generation: u64,
	consumed:   u64,
	running:    bool,
	started:    bool,
}

frame_pacer_callback :: proc "c" (
	display_link: CV_Display_Link,
	now, output: rawptr,
	flags_in: CV_Option_Flags,
	flags_out: ^CV_Option_Flags,
	userdata: rawptr,
) -> CV_Return {
	value := cast(^Frame_Pacer)userdata
	if value == nil do return 0
	sync.mutex_lock(&value.mutex)
	if value.running {
		value.generation += 1
		sync.cond_signal(&value.wake)
	}
	sync.mutex_unlock(&value.mutex)
	return 0
}

frame_pacer_start :: proc(value: ^Frame_Pacer) -> bool {
	assert(value != nil && value.link == nil, "frame_pacer_start: invalid state")
	if CVDisplayLinkCreateWithActiveCGDisplays(&value.link) != 0 do return false
	value.running = true
	if CVDisplayLinkSetOutputCallback(value.link, frame_pacer_callback, value) != 0 {
		frame_pacer_stop(value)
		return false
	}
	if CVDisplayLinkStart(value.link) != 0 {
		frame_pacer_stop(value)
		return false
	}
	value.started = true
	return true
}

frame_pacer_wait :: proc(value: ^Frame_Pacer) -> f64 {
	assert(value != nil, "frame_pacer_wait: nil pacer")
	started := time.tick_now()
	sync.mutex_lock(&value.mutex)
	defer sync.mutex_unlock(&value.mutex)
	for value.running && value.generation == value.consumed {
		if !sync.cond_wait_with_timeout(&value.wake, &value.mutex, 100 * time.Millisecond) do break
	}
	value.consumed = value.generation
	return time.duration_seconds(time.tick_since(started))
}

frame_pacer_stop :: proc(value: ^Frame_Pacer) {
	if value == nil || value.link == nil do return
	sync.mutex_lock(&value.mutex)
	value.running = false
	sync.cond_broadcast(&value.wake)
	sync.mutex_unlock(&value.mutex)
	if value.started do _ = CVDisplayLinkStop(value.link)
	CVDisplayLinkRelease(value.link)
	value.link = nil
	value.started = false
}
