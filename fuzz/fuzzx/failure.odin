package fuzzx

Failure :: struct {
	class:     u32,
	op_index:  i32,
	message:   string,
	failed:    bool,
}

failure_make :: proc(class: u32, op_index: int, message: string) -> Failure {
	assert(class != 0, "failure_make: zero class")
	assert(op_index >= -1, "failure_make: invalid operation index")
	return {class = class, op_index = i32(op_index), message = message, failed = true}
}

expect :: proc(ok: bool, class: u32, op_index: int, message: string) -> Failure {
	if ok do return {}
	return failure_make(class, op_index, message)
}
