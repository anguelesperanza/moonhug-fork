package psx_demo

import "core:fmt"
import "core:math"
import "core:encoding/uuid"
import "core:path/filepath"
import b3 "vendor:box3d"
import "moonhug:libs/input"
import "moonhug:libs/log"
import "moonhug:packages/engine"
import "moonhug:packages/physics3d"
import "moonhug:packages/psx"
import "moonhug:packages/psx_camera"
import "moonhug:packages/psx_controls"
import "moonhug:packages/psx_level"

// The demo game: the framework's main.odin as a component. It keeps the player
// and the camera across levels, swaps levels (scenes loaded next to this one),
// and answers the debug keys that toggle every feature of the PSX look.
//
//   H      hide this help            F11   fullscreen
//   WASD   move / turn               TAB   widescreen
//   N      next level                I     interlaced video mode
//   R      recentre the drag camera  U     interlacing
//   V      vertex snapping           T     texture mode
//   G      subdivision               L     lighting
//   B      dim ambient               O     overbright
//   C      colour depth              X     dithering
//   F      draw distance and fog     K     colour key
//   M      player blend mode         P     CRT effects
//   Y      overscan                 F12   screenshot
@(component={max=1, menu="PSX Demo/PsxDemo"})
@(typ_guid={guid = "a9fb93d4-1e86-4a89-ba27-307c8b704206"})
PsxDemo :: struct {
	using base: engine.CompData `inspect:"-"`,
	// The level scenes, in the order N cycles through them.
	levels:      [dynamic]engine.Asset_GUID `ext:"scene" expand`,
	// The one entered first.
	first_level: i32 `decor:min(0)`,
	// Level geometry is split to edges of this many metres when G turns
	// subdivision on.
	subdivision: f32 `decor:min(0)`,

	level:       i32 `json:"-" inspect:"-"`,         // index into `levels` of the one loaded, -1 none
	scene:       ^engine.Scene `json:"-" inspect:"-"`, // that level's scene
	started:     bool `json:"-" inspect:"-"`,
	dim_ambient: bool `json:"-" inspect:"-"`,
	show_help:   bool `json:"-" inspect:"-"`,
	// A level was entered: once physics has built its colliders (the next fixed
	// step), the player is put at its spawn and the camera set up.
	respawn:     bool `json:"-" inspect:"-"`,
	load_tick:   u64 `json:"-" inspect:"-"`,
}

cleanup_PsxDemo :: proc(d: ^PsxDemo) {
	delete(d.levels)
	engine.comp_zero(d)
}

reset_PsxDemo :: proc(d: ^PsxDemo) {
	d.first_level = 0
	d.subdivision = 1
	d.level = -1
	d.show_help = true
}

// What the demo dims the level's ambient to with B.
DIM_AMBIENT :: psx.Ambient{kind = .CONSTANT, color = {40.0 / 255, 40.0 / 255, 48.0 / 255, 1}}

// The fog and draw distance F toggles.
SHORT_DRAW_DISTANCE :: f32(12)
FOG_COLOR           :: [4]u8{30, 50, 70, 255}

CAMERA_WALL_MARGIN  :: f32(0.25)
CAMERA_MIN_DISTANCE :: f32(0.5)

// The physics layers: level colliders are on the first, the player on the
// second, and rays that look for walls and floors see only the first.
LAYER_WORLD  :: u64(1)

@(update={order=100})
psx_demo_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(psx_demos(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		_tick(d, dt)
		return
	}
}

@(private = "file")
_Actors :: struct {
	player_tH:  engine.Transform_Handle,
	player:     ^PsxDemoPlayer,
	character:  ^psx_controls.PsxCharacter,
	camera_tH:  engine.Transform_Handle,
	rig:        ^psx_camera.PsxCameraRig,
}

@(private = "file")
_find_actors :: proc() -> (a: _Actors, ok: bool) {
	w := engine.ctx_world()
	pit := engine.pool_iterator(psx_demo_players(w))
	for p, _ in engine.pool_next(&pit) {
		if !p.enabled do continue
		a.player_tH, a.player = p.owner, p
		_, a.character = engine.transform_get_comp(p.owner, psx_controls.PsxCharacter)
		break
	}
	rit := engine.pool_iterator(psx_camera.psx_camera_rigs(w))
	for r, _ in engine.pool_next(&rit) {
		if !r.enabled do continue
		a.camera_tH, a.rig = r.owner, r
		break
	}
	return a, a.player != nil && a.character != nil && a.rig != nil
}

