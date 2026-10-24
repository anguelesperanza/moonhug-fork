package psx

// PSX lighting, ported from the framework's baked and live vertex lighting.
//
// Baked: each vertex of level geometry gets the sum of every light's
// contribution folded into its colour when the geometry is first drawn
// (psx_mesh.odin), at half strength: the shader doubles it back, which is how
// the PS1's 128 = 1.0 gives lighting a 2x range. Gouraud shading is then just
// the GPU interpolating those colours across each triangle.
//
// Live: for a thing that moves, the three strongest lights at its centre
// become directional lights for the whole object, and the shader works out
// each vertex's share from its normal.

import "core:math"
import "core:math/linalg"

// What one light adds at a point with a surface normal: its colour times the
// cosine of the angle to the light, scaled by a falloff that reaches zero at
// `range` (and, for spots and areas, by how far inside the cone the point is).
light_contribution :: proc(light: Light, position, normal: [3]f32) -> [3]f32 {
	to_light := -light.direction
	falloff  := f32(1)

	if light.kind != .DIRECTIONAL {
		offset   := light.position - position
		distance := linalg.length(offset)
		if distance >= light.range do return {}
		if distance > 1e-4 do to_light = offset / distance
		falloff = 1 - distance / light.range

		#partial switch light.kind {
		case .SPOT:
			along := linalg.dot(-to_light, light.direction)
			falloff *= math.smoothstep(math.cos(math.to_radians(light.outer_angle)), math.cos(math.to_radians(light.inner_angle)), along)
		case .AREA_RECT, .AREA_DISK:
			falloff *= max(linalg.dot(-to_light, light.direction), 0)
		}
	}

	return light.color * max(linalg.dot(normal, to_light), 0) * falloff
}

// The sum of every light at a vertex: what bakes into its colour (before the
// halving).
light_at :: proc(lights: []Light, position, normal: [3]f32) -> (total: [3]f32) {
	for light in lights do total += light_contribution(light, position, normal)
	return
}

// The three strongest lights at `center`, as the directions toward them and
// what reaches the object from each, for the shader's live lighting.
Live_Lights :: struct {
	directions: [3][3]f32,
	colors:     [3][3]f32,
}

live_lights_at :: proc(lights: []Light, center: [3]f32) -> (live: Live_Lights) {
	strengths: [3]f32

	for light in lights {
		to_light := -light.direction
		reach    := light.color

		if light.kind != .DIRECTIONAL {
			offset := light.position - center
			if linalg.length(offset) > 1e-4 do to_light = linalg.normalize(offset)
			reach = light_contribution(light, center, to_light)
		}

		strength := reach.r + reach.g + reach.b
		if strength <= 0 do continue

		// Replace the weakest slot this one beats.
		slot := -1
		for k in 0 ..< 3 {
			if strength > strengths[k] && (slot < 0 || strengths[k] < strengths[slot]) do slot = k
		}
		if slot < 0 do continue

		strengths[slot]       = strength
		live.directions[slot] = to_light
		live.colors[slot]     = reach
	}
	return
}
