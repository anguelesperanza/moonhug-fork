package psx

import "moonhug:packages/engine"

// How the MeshRenderer on the same object draws in the PSX frame. An object
// without one is level geometry: BAKED, white, opaque.
//
// Things that move want LIVE lighting: baked geometry is merged into a few big
// meshes when the level first draws, and a baked object that moves afterwards
// is baked again (slowly). `blend` is the PS1's semi-transparency.
@(component={menu="PSX/PsxRenderer"})
@(typ_guid={guid = "532f96ae-2e44-42ca-895a-69bd97ce1df6"})
PsxRenderer :: struct {
	using base: engine.CompData `inspect:"-"`,
	lighting: Lighting_Mode,
	blend:    Blend_Mode,
	// Multiplied into the texture, like the tint of the original's DrawModel.
	tint:     [4]f32 `decor:color()`,
}

reset_PsxRenderer :: proc(r: ^PsxRenderer) {
	r.lighting = .BAKED
	r.blend    = .OPAQUE
	r.tint     = {1, 1, 1, 1}
}
