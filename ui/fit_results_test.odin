#+build !js
package ui

import "core:testing"

@(test)
fit_results_collection_overflow :: proc(t: ^testing.T) {
	builder: Fit_Builder
	storage: [2]Widget_Id
	builder.result_external = storage[:]
	frame: Ui_Frame
	root := Ui {
		frame = &frame,
	}
	builder.prepared.u = &root
	builder.prepared.rendered = true
	builder.prepared.count = 3
	nodes := prepared_nodes(&builder.prepared)
	for index in 0 ..< 3 {
		nodes[index].kind = .Button
		nodes[index].activated = true
		nodes[index].button.id = Widget_Id(index + 1)
	}
	fit_results_collect(&builder)
	testing.expect_value(t, builder.result_pending_count, 1)
	testing.expect_value(t, builder.result_dropped, u64(2))
	fit_results_begin(&builder)
	testing.expect(t, fit_button_result(&builder, Widget_Id(1)).activated)
	testing.expect(t, !fit_button_result(&builder, Widget_Id(2)).available)
}

@(test)
fit_results_expiration_and_external_storage :: proc(t: ^testing.T) {
	builder: Fit_Builder
	storage: [2]Widget_Id
	builder.result_external = storage[:]
	storage[1] = Widget_Id(7)
	builder.result_pending_count = 1
	builder.result_pending_valid = true
	builder.result_pending_overflow = true
	builder.result_dropped = 2
	fit_results_begin(&builder)
	positive := fit_button_result(&builder, Widget_Id(7))
	testing.expect(t, positive.available && positive.activated)
	testing.expect_value(t, positive, fit_button_result(&builder, Widget_Id(7)))
	testing.expect(t, !fit_button_result(&builder, Widget_Id(8)).available)
	fit_results_begin(&builder)
	testing.expect(t, !fit_button_result(&builder, Widget_Id(7)).available)
	builder.result_pending_valid = true
	fit_results_begin(&builder)
	negative := fit_button_result(&builder, Widget_Id(7))
	testing.expect(t, negative.available && !negative.activated)
	fit_results_reset(&builder)
	testing.expect(t, !fit_button_result(&builder, Widget_Id(7)).available)
	testing.expect_value(t, builder.result_dropped, u64(2))
	fit_builder_reset_storage(&builder)
	testing.expect(t, builder.result_external == nil)
}
