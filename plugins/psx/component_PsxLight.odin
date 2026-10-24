package psx

import "moonhug:packages/engine"

// A light the PSX renderer bakes into vertex colours (level geometry) and
// feeds to live lighting (things that move). The renderer takes its own light
// type rather than the engine's Light component: area lights, and a falloff
// that reaches zero at `range`, are part of how the original looked. The
// directional light shines along the transform's forward (-Z); point lights sit
// at the position; spot and area lights shine along forward from it.
//
// Collect the scene's lights into the renderer with psx_level.apply.
@(component={max=256, menu="PSX/PsxLight"})
@(typ_guid={guid = "ad2fa191-af25-4324-b853-1352c65c533c"})
PsxLight :: struct {
	using base: engine.CompData `inspect:"-"`,
	kind:        Light_Kind,
	color:       [4]f32 `decor:color()`, // alpha unused
	intensity:   f32 `decor:min(0)`,
	// Where the falloff reaches zero. Directional lights ignore it.
	range:       f32 `decor:min(0)`,
	// Spot: the cone's full-brightness and zero-brightness half angles, degrees.
	inner_angle: f32 `decor:min(0)`,
	outer_angle: f32 `decor:min(0)`,
}

reset_PsxLight :: proc(l: ^PsxLight) {
	l.kind        = .DIRECTIONAL
	l.color       = {1, 1, 1, 1}
	l.intensity   = 1
	l.range       = LIGHTING_DEFAULTS.light_range
	l.inner_angle = 20
	l.outer_angle = 30
}

Lighting_Defaults :: struct {
	light_range: f32,
}

LIGHTING_DEFAULTS :: Lighting_Defaults{
	light_range = 10,
}
