package psx

// Text, drawn with the engine's 8x8 bitmap font (gfx.debug_text). Queued by
// render_text during the frame and drawn by the render steps: FRAME text into
// the low-res frame (it gets the post effects and lands on its pixels), SCREEN
// text on top at the window's resolution.

import "base:runtime"
import "core:strings"
import gfx "moonhug:libs/gfx"

// Queues `text` for this frame's render. `position` is in pixels of the space
// it is drawn in, top-left origin, and `size` is the glyph height in pixels.
// The strings live for the frame.
render_text :: proc(text: string, position: [2]f32, size: f32 = 10, color: [4]u8 = {255, 255, 255, 255}, space: Text_Space = .FRAME) {
	context.allocator = runtime.default_allocator()
	append(&state.texts, Queued_Text{
		text     = strings.clone(text, context.temp_allocator),
		position = position,
		size     = size,
		color    = {f32(color.r), f32(color.g), f32(color.b), f32(color.a)} / 255,
		space    = space,
	})
}

// How big `text` draws at glyph height `size`, in pixels.
measure_text :: proc(text: string, size: f32 = 10) -> [2]f32 {
	lines := f32(1)
	for r in text do if r == '\n' do lines += 1
	return {gfx.debug_text_width(size, text), lines * size + (lines - 1) * size * 0.25}
}

// Draws the queued text of one space inside the current pass. The caller has
// set a pixel-space view (gfx.matrix4_ortho_pixels) and a depth that lets it
// show: a pass of its own on the target.
draw_queued_text :: proc(space: Text_Space) {
	for queued in state.texts {
		if queued.space == space do gfx.debug_text(queued.position, queued.size, queued.color, queued.text)
	}
}

has_queued_text :: proc(space: Text_Space) -> bool {
	for queued in state.texts do if queued.space == space do return true
	return false
}

// Called when the frame has drawn them all.
clear_queued_text :: proc() {
	clear(&state.texts)
}
