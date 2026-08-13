package fit

import "ingot:ui"
import "ingot:ui_gfx"

Builder :: struct {
	inner: ui.Fit_Builder,
	root:  ui.Ui,
	bound: bool,
}

Storage_Node :: ui.Prepared_Node
Storage :: ui.Fit_Storage
STORAGE_NODE_DEFAULT :: ui.MAX_PREPARED_NODES
STORAGE_NODE_HARD_MAX :: ui.MAX_PREPARED_NODES_HARD

App :: struct {
	inner:    ui_gfx.App,
	builder:  Builder,
	draw:     Draw_Proc,
	userdata: rawptr,
}

Session :: struct {
	inner:   ui_gfx.Session,
	frame:   ui_gfx.Session_Frame,
	builder: Builder,
	open:    bool,
}

State :: ui_gfx.App_State
Frame_Pacing :: ui_gfx.App_Frame_Pacing
Config :: ui_gfx.App_Config
Session_Config :: ui_gfx.Session_Config

Draw_Proc :: #type proc(builder: ^Builder, userdata: rawptr)
Shutdown_Proc :: #type proc(app: ^App, userdata: rawptr)

Callbacks :: struct {
	draw:     Draw_Proc,
	shutdown: Shutdown_Proc,
}

Track :: ui.Track
Track_Kind :: ui.Track_Kind
Space :: ui.Space
Cross_Align :: ui.Cross_Align
Main_Align :: ui.Main_Align
Text_Role :: ui.Text_Role
Ink :: ui.Ink
Button_Style :: ui.Btn_Style
Widget_Id :: ui.Widget_Id
Rect :: ui.Rect_I32
Size :: ui.Intrinsic_Size
Z_Order :: ui.Z_Order
Transition_State :: ui.Transition_Rect_State
Transition_Options :: ui.Transition_Options
Aspect_Ratio :: ui.Aspect_Ratio

Size_Options :: ui.Prepared_Size
Transition :: ui.Prepared_Transition
Container_Effects :: ui.Prepared_Container_Effects
Container_Options :: ui.Prepared_Container_Options
Flow_Options :: ui.Prepared_Flow_Options
Grid_Options :: ui.Prepared_Grid_Options
Attachment_Options :: ui.Prepared_Attachment_Options
Attachment_Target :: ui.Attachment_Target_Kind
Attachment_Point :: ui.Attachment_Point
Label_Options :: ui.Fit_Label_Options
Button_Options :: ui.Fit_Button_Options
Custom_Options :: ui.Fit_Custom_Options
Custom_Spec :: ui.Prepared_Custom

Fixed :: ui.fixed
Grow :: ui.grow
Percent :: ui.percent
Fit :: ui.fit
