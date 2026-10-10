package fit

import "ingot:ui"

@(private = "package")
to_key :: proc(value: Key) -> ui.Key {
	// Why transmute: fit.Key is a value-subset of ui.Key with identical i32
	// codes; the #assert beside the declaration and fit_key_contract_complete
	// enumerate every member and check it.
	return transmute(ui.Key)value
}

@(private = "package")
to_semantic_role :: proc(value: Semantic_Role) -> ui.Sem_Role {
	// Why transmute: both enums are u8 with identical ordinals; fit omits only
	// the trailing .Link, which the #assert beside the declaration pins and
	// fit_roles_contract_complete checks per member.
	return transmute(ui.Sem_Role)value
}
