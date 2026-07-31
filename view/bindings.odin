// The consumer contract.
//
// Goal: a saved view cannot own state. The document describes structure; the
// client supplies storage and reads interaction back out. This file is the
// interface another ingot client implements to render somebody else's view.
//
// Method: one tagged union in one slice, so there is one index space and one
// bounds check. An earlier shape had five parallel slices, which is five
// chances to use the wrong index; Tiger Style asks for lower dimensionality at
// the call site. The tag is checked before the union is read, because both the
// index and the expected kind come from document data.
package view

import "ingot:ui"

Binding_Kind :: enum u8 {
	None,
	Boolean,
	Number,
	Integer,
	Text,
	Label,
}

Binding :: struct {
	kind: Binding_Kind,
	as:   struct #raw_union {
		boolean: ^bool,
		number:  ^f32,
		integer: ^i32,
		text:    ^ui.Input_Box,
		label:   string,
	},
}

// Event records one interaction. The key is carried as an offset into the
// view's text blob rather than as a string so an Event stays plain data.
Event :: struct {
	node:       i32,
	key_offset: u32,
	key_length: u16,
}

// Event_Sink is fixed capacity: a single frame cannot interact with more
// controls than a person can click. Overflow is counted rather than dropped
// silently, so a wrong bound is visible instead of mysterious.
Event_Sink :: struct {
	events:  [VIEW_EVENTS_MAX]Event,
	count:   i32,
	dropped: i32,
}

Bindings :: struct {
	slots:  []Binding,
	events: ^Event_Sink,
}

bind_boolean :: proc(value: ^bool) -> Binding {
	assert(value != nil, "bind_boolean: nil value")
	binding := Binding {
		kind = .Boolean,
	}
	binding.as.boolean = value
	return binding
}

bind_number :: proc(value: ^f32) -> Binding {
	assert(value != nil, "bind_number: nil value")
	binding := Binding {
		kind = .Number,
	}
	binding.as.number = value
	return binding
}

bind_integer :: proc(value: ^i32) -> Binding {
	assert(value != nil, "bind_integer: nil value")
	binding := Binding {
		kind = .Integer,
	}
	binding.as.integer = value
	return binding
}

bind_text :: proc(value: ^ui.Input_Box) -> Binding {
	assert(value != nil, "bind_text: nil value")
	binding := Binding {
		kind = .Text,
	}
	binding.as.text = value
	return binding
}

bind_label :: proc(value: string) -> Binding {
	binding := Binding {
		kind = .Label,
	}
	binding.as.label = value
	return binding
}

// sink_reset clears a sink for a new frame. Events are per-frame output; a sink
// that accumulated across frames would report a click forever.
sink_reset :: proc(sink: ^Event_Sink) {
	assert(sink != nil, "sink_reset: nil sink")
	assert(sink.count >= 0 && sink.count <= VIEW_EVENTS_MAX, "sink_reset: count out of range")
	assert(sink.dropped >= 0, "sink_reset: negative dropped count")
	sink.count = 0
	sink.dropped = 0
}

// sink_push records one interaction. Overflow increments dropped rather than
// asserting: too many interactions in one frame is an operating condition of a
// very large view, not a programmer error.
@(private = "package")
sink_push :: proc(sink: ^Event_Sink, event: Event) {
	assert(sink != nil, "sink_push: nil sink")
	assert(sink.count >= 0 && sink.count <= VIEW_EVENTS_MAX, "sink_push: count out of range")
	if sink.count >= VIEW_EVENTS_MAX {
		sink.dropped += 1
		return
	}
	sink.events[sink.count] = event
	sink.count += 1
}

// view_fired reports whether the node with this key interacted during the frame
// the sink describes. Polling by key keeps the caller free of node indices,
// which are an implementation detail of how the document was authored.
view_fired :: proc(view: View, sink: ^Event_Sink, key: string) -> bool {
	assert(sink != nil, "view_fired: nil sink")
	assert(sink.count >= 0 && sink.count <= VIEW_EVENTS_MAX, "view_fired: count out of range")
	if key == "" do return false
	for index in 0 ..< int(sink.count) {
		event := sink.events[index]
		if text_slice(view, event.key_offset, event.key_length) == key do return true
	}
	return false
}

// view_text resolves a node's offset/length pair against the text blob. Tools
// that read or rewrite a document need it, and a caller computing the slice
// itself would be re-deriving a bound this package already checks.
view_text :: proc(view: View, offset: u32, length: u16) -> string {
	return text_slice(view, offset, length)
}

// text_slice resolves an offset/length pair against the text blob. Every read
// of document text goes through here so the bound is checked in one place.
// It returns "" rather than asserting on a bad range because the same helper
// serves validation, which must tolerate a malformed document.
@(private = "package")
text_slice :: proc(view: View, offset: u32, length: u16) -> string {
	if length == 0 do return ""
	start := int(offset)
	end := start + int(length)
	if start < 0 || end > len(view.text) || end < start do return ""
	return view.text[start:end]
}
