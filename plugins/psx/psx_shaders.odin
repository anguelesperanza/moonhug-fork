package psx

// The PSX shaders. Their GLSL lives in shaders/, compiled offline to the blobs
// in shaders/compiled (compile_shaders.sh, the way `mh shaders` does the
// engine's) and embedded with #load, so a game ships no toolchain. They are
// registered with gfx the first time a frame needs them: gfx has to be up (a
// window and a device), which is not true when packages initialise.

import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

// The world shader: the PSX vertex stage and fragment stage over the engine's
// vertex format. Meshes draw with it through gfx.draw_mesh's `shader`.
WORLD_SHADER     :: "psx_world"
// Fullscreen shaders, drawn with gfx.draw_fullscreen.
INTERLACE_SHADER :: "psx_interlace"
COMPOSITE_SHADER :: "psx_composite"
PRESENT_SHADER   :: "psx_present"

@(private = "file") _WORLD_VERT_SPV     :: #load("shaders/compiled/psx.vert.spv")
@(private = "file") _WORLD_VERT_MSL     :: #load("shaders/compiled/psx.vert.msl")
@(private = "file") _WORLD_FRAG_SPV     :: #load("shaders/compiled/psx.frag.spv")
@(private = "file") _WORLD_FRAG_MSL     :: #load("shaders/compiled/psx.frag.msl")
@(private = "file") _INTERLACE_FRAG_SPV :: #load("shaders/compiled/psx_interlace.frag.spv")
@(private = "file") _INTERLACE_FRAG_MSL :: #load("shaders/compiled/psx_interlace.frag.msl")
@(private = "file") _COMPOSITE_FRAG_SPV :: #load("shaders/compiled/psx_composite.frag.spv")
@(private = "file") _COMPOSITE_FRAG_MSL :: #load("shaders/compiled/psx_composite.frag.msl")
@(private = "file") _PRESENT_FRAG_SPV   :: #load("shaders/compiled/psx_present.frag.spv")
@(private = "file") _PRESENT_FRAG_MSL   :: #load("shaders/compiled/psx_present.frag.msl")

// Registers the shaders once. False (with the reason logged) when gfx refuses
// one, in which case the frame draws nothing rather than draw wrong.
shaders_ensure :: proc() -> bool {
	if state.shaders_ready do return true
	if gfx.device() == nil do return false

	// The engine pushes a light block at fragment slot 0 and its draw block at
	// slot 2 for every mesh draw (the built-in unlit shader declares all three
	// for that reason); the PSX block is slot 1.
	if !gfx.shader_exists(WORLD_SHADER) {
		if !gfx.shader_register(WORLD_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _WORLD_FRAG_SPV, _WORLD_FRAG_MSL, frag_samplers = 1, frag_uniform_buffers = gfx.DRAW_UNIFORM_SLOT + 1) {
			log.errorf("[PSX] the world shader failed to register")
			return false
		}
	}
	if !_register_fullscreen(INTERLACE_SHADER, _INTERLACE_FRAG_SPV, _INTERLACE_FRAG_MSL, 1) do return false
	if !_register_fullscreen(COMPOSITE_SHADER, _COMPOSITE_FRAG_SPV, _COMPOSITE_FRAG_MSL, 2) do return false
	if !_register_fullscreen(PRESENT_SHADER, _PRESENT_FRAG_SPV, _PRESENT_FRAG_MSL, 1) do return false

	state.shaders_ready = true
	return true
}

@(private = "file")
_register_fullscreen :: proc(name: string, spv, msl: []u8, samplers: u32) -> bool {
	if gfx.fullscreen_exists(name) do return true
	if !gfx.fullscreen_register(name, spv, msl, samplers, 2) {
		log.errorf("[PSX] the %s shader failed to register", name)
		return false
	}
	return true
}
