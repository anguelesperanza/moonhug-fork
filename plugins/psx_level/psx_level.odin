package psx_level

// Level support for PSX games. A level is a MoonHug scene: meshes and
// colliders are the engine's and physics3d's own components, and what the
// original framework's Stargate importer gave a level on top (named entities
// with shapes, lights, the ambient setting) is PsxEntity, PsxLight and
// PsxEnvironment. A level loaded additively next to a persistent scene is
// asked about by scene, so the persistent scene's own lights do not mix in.

import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"
import "moonhug:packages/psx"

// The first PsxEntity named `name` in `scene` (any loaded scene when nil).
find_entity :: proc(name: string, scene: ^engine.Scene = nil) -> (tH: engine.Transform_Handle, entity: ^PsxEntity, ok: bool) {
	w := engine.ctx_world()
	it := engine.pool_iterator(psx_entities(w))
	for e, _ in engine.pool_next(&it) {
		if !e.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(e.owner))
		if t == nil || (scene != nil && t.scene != scene) do continue
		if t.name == name do return e.owner, e, true
	}
	return {}, nil, false
}

entity_position :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.transform_world(tH).position
}

// The yaw the entity faces, radians, as atan2(z, x) of its forward (-Z): the
// convention the character controls use for `facing`.
entity_facing :: proc(tH: engine.Transform_Handle) -> f32 {
	rot := engine.quat_to_matrix3(engine.transform_world(tH).rotation)
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
	return math.atan2(forward.z, forward.x)
}

// Whether `point` is inside the entity's shape. A POINT contains nothing.
entity_contains :: proc(tH: engine.Transform_Handle, entity: ^PsxEntity, point: [3]f32) -> bool {
	tw := engine.transform_world(tH)
	switch entity.kind {
	case .POINT:
		return false
	case .SPHERE:
		scale := tw.scale
		radius := entity.size.x * max(abs(scale.x), abs(scale.y), abs(scale.z))
		return linalg.length(point - tw.position) <= radius
	case .BOX:
		world := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		if abs(linalg.determinant(world)) < 1e-12 do return false
		local := (linalg.matrix4_inverse(world) * [4]f32{point.x, point.y, point.z, 1}).xyz
		return abs(local.x) <= entity.size.x && abs(local.y) <= entity.size.y && abs(local.z) <= entity.size.z
	}
	return false
}

// A level's lighting as the renderer takes it: every PsxLight in `scene` in
// world space (the temp allocator), the PsxEnvironment's ambient, and whether
// the level is lit at all (its environment says so and it has lights).
Level_Lighting :: struct {
	lights:  []psx.Light,
	ambient: psx.Ambient,
	lit:     bool,
}

collect_lighting :: proc(scene: ^engine.Scene = nil) -> (out: Level_Lighting) {
	w := engine.ctx_world()
	lights := make([dynamic]psx.Light, context.temp_allocator)

	it := engine.pool_iterator(psx.psx_lights(w))
	for l, _ in engine.pool_next(&it) {
		if !l.enabled || !engine.transform_active_in_hierarchy(l.owner) do continue
		t := engine.pool_get(&w.transforms, engine.Handle(l.owner))
		if t == nil || (scene != nil && t.scene != scene) do continue

		tw := engine.transform_world(l.owner)
		rot := engine.quat_to_matrix3(tw.rotation)
		direction := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
		if direction != {} do direction = linalg.normalize(direction)
		append(&lights, psx.Light{
			kind        = l.kind,
			position    = tw.position,
			direction   = direction,
			color       = l.color.rgb * l.intensity,
			range       = l.range,
			inner_angle = l.inner_angle,
			outer_angle = l.outer_angle,
		})
	}
	out.lights = lights[:]

	enabled := false
	env_it := engine.pool_iterator(psx.psx_environments(w))
	for e, _ in engine.pool_next(&env_it) {
		if !e.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(e.owner))
		if t == nil || (scene != nil && t.scene != scene) do continue
		out.ambient = psx.Ambient{kind = e.ambient_kind, color = e.ambient_color, ground_color = e.ambient_ground_color}
		enabled = e.lighting_enabled
		break
	}
	out.lit = enabled && len(out.lights) > 0
	return
}

// Hands the level's lights and ambient to the renderer, and switches lighting
// on when it has any: what the original did when it entered a level.
apply_lighting :: proc(scene: ^engine.Scene = nil) -> Level_Lighting {
	lighting := collect_lighting(scene)
	psx.set_lights(lighting.lights)
	psx.set_ambient(lighting.ambient)
	psx.set_lighting(lighting.lit)
	return lighting
}
