package psx

import "moonhug:packages/engine"

// A level's lighting settings: whether its geometry is lit at all, and the
// ambient light added on top of the baked and live lights. One per level
// scene; psx_level.apply hands it to the renderer when the level loads.
@(component={max=4, menu="PSX/PsxEnvironment"})
@(typ_guid={guid = "5bdf6d7c-4cf9-42c5-9408-ee32b034b656"})
PsxEnvironment :: struct {
	using base: engine.CompData `inspect:"-"`,
	lighting_enabled:   bool,
	ambient_kind:       Ambient_Kind,
	ambient_color:      [4]f32 `decor:color()`,
	// HEMISPHERE only: the ambient colour of surfaces facing down.
	ambient_ground_color: [4]f32 `decor:color()`,
}

reset_PsxEnvironment :: proc(e: ^PsxEnvironment) {
	e.lighting_enabled = true
	e.ambient_kind = .CONSTANT
	e.ambient_color = {0, 0, 0, 1}
	e.ambient_ground_color = {0, 0, 0, 1}
}
