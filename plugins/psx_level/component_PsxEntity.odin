package psx_level

import "moonhug:packages/engine"

// The shapes a level entity can have: a point (a spawn), a box or a sphere
// (a trigger zone).
Shape_Kind :: enum u8 {
	POINT,
	BOX,
	SPHERE,
}

// A named place in a level: where the player spawns ("player_spawn"), a zone
// that something happens in ("bedroom_swap_event"). The name is the object's
// own name in the hierarchy; the game looks it up with find_entity.
//
// The Stargate editor called these entities with a shape; the shape is the
// same: a BOX is half extents around the transform (scaled and turned by it), a
// SPHERE a radius in `size.x` (scaled by the largest axis).
@(component={menu="PSX/PsxEntity"})
@(typ_guid={guid = "cfee3376-60b0-4c31-8e59-b966433fbd86"})
PsxEntity :: struct {
	using base: engine.CompData `inspect:"-"`,
	kind:       Shape_Kind,
	size:       [3]f32,
}

reset_PsxEntity :: proc(e: ^PsxEntity) {
	e.kind = .POINT
	e.size = {0.5, 0.5, 0.5}
}
