package shared

import fit "ingot:fit"
import rl "ingot:gfx"

Game_Init_Proc               :: proc(ctx: ^rl.Context) -> bool
Game_Prepare_Proc            :: proc()
Game_Draw_Proc               :: proc(builder: ^fit.Builder)
Game_Uses_Custom_Cursor_Proc :: proc() -> bool
Game_Should_Quit_Proc        :: proc() -> bool
Game_Theme_Proc              :: proc() -> fit.Theme
Game_Shutdown_Proc           :: proc()
