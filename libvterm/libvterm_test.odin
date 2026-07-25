package libvterm

import "core:testing"

@(test)
abi_layout_matches_libvterm_0_3_3 :: proc(t: ^testing.T) {
	testing.expect(t, vterm_abi_validate())
	testing.expect_value(t, size_of(VTerm_Value), 16)
	testing.expect_value(t, size_of(VTerm_String_Fragment), 16)
	testing.expect_value(t, size_of(VTerm_Screen_Callbacks), 72)
}
