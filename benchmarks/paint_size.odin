package main

import "core:fmt"
import "ingot:ui"

main :: proc() {
	stats := ui.paint_storage_stats()
	fmt.println(stats)
}
