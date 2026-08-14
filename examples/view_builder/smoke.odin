#+build !js
package main

import "core:fmt"
import "core:os"
import "ingot:view"

when SMOKE {
	smoke_frames: int

	smoke_step :: proc(data: ^State) {
		assert(data != nil)
		smoke_frames += 1
		switch smoke_frames {
		case 2:
			add_label(data)
		case 4:
			save(data)
		case 6:
			load(data)
		case 8:
			delete_last(data)
		case 10:
			if result, ok := view.view_validate(view.view_of(&data.doc)); !ok {
				fmt.eprintfln("smoke: invalid document: %v", result)
				os.exit(1)
			}
			fmt.printfln("smoke: ok, %d nodes", data.doc.count)
			os.exit(0)
		}
	}
}
