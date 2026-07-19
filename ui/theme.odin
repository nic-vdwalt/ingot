// LIB-CANDIDATE: this package must import only core:* and vendor:raylib.
// Never import app packages — destined for a standalone Odin GUI library.
// Merged from openalloy/alloy (full app palette + macOS glass) plus
// ingot-only re-theme constants preserved for other consumers.
package ui

import rl "vendor:raylib"

// GLASS_ENABLED is true on macOS, where window_style_darwin.odin installs an
// NSVisualEffectView vibrancy backdrop behind the GL view. Large surface fills
// become translucent so the frosted blur shows through; other platforms keep
// fully opaque fills.
GLASS_ENABLED :: ODIN_OS == .Darwin

when GLASS_ENABLED {
	// Windowed: translucent so the frosted vibrancy shows through.
	BG_APP_WINDOWED   :: rl.Color{30, 30, 30, 162}
	BG_CHAT_WINDOWED  :: rl.Color{28, 28, 30, 207}
	BG_PANEL_WINDOWED :: rl.Color{36, 36, 40, 212}
	// Fullscreen: near-opaque so the warm backdrop fallback doesn't bleed.
	BG_APP_FULLSCREEN   :: rl.Color{30, 30, 30, 245}
	BG_CHAT_FULLSCREEN  :: rl.Color{28, 28, 30, 250}
	BG_PANEL_FULLSCREEN :: rl.Color{36, 36, 40, 250}
	// Mutable; updated per-frame by set_glass_fullscreen().
	BG_APP:   rl.Color = BG_APP_WINDOWED
	BG_CHAT:  rl.Color = BG_CHAT_WINDOWED
	BG_PANEL: rl.Color = BG_PANEL_WINDOWED
} else {
	BG_APP:   rl.Color = rl.Color{30, 30, 30, 255}
	BG_CHAT:  rl.Color = rl.Color{30, 30, 30, 255}
	BG_PANEL: rl.Color = rl.Color{40, 40, 40, 255}
}

// Color palette.
BG_COLOR         :: rl.Color{30, 30, 30, 255}       // Dark background
BG_SECONDARY     :: rl.Color{40, 40, 40, 255}       // Slightly lighter
BG_ACTIVE        :: rl.Color{50, 50, 60, 255}       // Active tab/selection
BG_HOVER         :: rl.Color{55, 55, 65, 255}       // Hover state
BG_INPUT         :: rl.Color{45, 45, 50, 255}       // Input field background
BG_CODE          :: rl.Color{35, 35, 40, 255}       // Code block background

FG_PRIMARY       :: rl.Color{220, 220, 220, 255}    // Primary text
FG_SECONDARY     :: rl.Color{160, 160, 170, 255}    // Secondary/muted text
FG_ACCENT        :: rl.Color{100, 160, 255, 255}    // Accent (links, active)
FG_USER          :: rl.Color{180, 200, 255, 255}    // User message
FG_ASSISTANT     :: rl.Color{200, 220, 200, 255}    // Assistant message
FG_ERROR         :: rl.Color{255, 120, 120, 255}    // Error text
FG_SUCCESS       :: rl.Color{120, 220, 120, 255}    // Success text
FG_TOOL          :: rl.Color{200, 180, 120, 255}    // Tool activity
FG_DIFF_REMOVE   :: rl.Color{255, 140, 140, 255}   // Diff: removed lines (pinkish-red)
FG_DIFF_ADD      :: rl.Color{140, 230, 140, 255}   // Diff: added lines (green)
BG_DIFF_REMOVE   :: rl.Color{60, 30, 30, 255}      // Diff: removed cell background
BG_DIFF_ADD      :: rl.Color{28, 50, 30, 255}      // Diff: added cell background
FG_DIFF_GUTTER   :: rl.Color{110, 110, 120, 255}   // Diff: line-number gutter

BORDER_COLOR     :: rl.Color{70, 70, 80, 255}       // Borders
BORDER_SUBTLE    :: rl.Color{52, 52, 60, 255}       // Hairline borders (cards, dividers)
BADGE_COLOR      :: rl.Color{255, 100, 100, 255}    // Unread badge
MERGE_LINK_COLOR :: rl.Color{70, 110, 170, 255}     // Joined/merged tab-group link

BUTTON_BG        :: rl.Color{60, 100, 180, 255}     // Button background
BUTTON_HOVER     :: rl.Color{70, 120, 200, 255}     // Button hover
BUTTON_TEXT      :: rl.Color{255, 255, 255, 255}     // Button text

// Unified button system.
BTN_ROUNDNESS    :: f32(0.3)
BTN_SEGMENTS     :: i32(6)
BTN_BORDER_W     :: f32(1.0)

