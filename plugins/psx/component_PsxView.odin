package psx

import "moonhug:packages/engine"

// The PSX look of the camera it sits on. A Camera whose `slot` is "Psx"
// renders through this plugin's frame (psx_scene, psx_post, psx_present) and
// reads every setting here, so they are edited in the inspector and saved with
// the scene. Runtime toggles (the psx.set_* procs) change this component, so
// what the game does to the look is visible in the inspector as it happens.
//
// A camera with no PsxView renders with the defaults below.
@(component={max=8, menu="PSX/PsxView"})
@(typ_guid={guid = "37c12555-5059-4c1c-a0ec-da1227a4e6a6"})
PsxView :: struct {
	using base: engine.CompData `inspect:"-"`,

	resolution:      Resolution,
	video_mode:      Mode,
	display_aspect:  Display_Aspect,
	// The frame's lines are redrawn a field at a time: motion combs. Only the
	// interlaced video modes (NTCS_I, PAL_I) have fields to draw.
	interlacing:     bool,
	vertex_snapping: bool,
	texture_mode:    Texture_Mode,
	color_depth:     Color_Depth,
	dithering:       bool,
	// Pure black texels and alpha below one half are not drawn, everything
	// else is opaque.
	color_key:       bool,
	// Lighting clamps at 2 instead of 1, with baked colours stored at half
	// strength like the PS1's 128 = 1.0.
	overbright:      bool,

	// Depth cueing, per vertex: fog begins at `fog_start` world units from the
	// camera and is solid at `fog_end` (end <= start is no fog). The colour
	// is usually the camera's clear colour, so it hides the draw distance.
	fog_start:       f32 `decor:min(0)`,
	fog_end:         f32 `decor:min(0)`,
	fog_color:       [4]f32 `decor:color()`,
	// The far clip plane. 0 keeps the camera's own far clip. Pair it with fog.
	draw_distance:   f32 `decor:min(0)`,
	// Level geometry is split so no edge is longer than this many metres when
	// it is baked, which hides affine warping and gives vertex lighting more
	// vertices to work with. 0 = off.
	subdivision:     f32 `decor:min(0)`,

	post:            Post_Effects,
}

reset_PsxView :: proc(v: ^PsxView) {
	v.resolution      = .RES_ONE
	v.video_mode      = .NTCS_P
	v.display_aspect  = .STRETCH
	v.interlacing     = true
	v.vertex_snapping = true
	v.texture_mode    = .AFFINE
	v.color_depth     = .BITS_15
	v.dithering       = true
	v.color_key       = false
	v.overbright      = true
	v.fog_start       = 0
	v.fog_end         = 0
	v.fog_color       = {0, 0, 0, 1}
	v.draw_distance   = 0
	v.subdivision     = 0
	v.post            = {}
}

// The defaults a camera without a PsxView renders with.
view_defaults :: proc() -> PsxView {
	v: PsxView
	reset_PsxView(&v)
	return v
}
