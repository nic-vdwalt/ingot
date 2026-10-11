package fit

import "ingot:ui"

Button_Result_Status :: enum u8 {
	Unavailable,
	Available,
}

Button_Result :: struct {
	status:    Button_Result_Status,
	activated: bool,
}

button_result :: proc(parent: Parent, key: $K) -> Button_Result {
	builder := parent_validate(parent)
	return builder_button_result(builder, result_identity(parent, key))
}

@(private = "package")
result_identity :: proc(parent: Parent, key: $K) -> Widget_Id {
	when K == Widget_Id {
		return key
	} else {
		return id(parent, key)
	}
}

@(private = "package")
builder_button_result :: proc(builder: ^Builder, widget: Widget_Id) -> Button_Result {
	assert(builder != nil && builder.bound)
	assert(builder.generation != 0)
	result := ui.fit_button_result(&builder.inner, widget)
	return {status = result.available ? .Available : .Unavailable, activated = result.activated}
}

button_results_dropped :: proc(builder: ^Builder) -> u64 {
	assert(builder != nil)
	return builder.inner.result_dropped
}
