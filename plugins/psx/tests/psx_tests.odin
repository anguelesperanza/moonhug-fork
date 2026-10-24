package psx_tests

// The PSX renderer's logic that needs no GPU: lighting, the frame's geometry,
// the tile grid's turns, the angle helpers.

import "core:math"
import "core:testing"
import psx ".."

@(private = "file")
_near :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return abs(a - b) <= eps
}

@(test)
psx_directional_light :: proc(t: ^testing.T) {
	// Shines along -Y (straight down): a floor facing up gets all of it, a wall none.
	light := psx.Light{kind = .DIRECTIONAL, direction = {0, -1, 0}, color = {1, 0.5, 0.25}}
	up := psx.light_contribution(light, {0, 0, 0}, {0, 1, 0})
	testing.expect_value(t, up, [3]f32{1, 0.5, 0.25})
	wall := psx.light_contribution(light, {0, 0, 0}, {1, 0, 0})
	testing.expect_value(t, wall, [3]f32{0, 0, 0})
	down := psx.light_contribution(light, {0, 0, 0}, {0, -1, 0})
	testing.expect_value(t, down, [3]f32{0, 0, 0}) // facing away: never negative
}

@(test)
psx_point_light_falloff :: proc(t: ^testing.T) {
	light := psx.Light{kind = .POINT, position = {0, 2, 0}, color = {1, 1, 1}, range = 4}
	// 1 m under it, facing it: falloff 1 - 1/4.
	near := psx.light_contribution(light, {0, 1, 0}, {0, 1, 0})
	testing.expect(t, _near(near.r, 0.75), "falloff at 1 m of 4")
	// Past its range it lights nothing.
	far := psx.light_contribution(light, {0, -3, 0}, {0, 1, 0})
	testing.expect_value(t, far, [3]f32{0, 0, 0})
}

@(test)
psx_spot_light_cone :: proc(t: ^testing.T) {
	light := psx.Light{kind = .SPOT, position = {0, 2, 0}, direction = {0, -1, 0}, color = {1, 1, 1}, range = 10, inner_angle = 10, outer_angle = 30}
	inside := psx.light_contribution(light, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, inside.r > 0.5, "straight below it is inside the cone")
	// 60 degrees off the axis: outside the 30 degree cone.
	outside := psx.light_contribution(light, {2 * math.sqrt(f32(3)), 0, 0}, {0, 1, 0})
	testing.expect_value(t, outside, [3]f32{0, 0, 0})
}

@(test)
psx_area_light_faces_one_way :: proc(t: ^testing.T) {
	// An area light is a one-sided point light: it lights what is in front.
	light := psx.Light{kind = .AREA_RECT, position = {0, 2, 0}, direction = {0, -1, 0}, color = {1, 1, 1}, range = 10}
	front := psx.light_contribution(light, {0, 0, 0}, {0, 1, 0})
	behind := psx.light_contribution(light, {0, 4, 0}, {0, -1, 0})
	testing.expect(t, front.r > 0, "in front")
	testing.expect_value(t, behind, [3]f32{0, 0, 0})
}

@(test)
psx_live_lights_pick_the_strongest :: proc(t: ^testing.T) {
	lights := []psx.Light{
		{kind = .DIRECTIONAL, direction = {0, -1, 0}, color = {0.1, 0.1, 0.1}},
		{kind = .DIRECTIONAL, direction = {0, -1, 0}, color = {0.2, 0.2, 0.2}},
		{kind = .DIRECTIONAL, direction = {0, -1, 0}, color = {0.3, 0.3, 0.3}},
		{kind = .DIRECTIONAL, direction = {0, -1, 0}, color = {0.9, 0.9, 0.9}},
	}
	live := psx.live_lights_at(lights, {})
	// Three slots: the weakest of four is the one left out.
	total := live.colors[0].r + live.colors[1].r + live.colors[2].r
	testing.expect(t, _near(total, 0.2 + 0.3 + 0.9), "the 0.1 light is dropped")
	for dir in live.directions do testing.expect_value(t, dir, [3]f32{0, 1, 0}) // toward the light
}

@(test)
psx_frame_size :: proc(t: ^testing.T) {
	v := psx.view_defaults()
	testing.expect_value(t, psx.frame_size(v, {1920, 1080}), [2]i32{256, 240})

	v.video_mode = .PAL_I
	v.resolution = .RES_FIVE
	testing.expect_value(t, psx.frame_size(v, {1920, 1080}), [2]i32{640, 512})

	// WIDESCREEN adds columns until the frame is the surface's shape: 256 at
	// 4:3 becomes 256 * (16/9) / (4/3) = 341.
	v = psx.view_defaults()
	v.display_aspect = .WIDESCREEN
	testing.expect_value(t, psx.frame_size(v, {1920, 1080}), [2]i32{341, 240})
	// A surface that is already 4:3 needs none.
	testing.expect_value(t, psx.frame_size(v, {1024, 768}), [2]i32{256, 240})

	// NONE renders at the surface's size.
	v = psx.view_defaults()
	v.resolution = .NONE
	v.video_mode = .NONE
	testing.expect_value(t, psx.frame_size(v, {800, 600}), [2]i32{800, 600})
}

