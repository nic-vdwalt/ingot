// ingot:gfx — the "raylib of WebGPU". Core public types deliberately mirror
// raylib's shapes (same names, same enum values) so consuming Odin apps migrate
// mechanically: `import rl "vendor:raylib"` -> `import rl "ingot:gfx"`, then the
// existing `rl.*` call sites keep resolving. Values that map onto GLFW/GPU state
// match raylib exactly (KeyboardKey == GLFW key codes, etc.).
package gfx

// --- math / color ----------------------------------------------------------

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
	UNKNOWN                   = 0,
	UNCOMPRESSED_GRAYSCALE    = 1,
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

Camera3D :: struct {
	position:   Vector3,
	target:     Vector3,
	up:         Vector3,
	fovy:       f32,
	projection: CameraProjection,
}
Camera :: Camera3D

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
ConfigFlags :: distinct bit_set[ConfigFlag; i32]

// Convenience alias used by some call sites (raylib exposes KEY_NULL sentinel).
KEY_NULL :: KeyboardKey.KEY_NULL
