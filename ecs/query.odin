package ecs

// Queries iterate the smallest participating set's dense array and probe the
// others through their sparse arrays, so cost is O(len(smallest set)). The
// driving set is chosen once at iterator construction; structural changes
// (destroy/add/remove) during iteration must go through Deferred, so counts
// stay stable while an iterator is live.

Iter2 :: struct($A, $B: typeid) {
	a:      ^Set(A),
	b:      ^Set(B),
	driven: ^Set_Header,
	cursor: u32,
}

Iter3 :: struct($A, $B, $C: typeid) {
	a:      ^Set(A),
	b:      ^Set(B),
	c:      ^Set(C),
	driven: ^Set_Header,
	cursor: u32,
}

Iter4 :: struct($A, $B, $C, $D: typeid) {
	a:      ^Set(A),
	b:      ^Set(B),
	c:      ^Set(C),
	d:      ^Set(D),
	driven: ^Set_Header,
	cursor: u32,
}

iter2 :: proc(a: ^Set($A), b: ^Set($B)) -> Iter2(A, B) {
	assert(a != nil, "iter2: nil set a")
	assert(b != nil, "iter2: nil set b")
	result := Iter2(A, B) {
		a      = a,
		b      = b,
		driven = &a.header,
	}
	if b.header.count < result.driven.count do result.driven = &b.header
	return result
}

iter2_next :: proc(it: ^Iter2($A, $B)) -> (entity: Entity, a: ^A, b: ^B, ok: bool) {
	assert(it != nil, "iter2_next: nil iterator")
	assert(it.cursor <= it.driven.count, "iter2_next: cursor past driving set")
	for it.cursor < it.driven.count {
		candidate := it.driven.entities[it.cursor]
		it.cursor += 1
		value_a := _probe(it.a, candidate)
		if value_a == nil do continue
		value_b := _probe(it.b, candidate)
		if value_b == nil do continue
		return candidate, value_a, value_b, true
	}
	return ENTITY_NIL, nil, nil, false
}

iter3 :: proc(a: ^Set($A), b: ^Set($B), c: ^Set($C)) -> Iter3(A, B, C) {
	assert(a != nil, "iter3: nil set a")
	assert(b != nil && c != nil, "iter3: nil set b or c")
	result := Iter3(A, B, C) {
		a      = a,
		b      = b,
		c      = c,
		driven = &a.header,
	}
	if b.header.count < result.driven.count do result.driven = &b.header
	if c.header.count < result.driven.count do result.driven = &c.header
	return result
}

iter3_next :: proc(it: ^Iter3($A, $B, $C)) -> (entity: Entity, a: ^A, b: ^B, c: ^C, ok: bool) {
	assert(it != nil, "iter3_next: nil iterator")
	assert(it.cursor <= it.driven.count, "iter3_next: cursor past driving set")
	for it.cursor < it.driven.count {
		candidate := it.driven.entities[it.cursor]
		it.cursor += 1
		value_a := _probe(it.a, candidate)
		if value_a == nil do continue
		value_b := _probe(it.b, candidate)
		if value_b == nil do continue
		value_c := _probe(it.c, candidate)
		if value_c == nil do continue
		return candidate, value_a, value_b, value_c, true
	}
	return ENTITY_NIL, nil, nil, nil, false
}

iter4 :: proc(a: ^Set($A), b: ^Set($B), c: ^Set($C), d: ^Set($D)) -> Iter4(A, B, C, D) {
	assert(a != nil, "iter4: nil set a")
	assert(b != nil && c != nil && d != nil, "iter4: nil set b, c, or d")
	result := Iter4(A, B, C, D) {
		a      = a,
		b      = b,
		c      = c,
		d      = d,
		driven = &a.header,
	}
	if b.header.count < result.driven.count do result.driven = &b.header
	if c.header.count < result.driven.count do result.driven = &c.header
	if d.header.count < result.driven.count do result.driven = &d.header
	return result
}

iter4_next :: proc(
	it: ^Iter4($A, $B, $C, $D),
) -> (
	entity: Entity,
	a: ^A,
	b: ^B,
	c: ^C,
	d: ^D,
	ok: bool,
) {
	assert(it != nil, "iter4_next: nil iterator")
	assert(it.cursor <= it.driven.count, "iter4_next: cursor past driving set")
	for it.cursor < it.driven.count {
		candidate := it.driven.entities[it.cursor]
		it.cursor += 1
		value_a := _probe(it.a, candidate)
		if value_a == nil do continue
		value_b := _probe(it.b, candidate)
		if value_b == nil do continue
		value_c := _probe(it.c, candidate)
		if value_c == nil do continue
		value_d := _probe(it.d, candidate)
		if value_d == nil do continue
		return candidate, value_a, value_b, value_c, value_d, true
	}
	return ENTITY_NIL, nil, nil, nil, nil, false
}

// _probe answers "does entity have this component" and hands back the typed
// pointer in one sparse lookup; nil means absent.
_probe :: proc(set: ^Set($T), entity: Entity) -> ^T {
	assert(set != nil, "_probe: nil set")
	assert(entity.index < u32(len(set.header.sparse)), "_probe: entity index out of range")
	slot := set.header.sparse[entity.index]
	if slot == 0 do return nil
	return &set.items[slot - 1]
}