BG_POPUP         :: rl.Color{35, 35, 42, 255}       // Command menu popup background
FG_DISABLED      :: rl.Color{90, 90, 100, 255}      // Disabled command text

BG_PLAN_BAR      :: rl.Color{60, 50, 20, 255}       // Plan mode bar background
FG_PLAN          :: rl.Color{255, 200, 80, 255}      // Plan mode text/accent
FG_PLANNING      :: rl.Color{110, 170, 240, 255}     // Planning mode accent (soft blue)
BG_SELECTION     :: rl.Color{60, 80, 130, 255}       // Text selection highlight

// Plan sidebar title card (the H1 plan title shown above "Plan Progress").
BG_PLAN_TITLE       :: rl.Color{48, 42, 24, 255}    // Dark-amber title card background

// Tool card styling.
BG_TOOL_CARD       :: rl.Color{38, 38, 45, 255}    // Card background
BG_TOOL_CARD_HOVER :: rl.Color{45, 45, 55, 255}    // Card hover state
FG_HEADING       :: rl.Color{230, 230, 240, 255}     // Heading text
FG_BULLET        :: rl.Color{140, 160, 200, 255}     // Bullet point dot
FG_BOLD          :: rl.Color{255, 255, 255, 255}     // Bold text (white)
FG_CODE_INLINE   :: rl.Color{214, 182, 150, 255}     // Inline `code` text (non-file)

// Table layout.
BG_TABLE_HEADER  :: rl.Color{45, 45, 52, 255}       // Header row background

// Agent-busy wave bar.
WAVE_COLOR_A   :: rl.Color{30, 95, 138, 255}   // dark ocean blue #1e5f8a
WAVE_COLOR_B   :: rl.Color{126, 206, 240, 255} // light sky blue #7ecef0
WAVE_BAR_COUNT :: 28   // number of bars (count, not pixels)

// Circular wave-ring connecting animation.
VORTEX_SQUASH      :: f32(0.82)  // vertical squash ratio (not a pixel size)

// Split view ratios (not pixel sizes).
SPLIT_MIN_RATIO    :: f32(0.2)
SPLIT_MAX_RATIO    :: f32(0.8)

// User prompt card width ratio within the chat column (not a pixel size).
USER_CARD_MAX_RATIO :: f32(0.72)

// Drag-and-drop delivery animation duration (seconds, not pixels).
DROP_ANIM_DUR    :: 0.85

// Nvim scroll speed (separate from UI scroll; nvim handles its own DPI).
NVIM_SCROLL_SPEED :: 0.5

// Input and cache limits (character / entry counts, not pixels).
INPUT_MAX_LEN    :: 262144
TOOL_MAX_LINES   :: 20

// ---------------------------------------------------------------------------
// Pixel-dimension layout variables.
// These start at their 96-DPI base values and are rescaled at startup by
// set_ui_scale() in scale.odin whenever the OS reports a higher DPI factor.
// ---------------------------------------------------------------------------

// Font sizes.
FONT_SIZE: i32       = 16
FONT_SIZE_LARGE: i32 = 20
FONT_SIZE_SMALL: i32 = 13
LINE_HEIGHT: i32     = 22

// Embedded terminal / nvim grid metrics (shared by both renderers). Scaled by
// set_ui_scale() so the character grid follows the UI scale.
NVIM_FONT_SIZE: i32 = 16
NVIM_CELL_PAD: i32  = 6  // extra vertical padding per cell
NVIM_MARGIN: i32    = 10 // breathing room between pane edges and the grid

// General layout.
TAB_BAR_HEIGHT: i32      = 35
CAPTION_BTN_W: i32       = 46 // custom title bar caption button width (Windows)
INPUT_BAR_HEIGHT: i32    = 50
PADDING: i32             = 10
TAB_WIDTH: i32           = 180
TAB_MIN_WIDTH: i32       = 70
TAB_CLOSE_SIZE: i32      = 16
TAB_ICON_SIZE: i32       = 18
COMMAND_ITEM_HEIGHT: i32 = 28
POPUP_MAX_WIDTH: i32     = 400
SCROLL_SPEED: f32        = 15.0

// Height of the staged-attachment chip row above the composer.
ATTACHMENT_CHIP_ROW_H: i32 = 28

// Drag-and-drop drop target + delivery animation.
DROP_ZONE_H: i32     = 56
DROP_ZONE_BG     :: rl.Color{45, 55, 75, 235}
DROP_ZONE_BORDER :: rl.Color{100, 160, 255, 255} // == FG_ACCENT

// Split view divider.
SPLIT_DIVIDER_W: i32 = 4

