package fit

import "ingot:ui"

// Re-exports ui's fixed-capacity label builder so gallery and app code can
// build per-frame labels without core:fmt (see ui/label_text.odin for why).
LABEL_TEXT_BYTES_MAX :: ui.LABEL_TEXT_BYTES_MAX
Label_Text :: ui.Label_Text

label_text_reset :: ui.label_text_reset
label_text_string :: ui.label_text_string
label_text_byte :: ui.label_text_byte
label_text_int :: ui.label_text_int
label_text_int_padded :: ui.label_text_int_padded
label_text_hex2 :: ui.label_text_hex2
label_text_float :: ui.label_text_float
label_text_temp :: ui.label_text_temp
label_text_ctemp :: ui.label_text_ctemp
