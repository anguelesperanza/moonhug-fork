package psx

// The renderer's state and the API a game drives it with. The original kept one
// global struct (`si`) next to a raylib window; here the per-camera look lives
// on the PsxView component (so it is authored and saved with the scene) and the
// rest, the lights the level hands in and the queues the frame consumes, lives
// in `state`.
//
// Every set_* below changes the active PsxView, so a toggle shows in the
// inspector as it happens.

import "core:time"
import sdl "vendor:sdl3"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"

State :: struct {
	// What lights the level (psx_level.apply fills them, set_lights replaces them).
	lights:           [dynamic]Light,
	ambient:          Ambient,
	lighting_enabled: bool,
	// Baked vertex colours depend on the lights: bumped when they change, so
	// geometry baked under the old ones bakes again. (The ambient and the
	// lighting switch are applied by the shader and cost no rebake.)
	lights_version:   u64,

	// The interlaced field to draw next, and whether the display target has
	// nothing worth keeping (the first frame, or after it was recreated).
	field:            i32,
	interlace_fresh:  bool,
	last_size:        [2]i32, // the low-res frame's size last frame: a change recreates the display target

	texts:            [dynamic]Queued_Text,

	// The frame cap, 0 = uncapped.
	target_fps:       i32,
	last_frame:       time.Tick,

	last_report:      [3]int, // what the scene step last logged

	shaders_ready:    bool,
	slot_added:       bool,
}

state := State{
	lighting_enabled = true,
	interlace_fresh  = true,
}

// What a camera without a PsxView renders with, and what the set_* procs change
// while the scene has none.
@(private)
_fallback_view: PsxView
@(private)
_fallback_ready: bool

// The PsxView the frame renders with: the one on `camera` (a Camera's owner),
// else the first enabled one in the world, else a package default.
view_for :: proc(camera: engine.Transform_Handle) -> ^PsxView {
	if engine.ctx_get() != nil {
		if camera != {} {
			if _, v := get_comp(camera, PsxView); v != nil do return v
		}
		return active_view()
	}
	return _fallback()
}

// The first enabled PsxView in the world, else the package default.
active_view :: proc() -> ^PsxView {
	if engine.ctx_get() != nil && engine.ctx_world() != nil {
		it := engine.pool_iterator(psx_views(engine.ctx_world()))
		for v, _ in engine.pool_next(&it) {
			if v.enabled do return v
		}
	}
	return _fallback()
}

@(private)
_fallback :: proc() -> ^PsxView {
	if !_fallback_ready {
		_fallback_view = view_defaults()
		_fallback_ready = true
	}
	return &_fallback_view
}

// --- the look -------------------------------------------------------------------

set_vertex_snapping :: proc(enabled: bool) { active_view().vertex_snapping = enabled }
is_vertex_snapping  :: proc() -> bool { return active_view().vertex_snapping }

set_texture_mode :: proc(mode: Texture_Mode) { active_view().texture_mode = mode }
get_texture_mode :: proc() -> Texture_Mode { return active_view().texture_mode }

set_color_depth :: proc(depth: Color_Depth) { active_view().color_depth = depth }
get_color_depth :: proc() -> Color_Depth { return active_view().color_depth }

set_dithering :: proc(enabled: bool) { active_view().dithering = enabled }
is_dithering  :: proc() -> bool { return active_view().dithering }

set_color_key :: proc(enabled: bool) { active_view().color_key = enabled }
is_color_key  :: proc() -> bool { return active_view().color_key }

set_overbright :: proc(enabled: bool) { active_view().overbright = enabled }
is_overbright  :: proc() -> bool { return active_view().overbright }

// The far clip plane, in world units. 0 keeps the camera's own.
set_draw_distance :: proc(distance: f32) { active_view().draw_distance = max(distance, 0) }
get_draw_distance :: proc() -> f32 { return active_view().draw_distance }

// Sets fog (PS1-style depth cueing), per vertex: `start` and `end` are world
// units from the camera where fog begins and where it is solid; end <= start
// turns it off. `color` (0..255) is what things fade into, usually the camera's
// clear colour so the fog hides the draw distance. Fog is worked out per vertex,
// so large polygons fog unevenly, as on the PS1: split big surfaces for even fog.
set_fog :: proc(start, end: f32, color: [4]u8) {
	v := active_view()
	v.fog_start = start
	v.fog_end = end
	v.fog_color = {f32(color.r), f32(color.g), f32(color.b), f32(color.a)} / 255
}

set_post_effects :: proc(effects: Post_Effects) { active_view().post = effects }
get_post_effects :: proc() -> Post_Effects { return active_view().post }

set_display_aspect :: proc(aspect: Display_Aspect) { active_view().display_aspect = aspect }
get_display_aspect :: proc() -> Display_Aspect { return active_view().display_aspect }

set_video_mode :: proc(mode: Mode) { active_view().video_mode = mode }
get_video_mode :: proc() -> Mode { return active_view().video_mode }

set_interlacing :: proc(enabled: bool) {
	v := active_view()
	if enabled && !v.interlacing do state.interlace_fresh = true
	v.interlacing = enabled
}
is_interlacing :: proc() -> bool { return active_view().interlacing }

// Level geometry is split to edges no longer than `max_edge` metres when it
// bakes. 0 turns it off.
set_subdivision :: proc(max_edge: f32) { active_view().subdivision = max(max_edge, 0) }
get_subdivision :: proc() -> f32 { return active_view().subdivision }

// --- lighting -------------------------------------------------------------------

set_lighting :: proc(enabled: bool) { state.lighting_enabled = enabled }
is_lighting :: proc() -> bool { return state.lighting_enabled }

set_ambient :: proc(ambient: Ambient) { state.ambient = ambient }
get_ambient :: proc() -> Ambient { return state.ambient }

set_lights :: proc(lights: []Light) {
	clear(&state.lights)
	append(&state.lights, ..lights)
	state.lights_version += 1
}
get_lights :: proc() -> []Light { return state.lights[:] }

// --- window ---------------------------------------------------------------------

// Borderless fullscreen at the monitor's resolution.
set_fullscreen :: proc(enabled: bool) {
	if w := gfx.window(); w != nil do sdl.SetWindowFullscreen(w, enabled)
}

is_fullscreen :: proc() -> bool {
	w := gfx.window()
	return w != nil && .FULLSCREEN in sdl.GetWindowFlags(w)
}

// Caps the frame rate: NTSC 30 fps, PAL 25 fps, or any other. 0 = uncapped.
// Only the standalone player caps itself, an editor's frame is its own.
set_fps_mode :: proc(mode: Fps_Mode) {
	switch mode {
	case .NTSC: state.target_fps = 30
	case .PAL:  state.target_fps = 25
	}
}

set_fps_value :: proc(value: i32) {
	state.target_fps = max(value, 0)
}

set_fps :: proc { set_fps_mode, set_fps_value }

// The frame limiter: sleeps off what is left of the frame's budget. The
// frame's period is measured between two calls, so the time the previous
// frame took to render counts against the budget.
@(late_update)
psx_frame_limit :: proc(dt: f32) {
	if state.target_fps <= 0 || engine.application_is_editor() do return
	budget := time.Duration(f64(time.Second) / f64(state.target_fps))
	if state.last_frame._nsec != 0 {
		elapsed := time.tick_since(state.last_frame)
		if elapsed < budget do time.sleep(budget - elapsed)
	}
	state.last_frame = time.tick_now()
}