// Plan sidebar.
PLAN_SIDEBAR_W: i32           = 300
PLAN_SIDEBAR_COLLAPSED_W: i32 = 30
PLAN_SIDEBAR_ROW_H: i32       = 22
PLAN_TITLE_ACCENT_W: i32      = 3
PLAN_TITLE_PAD: i32           = 8

// Background shells panel.
SHELLS_PANEL_W: i32 = 360

// Debug watch sidebar.
DEBUG_SIDEBAR_W: i32           = 320
DEBUG_SIDEBAR_COLLAPSED_W: i32 = 30
DEBUG_SIDEBAR_ROW_H: i32       = 28
DEBUG_TITLE_ACCENT_W: i32      = 3
DEBUG_TITLE_PAD: i32           = 8
FG_DEBUG              :: rl.Color{180, 140, 255, 255}  // Purple accent for debug panel
BG_DEBUG_TITLE        :: rl.Color{40, 32, 52, 255}     // Dark purple title card background
FG_DEBUG_CHANGED      :: rl.Color{255, 180, 80, 255}   // Amber for changed values
FG_DEBUG_ANNOTATION   :: rl.Color{140, 160, 180, 255}  // Muted blue-gray for annotations

// Background of an attachment chip.
BG_CHIP      :: rl.Color{55, 60, 72, 255}
BG_CHIP_HOVER :: rl.Color{70, 76, 92, 255}

// Flat chat message styling.
BG_USER_CARD        :: rl.Color{44, 52, 74, 255}    // Compact user prompt card
BORDER_USER_CARD    :: rl.Color{78, 96, 140, 255}   // 1px card border
BG_BAND_ERROR       :: rl.Color{52, 34, 34, 255}    // Error message tint band
FG_LABEL            :: rl.Color{130, 135, 150, 255} // Small uppercase role/section labels
CHAT_MAX_W: i32          = 860 // Centered reading-column cap
MSG_GAP: i32             = 14  // Vertical gap between chat elements
USER_CARD_PAD_H: i32     = 12
USER_CARD_PAD_V: i32     = 8
USER_CARD_RADIUS_PX: f32 = 8
USER_CARD_MIN_W: i32     = 48

// Tool card styling.
TOOL_BORDER_W: i32   = 2
TOOL_CARD_PAD_V: i32 = 4
TOOL_CARD_PAD_H: i32 = 8
TOOL_CARD_GAP: i32   = 4

// Unified panel/list metrics (consistency pass).
ROW_H_SM: i32       = 24 // dense list rows (plan/debug/git files)
ROW_H_MD: i32       = 28 // primary list rows (browser, pickers)
PANEL_HEADER_H: i32 = 34 // shared panel header band
CARD_RADIUS_PX: f32 = 6  // shared card corner radius

// Markdown layout.
CODE_BLOCK_PAD: i32 = 8
BULLET_INDENT: i32  = 20
TABLE_CELL_PAD: i32 = 8

// Wave-bar animation (agent busy indicator in chat).
WAVE_BAR_W: i32     = 3
WAVE_BAR_GAP: i32   = 3
WAVE_BAR_MAX_H: i32 = 18
WAVE_BAR_MIN_H: i32 = 3

// Vortex connecting animation (ring of radial bars).
VORTEX_RADIUS: f32 = 56.0
VORTEX_INNER: f32  = 12.0

// --- ingot-only palette constants (not present in the alloy superset) ------
BG_APP:   rl.Color = {30, 31, 34, 255}   // #1E1F22 — guild rail / app base
BG_CHAT:  rl.Color = {49, 51, 56, 255}   // #313338 — chat area
BG_PANEL: rl.Color = {43, 45, 49, 255}   // #2B2D31 — channel list / member list
BUTTON_DANGER_BG    :: rl.Color{80, 35, 35, 255}   // Danger button background
BUTTON_DANGER_HOVER :: rl.Color{62, 36, 36, 255}   // Danger button hover
BUTTON_DANGER_FG    :: rl.Color{255, 180, 180, 255} // Danger button text
BUTTON_DISABLED_BG :: rl.Color{47, 49, 54, 255}  // Disabled button background
BUTTON_PRESSED   :: rl.Color{58, 67, 160, 255}   // Button pressed (mouse held)
FG_ACCENT_LIGHT  :: rl.Color{129, 140, 248, 255} // Lighter accent for text on dark
FG_MUTED_DIM     :: rl.Color{110, 115, 122, 255} // Dimmed text (muted users, disabled)
MODAL_DIM        :: rl.Color{0, 0, 0, 140}       // Backdrop dim behind modals
PILL_TINT_ALPHA :: u8(38)