@(test)
psx_display_rect :: proc(t: ^testing.T) {
	// 4:3 bars: the largest 4:3 rectangle, centred.
	r := psx.display_rect(.FOUR_THREE, {1920, 1080})
	testing.expect(t, _near(r.z, 1440) && _near(r.w, 1080), "pillarboxed to 1440 x 1080")
	testing.expect(t, _near(r.x, 240) && _near(r.y, 0), "centred")
	// A tall window gets bars above and below instead.
	r = psx.display_rect(.FOUR_THREE, {800, 800})
	testing.expect(t, _near(r.z, 800) && _near(r.w, 600) && _near(r.y, 100), "letterboxed")
	// The other two fill the surface.
	testing.expect_value(t, psx.display_rect(.STRETCH, {1920, 1080}), [4]f32{0, 0, 1920, 1080})
	testing.expect_value(t, psx.display_rect(.WIDESCREEN, {1920, 1080}), [4]f32{0, 0, 1920, 1080})
}

@(test)
psx_tile_turns :: proc(t: ^testing.T) {
	g := psx.PsxTileGrid{columns = 3, rows = 2}
	defer delete(g.turns)
	// No turns, no randomness: every cell as the mesh is.
	testing.expect_value(t, psx.tile_quarter_turns(&g, 1, 1), u32(0))

	// Random turns repeat for the same cell and seed, differ with the seed.
	g.random_rotation = true
	seen: [4]bool
	for row in i32(0) ..< 40 {
		for column in i32(0) ..< 40 {
			turns := psx.tile_quarter_turns(&g, column, row)
			testing.expect(t, turns < 4, "a quarter turn is 0 to 3")
			testing.expect_value(t, psx.tile_quarter_turns(&g, column, row), turns)
			seen[turns] = true
		}
	}
	testing.expect(t, seen[0] && seen[1] && seen[2] && seen[3], "all four turns occur")

	// Explicit turns win, row by row.
	for turn in ([]u8{0, 1, 2, 3, 6, 5}) do append(&g.turns, turn)
	testing.expect_value(t, psx.tile_quarter_turns(&g, 2, 0), u32(2))
	testing.expect_value(t, psx.tile_quarter_turns(&g, 0, 1), u32(3))
	testing.expect_value(t, psx.tile_quarter_turns(&g, 1, 1), u32(2)) // 6 wraps
}

@(test)
psx_angles :: proc(t: ^testing.T) {
	// The short way round the compass.
	testing.expect(t, _near(psx.angle_diff(0.1, 0.3), 0.2), "plain")
	testing.expect(t, _near(psx.angle_diff(math.PI - 0.1, -math.PI + 0.1), 0.2), "across the seam")
	testing.expect(t, _near(psx.angle_diff(-math.PI + 0.1, math.PI - 0.1), -0.2), "and back")

	// turn_toward steps at most speed * delta, and lands exactly.
	angle := f32(0)
	psx.turn_toward(&angle, 1, 2, 0.1)
	testing.expect(t, _near(angle, 0.2), "a step")
	psx.turn_toward(&angle, 0.25, 2, 0.1)
	testing.expect_value(t, angle, f32(0.25))

	// A flat yaw of straight up is undefined.
	_, ok := psx.flat_yaw({0, 0, 0}, {0, 5, 0})
	testing.expect(t, !ok, "vertical has no yaw")
	yaw, flat_ok := psx.flat_yaw({0, 0, 0}, {0, 3, 2})
	testing.expect(t, flat_ok && _near(yaw, math.atan2(f32(2), f32(0))), "atan2(z, x)")
}

@(test)
psx_post_effects_default_is_off :: proc(t: ^testing.T) {
	testing.expect_value(t, psx.get_post_effects(), psx.Post_Effects{})
	psx.set_post_effects(psx.POST_EFFECTS_CRT)
	testing.expect(t, psx.get_post_effects() != {}, "the CRT preset is a pass")
	psx.set_post_effects({})
}

@(test)
psx_toggles_change_the_view :: proc(t: ^testing.T) {
	// With no scene the setters work on the package's default view.
	psx.set_vertex_snapping(false)
	testing.expect(t, !psx.is_vertex_snapping(), "snapping off")
	psx.set_vertex_snapping(true)
	psx.set_fog(11, 17, {30, 50, 70, 255})
	view := psx.view_defaults()
	_ = view
	psx.set_draw_distance(-5)
	testing.expect_value(t, psx.get_draw_distance(), f32(0)) // never negative
	psx.set_color_depth(.BITS_24)
	testing.expect_value(t, psx.get_color_depth(), psx.Color_Depth.BITS_24)
	psx.set_color_depth(.BITS_15)
}
