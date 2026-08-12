// ingot:gfx - the "raylib of WebGPU". Core public types deliberately mirror
// raylib's shapes (same names, same enum values) so consuming Odin apps migrate
// mechanically: `import rl "vendor:raylib"` -> `import rl "ingot:gfx"`, then the
// existing `rl.*` call sites keep resolving. Values that map onto GLFW/GPU state
// match raylib exactly (KeyboardKey == GLFW key codes, etc.).
package gfx

// --- math / color ----------------------------------------------------------

// Degree/radian conversion factors, matching raylib's raymath constants.
PI :: 3.14159265358979323846
RAD2DEG :: 180.0 / PI
DEG2RAD :: PI / 180.0

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

// Color: RGBA8. Kept as `distinct [4]u8` (like Odin's raylib binding) so `.r`,
// `.g`, `.b`, `.a` swizzles AND positional literals `Color{30,30,30,255}` work.
Color :: distinct [4]u8

Rectangle :: struct {
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

// --- image / texture / font ------------------------------------------------

PixelFormat :: enum i32 {
	UNKNOWN = 0,
	UNCOMPRESSED_GRAYSCALE = 1,
	UNCOMPRESSED_GRAY_ALPHA,
	UNCOMPRESSED_R5G6B5,
	UNCOMPRESSED_R8G8B8,
	UNCOMPRESSED_R5G5B5A1,
	UNCOMPRESSED_R4G4B4A4,
	UNCOMPRESSED_R8G8B8A8,
	UNCOMPRESSED_R32,
	UNCOMPRESSED_R32G32B32,
	UNCOMPRESSED_R32G32B32A32,
	UNCOMPRESSED_R16,
	UNCOMPRESSED_R16G16B16,
	UNCOMPRESSED_R16G16B16A16,
	COMPRESSED_DXT1_RGB,
	COMPRESSED_DXT1_RGBA,
	COMPRESSED_DXT3_RGBA,
	COMPRESSED_DXT5_RGBA,
	COMPRESSED_ETC1_RGB,
	COMPRESSED_ETC2_RGB,
	COMPRESSED_ETC2_EAC_RGBA,
	COMPRESSED_PVRT_RGB,
	COMPRESSED_PVRT_RGBA,
	COMPRESSED_ASTC_4x4_RGBA,
	COMPRESSED_ASTC_8x8_RGBA,
}

TextureFilter :: enum i32 {
	POINT = 0,
	BILINEAR,
	TRILINEAR,
	ANISOTROPIC_4X,
	ANISOTROPIC_8X,
	ANISOTROPIC_16X,
}

// Image: CPU-side pixel data (decoded from PNG/etc.).
Image :: struct {
	data:    rawptr,
	width:   i32,
	height:  i32,
	mipmaps: i32,
	format:  PixelFormat,
}

// Texture: GPU-side. `id` indexes an internal registry that owns the backing
// wgpu.Texture + view (see texture.odin / text.odin). Layout mirrors raylib so
// `.id`, `.width`, `.height` field access ports unchanged.
Texture :: struct {
	id:      u32,
	width:   i32,
	height:  i32,
	mipmaps: i32,
	format:  PixelFormat,
}
Texture2D :: Texture

// Font: mirrors the raylib fields ingot uses (`glyphCount`, `texture`). `_atlas`
// indexes the internal glyph-metric + atlas table built by the text stack.
Font :: struct {
	baseSize:     i32,
	glyphCount:   i32,
	glyphPadding: i32,
	texture:      Texture2D,
	_atlas:       u32,
}

// --- camera ----------------------------------------------------------------

CameraProjection :: enum i32 {
	PERSPECTIVE = 0,
	ORTHOGRAPHIC,
}

// The canonical world basis: right-handed ROS, +X forward, +Y left, +Z up,
// satisfying +X x +Y = +Z. Every 3D API in Ingot - camera vectors, model
// transforms, mesh positions and normals, lights, bounds, rays, and scene data
// - is expressed in it. Importers convert source data exactly once at the
// import/cook boundary so no renderer repeats the conversion. Held by
// camera_world_axes_are_right_handed.
//
// A geographic consumer maps its own names onto the same basis rather than
// redefining it: east/north/up is this basis with forward=east and left=north,
// because east x north = up.
CAMERA_WORLD_FORWARD :: Vector3{1, 0, 0}
CAMERA_WORLD_LEFT :: Vector3{0, 1, 0}
CAMERA_WORLD_UP :: Vector3{0, 0, 1}
CAMERA_WORLD_RIGHT :: Vector3{0, -1, 0}

Camera3D :: struct {
	position:   Vector3,
	target:     Vector3,
	up:         Vector3,
	fovy:       f32,
	projection: CameraProjection,
}
Camera :: Camera3D

// Motion rates use the camera-local ROS basis. Linear components are
// forward/left/up units per second; angular components are roll/pitch/yaw radians
// per second about those same axes. Zoom velocity dollies by changing target
// distance rather than field of view.
Camera3D_Motion :: struct {
	linear_velocity:  Vector3,
	angular_velocity: Vector3,
	zoom_velocity:    f32,
}

// Orbit_Camera_State is a bounded azimuth/elevation orbit about `target`.
//
// yaw is the azimuth of the CAMERA's offset from the target - atan2(offset.y,
// offset.x) - not the direction the camera looks, which is its opposite. Yaw 0
// therefore places the camera on the target's +X side looking back along -X.
// Positive yaw turns the offset from +X toward +Y, which is counter-clockwise
// seen from +Z looking down. pitch is the elevation of that same offset, so
// positive pitch lifts the camera above the target.
Orbit_Camera_State :: struct {
	target:   Vector3,
	yaw:      f32,
	pitch:    f32,
	distance: f32,
}

// Orbit_Camera_Input.pan is a world-space delta applied to the orbit target
// each update. There is no default binding for it because computing a useful
// pan (drag a grabbed ground point, edge scrolling) needs application
// knowledge such as picking; callers fill it in after
// orbit_camera_input_poll. pan_rate is the camera-relative keyboard channel:
// x pans right, y pans toward the view direction (ground-projected), scaled
// by Orbit_Camera_Config.pan_speed and the current distance.
Orbit_Camera_Input :: struct {
	rotate_rate:  Vector2,
	zoom_rate:    f32,
	pointer_drag: Vector2,
	scroll:       f32,
	pan:          Vector3,
	pan_rate:     Vector2,
}

// min_yaw/max_yaw clamp the azimuth only when max_yaw > min_yaw; the zero
// default leaves yaw unbounded, preserving free-orbit behaviour. pan_speed
// scales the keyboard pan channel; the zero default disables it.
Orbit_Camera_Config :: struct {
	world_up:               Vector3,
	rotate_speed:           f32,
	zoom_speed:             f32,
	drag_radians_per_pixel: f32,
	scroll_distance:        f32,
	min_distance:           f32,
	max_distance:           f32,
	min_pitch:              f32,
	max_pitch:              f32,
	min_yaw:                f32,
	max_yaw:                f32,
	pan_speed:              f32,
}

// Orbit_Camera_Key_Pair binds one camera axis to up to two keys, because the
// conventional binding is an arrow key and a letter key for the same action.
// KEY_NULL means unbound and is never queried against the platform.
Orbit_Camera_Key_Pair :: struct {
	primary:   KeyboardKey,
	secondary: KeyboardKey,
}

// Orbit_Camera_Mouse_Binding is an optional mouse-button role. `bound`
// distinguishes "unset" from LEFT, whose enum value is zero.
Orbit_Camera_Mouse_Binding :: struct {
	button: MouseButton,
	bound:  bool,
}

// Orbit_Camera_Bindings maps physical input to the semantic Orbit_Camera_Input.
// It is separate from Orbit_Camera_Config because a binding is a user
// preference while a config is a camera property: rebinding a key must not be
// able to change the pitch limits. The pan keys default to KEY_NULL
// (unbound); RTS-style schemes bind them to WASD and move rotation elsewhere.
Orbit_Camera_Bindings :: struct {
	rotate_left:        Orbit_Camera_Key_Pair,
	rotate_right:       Orbit_Camera_Key_Pair,
	zoom_in:            Orbit_Camera_Key_Pair,
	zoom_out:           Orbit_Camera_Key_Pair,
	pan_forward:        Orbit_Camera_Key_Pair,
	pan_back:           Orbit_Camera_Key_Pair,
	pan_left:           Orbit_Camera_Key_Pair,
	pan_right:          Orbit_Camera_Key_Pair,
	drag_button:        MouseButton,
	// drag_modifier gates pointer_drag: when bound (either key non-null),
	// the drag only rotates while a modifier key is held. Unbound keeps the
	// historical always-on behaviour.
	drag_modifier:      Orbit_Camera_Key_Pair,
	// pan_button marks a button as grab-pan intent, resolved by
	// orbit_camera_pointer_intent. It may equal drag_button; the modifier
	// then disambiguates (held = rotate, released = pan).
	pan_button:         Orbit_Camera_Mouse_Binding,
	pointer_drag_scale: Vector2,
}

// Orbit_Camera_Pointer_Intent is the resolved role of the current pointer
// drag, so poll and app-level pan code agree on who owns the button.
Orbit_Camera_Pointer_Intent :: enum {
	None,
	Rotate,
	Pan,
}

// Orbit_Camera_Grab_Pan anchors a world point at press so per-frame ray/plane
// intersection can keep it pinned under the cursor. The anchor pick is the
// application's job (terrain raycast, physics query); the plane math is not.
Orbit_Camera_Grab_Pan :: struct {
	active: bool,
	anchor: Vector3,
}

Camera2D :: struct {
	offset:   Vector2,
	target:   Vector2,
	rotation: f32,
	zoom:     f32,
}

// --- input enums (values match raylib == GLFW) -----------------------------

MouseButton :: enum i32 {
	LEFT    = 0,
	RIGHT   = 1,
	MIDDLE  = 2,
	SIDE    = 3,
	EXTRA   = 4,
	FORWARD = 5,
	BACK    = 6,
}

MouseCursor :: enum i32 {
	DEFAULT       = 0,
	ARROW         = 1,
	IBEAM         = 2,
	CROSSHAIR     = 3,
	POINTING_HAND = 4,
	RESIZE_EW     = 5,
	RESIZE_NS     = 6,
	RESIZE_NWSE   = 7,
	RESIZE_NESW   = 8,
	RESIZE_ALL    = 9,
	NOT_ALLOWED   = 10,
}

// GamepadButton mirrors raylib's face-direction ordering (not GLFW's A/B/X/Y
// order); the platform backends remap into this via _GLFW_PAD_REMAP /
// _W3C_PAD_REMAP so `rl.IsGamepadButtonDown(0, .RIGHT_FACE_DOWN)` ports as-is.
GamepadButton :: enum i32 {
	UNKNOWN = 0,
	LEFT_FACE_UP,
	LEFT_FACE_RIGHT,
	LEFT_FACE_DOWN,
	LEFT_FACE_LEFT,
	RIGHT_FACE_UP,
	RIGHT_FACE_RIGHT,
	RIGHT_FACE_DOWN,
	RIGHT_FACE_LEFT,
	LEFT_TRIGGER_1,
	LEFT_TRIGGER_2,
	RIGHT_TRIGGER_1,
	RIGHT_TRIGGER_2,
	MIDDLE_LEFT,
	MIDDLE,
	MIDDLE_RIGHT,
	LEFT_THUMB,
	RIGHT_THUMB,
}

GamepadAxis :: enum i32 {
	LEFT_X        = 0,
	LEFT_Y        = 1,
	RIGHT_X       = 2,
	RIGHT_Y       = 3,
	LEFT_TRIGGER  = 4,
	RIGHT_TRIGGER = 5,
}

// GAMEPAD_BUTTON_COUNT bounds the per-pad button state arrays (raylib exposes
// 17 buttons + UNKNOWN sentinel).
GAMEPAD_BUTTON_COUNT :: 18
GAMEPAD_AXIS_COUNT :: 6

// TRIGGER_PRESS_THRESHOLD converts the analog trigger axes (-1..1, rest -1)
// into the digital LEFT/RIGHT_TRIGGER_2 buttons.
TRIGGER_PRESS_THRESHOLD :: f32(0.1)

// _GLFW_PAD_REMAP maps a GLFW gamepad button index (SDL mapping order: A, B,
// X, Y, LB, RB, back, start, guide, L3, R3, dpad U/R/D/L) to the raylib
// GamepadButton above. Kept as data (not a switch) so it is unit-testable.
@(rodata)
_GLFW_PAD_REMAP := [15]GamepadButton {
	.RIGHT_FACE_DOWN, // A / cross
	.RIGHT_FACE_RIGHT, // B / circle
	.RIGHT_FACE_LEFT, // X / square
	.RIGHT_FACE_UP, // Y / triangle
	.LEFT_TRIGGER_1, // left bumper
	.RIGHT_TRIGGER_1, // right bumper
	.MIDDLE_LEFT, // back / select
	.MIDDLE_RIGHT, // start
	.MIDDLE, // guide
	.LEFT_THUMB,
	.RIGHT_THUMB,
	.LEFT_FACE_UP, // dpad up
	.LEFT_FACE_RIGHT, // dpad right
	.LEFT_FACE_DOWN, // dpad down
	.LEFT_FACE_LEFT, // dpad left
}

// _W3C_PAD_REMAP maps a W3C standard-gamepad button index (browser Gamepad
// API) to the raylib GamepadButton. Differs from GLFW: triggers are digital
// buttons 6/7 and the dpad order is U/D/L/R.
@(rodata)
_W3C_PAD_REMAP := [17]GamepadButton {
	.RIGHT_FACE_DOWN, // 0 A / cross
	.RIGHT_FACE_RIGHT, // 1 B / circle
	.RIGHT_FACE_LEFT, // 2 X / square
	.RIGHT_FACE_UP, // 3 Y / triangle
	.LEFT_TRIGGER_1, // 4 left bumper
	.RIGHT_TRIGGER_1, // 5 right bumper
	.LEFT_TRIGGER_2, // 6 left trigger (analog button)
	.RIGHT_TRIGGER_2, // 7 right trigger (analog button)
	.MIDDLE_LEFT, // 8 back / select
	.MIDDLE_RIGHT, // 9 start
	.LEFT_THUMB, // 10
	.RIGHT_THUMB, // 11
	.LEFT_FACE_UP, // 12 dpad up
	.LEFT_FACE_DOWN, // 13 dpad down
	.LEFT_FACE_LEFT, // 14 dpad left
	.LEFT_FACE_RIGHT, // 15 dpad right
	.MIDDLE, // 16 guide
}

KeyboardKey :: enum i32 {
	KEY_NULL      = 0,
	// Android buttons
	BACK          = 4,
	MENU          = 5,
	VOLUME_UP     = 24,
	VOLUME_DOWN   = 25,
	// Alphanumeric
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
	// Function
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
	// Keypad
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
	// Modifiers
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

// --- config flags ----------------------------------------------------------

ConfigFlag :: enum i32 {
	FULLSCREEN_MODE          = 1,
	WINDOW_RESIZABLE         = 2,
	WINDOW_UNDECORATED       = 3,
	WINDOW_TRANSPARENT       = 4,
	MSAA_4X_HINT             = 5,
	VSYNC_HINT               = 6,
	WINDOW_HIDDEN            = 7,
	WINDOW_ALWAYS_RUN        = 8,
	WINDOW_MINIMIZED         = 9,
	WINDOW_MAXIMIZED         = 10,
	WINDOW_UNFOCUSED         = 11,
	WINDOW_TOPMOST           = 12,
	WINDOW_HIGHDPI           = 13,
	WINDOW_MOUSE_PASSTHROUGH = 14,
	BORDERLESS_WINDOWED_MODE = 15,
	INTERLACED_HINT          = 16,
}
ConfigFlags :: distinct bit_set[ConfigFlag;i32]

// Convenience alias used by some call sites (raylib exposes KEY_NULL sentinel).
KEY_NULL :: KeyboardKey.KEY_NULL
