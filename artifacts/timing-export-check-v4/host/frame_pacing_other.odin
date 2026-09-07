#+build !darwin
package main

Frame_Pacer :: struct {}

frame_pacer_start :: proc(value: ^Frame_Pacer) -> bool {
	return false
}

frame_pacer_wait :: proc(value: ^Frame_Pacer) -> f64 {
	return 0
}

frame_pacer_stop :: proc(value: ^Frame_Pacer) {}