@(private = "file")
_tick :: proc(d: ^PsxDemo, dt: f32) {
	actors, ok := _find_actors()
	if !ok do return

	if !d.started {
		d.started = true
		psx.set_fps(.NTSC)
		psx.set_subdivision(d.subdivision)
		if len(d.levels) > 0 do _enter_level(d, int(clamp(d.first_level, 0, i32(len(d.levels) - 1))), actors)
	}

	if position, teleport := script_step(); teleport do _place_player(actors, position)
	if script_drag() {
		feet := engine.transform_world(actors.player_tH).position - PLAYER_BODY_OFFSET
		psx_camera.use_drag_camera(actors.camera_tH, feet, actors.character.facing)
	}
	_keys(d, actors)

	if d.respawn && engine.fixed_tick_index() > d.load_tick do _respawn(d, actors)

	// The keys' wish becomes a velocity: the solver decides where it ends up,
	// which is what makes a wall stop the player.
	psx_controls.update_tank_controls(actors.character, dt)
	if body, has := physics3d.body_of(actors.player_tH); has {
		b3.Body_SetLinearVelocity(body, actors.character.move * actors.player.move_speed)
	}
	_face_model(actors)

	feet := engine.transform_world(actors.player_tH).position - PLAYER_BODY_OFFSET

	// The door: walking into the bedroom swap zone while facing it enters the
	// bedroom.
	if d.level == 1 && len(d.levels) > 2 {
		if tH, zone, found := psx_level.find_entity("bedroom_swap_event", d.scene); found {
			if psx_level.entity_contains(tH, zone, feet) && _is_facing(actors.character.facing, feet, psx_level.entity_position(tH)) {
				_enter_level(d, 2, actors)
			}
		}
	}

	psx_camera.camera_update(actors.camera_tH, feet, dt)

	// The drag camera stays in front of walls: a ray from its focus back toward
	// where it sits pulls it in to what it hits, instantly, and eases it back out.
	if actors.rig.mode == .DRAG {
		origin, translation := psx_camera.drag_camera_ray(actors.rig)
		limit := f32(0)
		if point, hit := _cast_ray(origin, translation); hit {
			limit = max(math.sqrt(_length_sq(point - origin)) - CAMERA_WALL_MARGIN, CAMERA_MIN_DISTANCE)
		}
		psx_camera.set_drag_camera_limit(actors.rig, limit)
	}

	if d.show_help do _render_help(d, actors)
}

// Loads level `index` next to this scene, then lets go of the one before it
// (a level that fails to load leaves the old one standing), and hands the new
// level's lights to the renderer.
@(private = "file")
_enter_level :: proc(d: ^PsxDemo, index: int, actors: _Actors) -> bool {
	path, found := engine.asset_db_get_path(uuid.Identifier(d.levels[index]))
	if !found {
		log.errorf("[PSX Demo] level %d names no scene", index)
		return false
	}
	scene := engine.scene_load_additive_path(path)
	if scene == nil {
		log.errorf("[PSX Demo] could not load %s", path)
		return false
	}
	if d.scene != nil && engine.sm_scene_is_valid(d.scene) do engine.sm_scene_unload(d.scene)
	d.scene = scene
	d.level = i32(index)

	lighting := psx_level.apply_lighting(scene)
	if d.dim_ambient do psx.set_ambient(DIM_AMBIENT)
	_ = lighting

	// Level geometry is baked at its first draw; the player waits for the level's
	// colliders to be built before it is put down.
	d.respawn = true
	d.load_tick = engine.fixed_tick_index()
	log.infof("[PSX Demo] level: %s", filepath.base(path))
	return true
}

// Puts the player at the level's spawn, standing on the floor under it, and
// sets the camera: the level's fixed shots if it has any, else the drag camera
// trailing the player.
@(private = "file")
_respawn :: proc(d: ^PsxDemo, actors: _Actors) {
	d.respawn = false

	position: [3]f32
	if tH, _, found := psx_level.find_entity("player_spawn", d.scene); found {
		position = psx_level.entity_position(tH)
		actors.character.facing = psx_level.entity_facing(tH)
	}
	if point, hit := _cast_ray(position + {0, 1, 0}, {0, -3, 0}); hit do position.y = point.y

	_place_player(actors, position)

	psx_camera.reset_shots(actors.camera_tH)
	if psx_camera.count_shots(d.scene) > 0 {
		actors.rig.mode = .FIXED
	} else {
		psx_camera.use_drag_camera(actors.camera_tH, position, actors.character.facing)
	}
}

// Puts the player's feet at `position` and stops it: the transform and the body.
@(private = "file")
_place_player :: proc(actors: _Actors, position: [3]f32) {
	center := position + PLAYER_BODY_OFFSET
	engine.transform_set_world_position(actors.player_tH, center)
	if body, has := physics3d.body_of(actors.player_tH); has {
		b3.Body_SetTransform(body, center, 1)
		b3.Body_SetLinearVelocity(body, {})
	}
}

