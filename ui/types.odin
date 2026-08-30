package ui

Vec2 :: [2]f32
Vector2 :: Vec2

Color :: distinct [4]u8

// Rect is the float paint rectangle: the renderer interpolates positions and
// sizes, so paint commands and hit tests carry subpixel precision.
Rect :: struct {
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}
Rectangle :: Rect

// Rect_I32 is the integer-pixel layout rectangle. Layout must land on whole
// screen-space pixels or repeated division drifts, so slots, containers, and
// widget geometry stay integral and convert to Rect only at the paint boundary.
Rect_I32 :: struct {
	x, y, w, h: i32,
}

// rect_f32 converts a layout rect to a paint rect at the one boundary where
// integer geometry meets the renderer.
rect_f32 :: proc(rect: Rect_I32) -> Rect {
	return {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
}

Font_Id :: distinct u32

Text_Metrics :: struct {
	ascent:       f32,
	descent:      f32,
	line_gap:     f32,
	line_advance: f32,
}

Mouse_Button :: enum i32 {
	LEFT,
	RIGHT,
	MIDDLE,
	SIDE,
	EXTRA,
	FORWARD,
	BACK,
}
MouseButton :: Mouse_Button

Cursor :: enum i32 {
	DEFAULT,
	ARROW,
	IBEAM,
	CROSSHAIR,
	POINTING_HAND,
	RESIZE_EW,
	RESIZE_NS,
	RESIZE_NWSE,
	RESIZE_NESW,
	RESIZE_ALL,
	NOT_ALLOWED,
}
MouseCursor :: Cursor

Key :: enum i32 {
	KEY_NULL      = 0,
	BACK          = 4,
	MENU          = 5,
	VOLUME_UP     = 24,
	VOLUME_DOWN   = 25,
	SPACE         = 32,
	APOSTROPHE    = 39,
	COMMA         = 44,
	MINUS         = 45,
	PERIOD        = 46,
	SLASH         = 47,
	ZERO          = 48,
	ONE           = 49,
	TWO           = 50,
	THREE         = 51,
	FOUR          = 52,
	FIVE          = 53,
	SIX           = 54,
	SEVEN         = 55,
	EIGHT         = 56,
	NINE          = 57,
	SEMICOLON     = 59,
	EQUAL         = 61,
	A             = 65,
	B             = 66,
	C             = 67,
	D             = 68,
	E             = 69,
	F             = 70,
	G             = 71,
	H             = 72,
	I             = 73,
	J             = 74,
	K             = 75,
	L             = 76,
	M             = 77,
	N             = 78,
	O             = 79,
	P             = 80,
	Q             = 81,
	R             = 82,
	S             = 83,
	T             = 84,
	U             = 85,
	V             = 86,
	W             = 87,
	X             = 88,
	Y             = 89,
	Z             = 90,
	LEFT_BRACKET  = 91,
	BACKSLASH     = 92,
	RIGHT_BRACKET = 93,
	GRAVE         = 96,
	ESCAPE        = 256,
	ENTER         = 257,
	TAB           = 258,
	BACKSPACE     = 259,
	INSERT        = 260,
	DELETE        = 261,
	RIGHT         = 262,
	LEFT          = 263,
	DOWN          = 264,
	UP            = 265,
	PAGE_UP       = 266,
	PAGE_DOWN     = 267,
	HOME          = 268,
	END           = 269,
	CAPS_LOCK     = 280,
	SCROLL_LOCK   = 281,
	NUM_LOCK      = 282,
	PRINT_SCREEN  = 283,
	PAUSE         = 284,
	F1            = 290,
	F2            = 291,
	F3            = 292,
	F4            = 293,
	F5            = 294,
	F6            = 295,
	F7            = 296,
	F8            = 297,
	F9            = 298,
	F10           = 299,
	F11           = 300,
	F12           = 301,
	KP_0          = 320,
	KP_1          = 321,
	KP_2          = 322,
	KP_3          = 323,
	KP_4          = 324,
	KP_5          = 325,
	KP_6          = 326,
	KP_7          = 327,
	KP_8          = 328,
	KP_9          = 329,
	KP_DECIMAL    = 330,
	KP_DIVIDE     = 331,
	KP_MULTIPLY   = 332,
	KP_SUBTRACT   = 333,
	KP_ADD        = 334,
	KP_ENTER      = 335,
	KP_EQUAL      = 336,
	LEFT_SHIFT    = 340,
	LEFT_CONTROL  = 341,
	LEFT_ALT      = 342,
	LEFT_SUPER    = 343,
	RIGHT_SHIFT   = 344,
	RIGHT_CONTROL = 345,
	RIGHT_ALT     = 346,
	RIGHT_SUPER   = 347,
	KB_MENU       = 348,
}
KeyboardKey :: Key

point_in_rect :: proc(point: Vec2, rect: Rect) -> bool {
	return(
		point.x >= rect.x &&
		point.x < rect.x + rect.width &&
		point.y >= rect.y &&
		point.y < rect.y + rect.height \
	)
}

// point_in_rect_i32 tests a pointer against a layout rect. Hit tests against
// layout geometry are common enough that routing every one through rect_f32
// invites each consumer to re-derive the edge semantics instead; four such
// copies existed before this was exported. Empty and negative rects contain
// nothing, because the comparison is half-open in both dimensions.
point_in_rect_i32 :: proc(point: Vec2, rect: Rect_I32) -> bool {
	return point_in_rect(point, rect_f32(rect))
}
