// LIB-CANDIDATE: this package must import only core:* and vendor:raylib.
// Never import app packages (state/, views/, protocol/, net/) — it is destined
// for extraction into a standalone Odin GUI library.
package ui

import rl "vendor:raylib"

// --- Discord-dark color palette ---------------------------------------------

BG_APP:   rl.Color = {30, 31, 34, 255}   // #1E1F22 — guild rail / app base
BG_CHAT:  rl.Color = {49, 51, 56, 255}   // #313338 — chat area
BG_PANEL: rl.Color = {43, 45, 49, 255}   // #2B2D31 — channel list / member list

BG_COLOR         :: rl.Color{30, 31, 34, 255}    // Dark base background
BG_SECONDARY     :: rl.Color{43, 45, 49, 255}    // Panel background
BG_ACTIVE        :: rl.Color{64, 66, 73, 255}    // Active row/selection
BG_HOVER         :: rl.Color{53, 55, 60, 255}    // Hover state
BG_INPUT         :: rl.Color{56, 58, 64, 255}    // Input field background
BG_CODE          :: rl.Color{40, 42, 46, 255}    // Code block background
BG_POPUP         :: rl.Color{35, 36, 40, 255}    // Modal / popup background

FG_PRIMARY       :: rl.Color{219, 222, 225, 255} // Primary text
FG_SECONDARY     :: rl.Color{148, 155, 164, 255} // Secondary/muted text
FG_ACCENT        :: rl.Color{88, 101, 242, 255}  // Blurple accent #5865F2
FG_ACCENT_LIGHT  :: rl.Color{129, 140, 248, 255} // Lighter accent for text on dark
FG_ERROR         :: rl.Color{242, 63, 66, 255}   // Error text
FG_SUCCESS       :: rl.Color{35, 165, 89, 255}   // Success / online green
FG_HEADING       :: rl.Color{242, 243, 245, 255} // Heading text
FG_BULLET        :: rl.Color{148, 155, 164, 255} // Bullet point dot
FG_BOLD          :: rl.Color{255, 255, 255, 255} // Bold text
FG_CODE_INLINE   :: rl.Color{219, 190, 160, 255} // Inline `code` text
FG_LABEL         :: rl.Color{148, 155, 164, 255} // Small uppercase section labels
FG_MUTED_DIM     :: rl.Color{110, 115, 122, 255} // Dimmed text (muted users, disabled)

BORDER_COLOR     :: rl.Color{63, 66, 72, 255}    // Borders
BORDER_SUBTLE    :: rl.Color{50, 52, 58, 255}    // Hairline borders
BADGE_COLOR      :: rl.Color{242, 63, 66, 255}   // Unread badge

BUTTON_BG        :: rl.Color{88, 101, 242, 255}  // Button background (blurple)
BUTTON_HOVER     :: rl.Color{71, 82, 196, 255}   // Button hover
BUTTON_PRESSED   :: rl.Color{58, 67, 160, 255}   // Button pressed (mouse held)
BUTTON_TEXT      :: rl.Color{255, 255, 255, 255} // Button text
BUTTON_DISABLED_BG :: rl.Color{47, 49, 54, 255}  // Disabled button background

BUTTON_DANGER_BG    :: rl.Color{80, 35, 35, 255}   // Danger button background
BUTTON_DANGER_HOVER :: rl.Color{62, 36, 36, 255}   // Danger button hover
BUTTON_DANGER_FG    :: rl.Color{255, 180, 180, 255} // Danger button text

MODAL_DIM        :: rl.Color{0, 0, 0, 140}       // Backdrop dim behind modals

BG_SELECTION     :: rl.Color{62, 80, 130, 255}   // Text selection highlight
BG_TABLE_HEADER  :: rl.Color{43, 45, 49, 255}    // Table header row background

// Unified button system (ratios, not pixels).
BTN_ROUNDNESS :: f32(0.3)
BTN_SEGMENTS  :: i32(6)
BTN_BORDER_W  :: f32(1.0)

// Input limits (character counts, not pixels).
INPUT_MAX_LEN :: 65536

// ---------------------------------------------------------------------------
// Pixel-dimension layout variables. These start at their 96-DPI base values
// and are rescaled at startup by set_ui_scale() in scale.odin.
// ---------------------------------------------------------------------------

// Font sizes.
FONT_SIZE: i32       = 16
FONT_SIZE_LARGE: i32 = 20
FONT_SIZE_SMALL: i32 = 13
LINE_HEIGHT: i32     = 22

// General layout.
PADDING: i32          = 10
INPUT_BAR_HEIGHT: i32 = 50
SCROLL_SPEED: f32     = 15.0

// Unified panel/list metrics.
ROW_H_SM: i32       = 24
ROW_H_MD: i32       = 32
PANEL_HEADER_H: i32 = 48
CARD_RADIUS_PX: f32 = 6

// Markdown layout.
CODE_BLOCK_PAD: i32 = 8
BULLET_INDENT: i32  = 20
TABLE_CELL_PAD: i32 = 8