// The model turns to the way the character faces.
@(private = "file")
_face_model :: proc(actors: _Actors) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(actors.player_tH))
	if t == nil || len(t.children) == 0 do return
	// The facing points along (cos, 0, sin) while a right-handed turn about +Y
	// sends +X to (cos, 0, -sin): the angle is negated.
	if model := engine.pool_get(&w.transforms, t.children[0].handle); model != nil {
		model.rotation = engine.quat_from_euler_xyz(0, -actors.character.facing * math.DEG_PER_RAD, 0)
	}
}

// The player's visible model: its first child's PsxRenderer.
@(private = "file")
_model_renderer :: proc(actors: _Actors) -> ^psx.PsxRenderer {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(actors.player_tH))
	if t == nil || len(t.children) == 0 do return nil
	_, r := engine.transform_get_comp(engine.Transform_Handle(t.children[0].handle), psx.PsxRenderer)
	return r
}

// Whether `point` is within 45 degrees of the way the character faces.
@(private = "file")
_is_facing :: proc(facing: f32, from, point: [3]f32) -> bool {
	to := point - from
	length := math.sqrt(to.x * to.x + to.z * to.z)
	if length < 0.001 do return true
	dir := [2]f32{math.cos(facing), math.sin(facing)}
	return (dir.x * to.x + dir.y * to.z) / length > math.cos(f32(math.PI / 4))
}

@(private = "file")
_length_sq :: proc(v: [3]f32) -> f32 {
	return v.x * v.x + v.y * v.y + v.z * v.z
}

// The first wall or floor along a ray, ignoring the player.
@(private = "file")
_cast_ray :: proc(origin, translation: [3]f32) -> (point: [3]f32, hit: bool) {
	filter := b3.DefaultQueryFilter()
	filter.maskBits = LAYER_WORLD
	result := b3.World_CastRayClosest(physics3d.world(), origin, translation, filter)
	return result.point, result.hit
}

// --- the debug keys ---------------------------------------------------------------

@(private = "file")
_pressed :: proc(key: input.Key) -> bool {
	return input.key_pressed(key) || script_pressed(key)
}

@(private = "file")
_keys :: proc(d: ^PsxDemo, actors: _Actors) {
	pressed :: _pressed

	if pressed(.TAB) do psx.set_display_aspect(.WIDESCREEN)

	if pressed(.V) {
		psx.set_vertex_snapping(!psx.is_vertex_snapping())
		log.infof("vertex snapping: %v", psx.is_vertex_snapping())
	}

	if pressed(.T) {
		psx.set_texture_mode(psx.get_texture_mode() == .AFFINE ? .PERSPECTIVE : .AFFINE)
		log.infof("texture mode: %v", psx.get_texture_mode())
	}

	if pressed(.G) {
		psx.set_subdivision(psx.get_subdivision() > 0 ? 0 : d.subdivision)
		log.infof("subdivision max edge: %v", psx.get_subdivision())
	}

	if pressed(.L) {
		psx.set_lighting(!psx.is_lighting())
		log.infof("lighting: %v", psx.is_lighting())
	}

	if pressed(.B) {
		d.dim_ambient = !d.dim_ambient
		if d.dim_ambient {
			psx.set_ambient(DIM_AMBIENT)
		} else if d.scene != nil {
			psx.set_ambient(psx_level.collect_lighting(d.scene).ambient)
		}
		log.infof("ambient: %v", psx.get_ambient())
	}

	if pressed(.C) {
		psx.set_color_depth(psx.get_color_depth() == .BITS_15 ? .BITS_24 : .BITS_15)
		log.infof("colour depth: %v", psx.get_color_depth())
	}

	if pressed(.X) {
		psx.set_dithering(!psx.is_dithering())
		log.infof("dithering: %v", psx.is_dithering())
	}

	if pressed(.F) {
		if psx.get_draw_distance() > 0 {
			psx.set_draw_distance(0)
			psx.set_fog(0, 0, {})
		} else {
			psx.set_draw_distance(SHORT_DRAW_DISTANCE)
			psx.set_fog(SHORT_DRAW_DISTANCE / 2, SHORT_DRAW_DISTANCE, FOG_COLOR)
		}
		log.infof("draw distance: %v", psx.get_draw_distance())
	}

	if pressed(.K) {
		psx.set_color_key(!psx.is_color_key())
		log.infof("colour key: %v", psx.is_color_key())
	}

	if pressed(.M) {
		if r := _model_renderer(actors); r != nil {
			r.blend = psx.Blend_Mode((int(r.blend) + 1) % len(psx.Blend_Mode))
			log.infof("player blend mode: %v", r.blend)
		}
	}

	if pressed(.O) {
		psx.set_overbright(!psx.is_overbright())
		log.infof("overbright: %v", psx.is_overbright())
	}

	if pressed(.N) && len(d.levels) > 0 {
		_enter_level(d, (int(d.level) + 1) % len(d.levels), actors)
	}

	if pressed(.P) {
		psx.set_post_effects(psx.get_post_effects() == {} ? psx.POST_EFFECTS_CRT : {})
		log.infof("post effects: %v", psx.get_post_effects())
	}

	if pressed(.Y) {
		effects := psx.get_post_effects()
		effects.overscan = !effects.overscan
		psx.set_post_effects(effects)
		log.infof("overscan: %v", effects.overscan)
	}

	if pressed(.I) {
		psx.set_video_mode(psx.get_video_mode() == .NTCS_I ? .NTCS_P : .NTCS_I)
		log.infof("video mode: %v", psx.get_video_mode())
	}

	if pressed(.U) {
		psx.set_interlacing(!psx.is_interlacing())
		log.infof("interlacing: %v", psx.is_interlacing())
	}

	if pressed(.F11) {
		psx.set_fullscreen(!psx.is_fullscreen())
		log.infof("fullscreen: %v", psx.is_fullscreen())
	}

	if pressed(.H) do d.show_help = !d.show_help

	if pressed(.F12) {
		psx.request_screenshot("psx_screenshot.png")
		log.infof("screenshot: psx_screenshot.png")
	}

	if pressed(.R) && actors.rig.mode == .DRAG {
		psx_camera.recenter_drag_camera(actors.rig, actors.character.facing)
	}
}

// The key list, drawn over the screen (SCREEN text: at the window's
// resolution, over the CRT effects): a key and what it does, with a black
// shadow.
@(private = "file")
_render_help :: proc(d: ^PsxDemo, actors: _Actors) {
	on_off :: proc(value: bool) -> string { return value ? "on" : "off" }

	post := psx.get_post_effects()
	draw_distance := psx.get_draw_distance()
	subdivision := psx.get_subdivision()
	level := d.scene != nil ? filepath.base(d.scene.path) : "none"
	blend := psx.Blend_Mode.OPAQUE
	if r := _model_renderer(actors); r != nil do blend = r.blend

	lines := [?][2]string{
		{"H", "hide this help"},
		{"WASD", "move / turn"},
		{"N", fmt.tprintf("next level: %s", level)},
		{"R", fmt.tprintf("recentre drag camera%s", actors.rig.mode == .DRAG ? "" : " (drag camera only)")},
		{"F11", fmt.tprintf("fullscreen: %s", on_off(psx.is_fullscreen()))},
		{"TAB", fmt.tprintf("widescreen: %v", psx.get_display_aspect())},
		{"I", fmt.tprintf("video mode: %v", psx.get_video_mode())},
		{"U", fmt.tprintf("interlacing: %s", on_off(psx.is_interlacing()))},
		{"V", fmt.tprintf("vertex snapping: %s", on_off(psx.is_vertex_snapping()))},
		{"T", fmt.tprintf("texture mode: %v", psx.get_texture_mode())},
		{"G", fmt.tprintf("subdivision: %s", subdivision > 0 ? fmt.tprintf("%v m", subdivision) : "off")},
		{"L", fmt.tprintf("lighting: %s", on_off(psx.is_lighting()))},
		{"B", fmt.tprintf("ambient: %s", d.dim_ambient ? "dim override" : "level")},
		{"O", fmt.tprintf("overbright: %s", on_off(psx.is_overbright()))},
		{"C", fmt.tprintf("colour depth: %v", psx.get_color_depth())},
		{"X", fmt.tprintf("dithering: %s", on_off(psx.is_dithering()))},
		{"F", fmt.tprintf("draw distance + fog: %s", draw_distance > 0 ? fmt.tprintf("%v m", draw_distance) : "off")},
		{"K", fmt.tprintf("colour key: %s", on_off(psx.is_color_key()))},
		{"M", fmt.tprintf("player blend mode: %v", blend)},
		{"P", fmt.tprintf("CRT effects: %s", on_off(post != {}))},
		{"Y", fmt.tprintf("overscan: %s", on_off(post.overscan))},
	}

	for line, i in lines {
		for text, column in line {
			position := [2]f32{16 + f32(column) * 90, 16 + f32(i) * 24}
			psx.render_text(text, position + 2, 20, {0, 0, 0, 255}, .SCREEN)
			psx.render_text(text, position, 20, {255, 255, 255, 255}, .SCREEN)
		}
	}
}
