package mygame

import "core:math"
import "core:math/linalg"

import "moonhug:libs/input"
import "moonhug:packages/engine"


// A free camera: click the game to capture the mouse and look around, WASD to
// fly, E / Q up and down, Shift to go faster, Escape to give the mouse back.
@(component={menu="MyGame/FlyCamera"})
@(typ_guid={guid = "d3435457-4f2f-4317-b35d-51bb77253f7b"})
FlyCamera :: struct {
	using base: engine.CompData `inspect:"-"`,
	speed:      f32,
	fast_mult:  f32,
	look_speed: f32, // degrees per mouse count
	yaw:        f32 `json:"-" inspect:"-"`,
	pitch:      f32 `json:"-" inspect:"-"`,
	captured:   bool `json:"-" inspect:"-"`,
}

reset_FlyCamera :: proc(c: ^FlyCamera) {
	c.speed = 5
	c.fast_mult = 3
	c.look_speed = 0.15
	c.yaw, c.pitch, c.captured = 0, 0, false
}

// Runs on destroy, removal and Reset: never leave the mouse captured.
cleanup_FlyCamera :: proc(c: ^FlyCamera) {
	if c.captured do input.set_mouse_relative(false)
	c.captured = false
}


@(update)
fly_camera_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(fly_cameras(w))
	for c, _ in engine.pool_next(&it) {
		if !c.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(c.owner))
		if t == nil do continue

		if input.mouse_pressed(.Left) && !c.captured { c.captured = true;  input.set_mouse_relative(true) }
		if input.key_pressed(.ESCAPE) &&  c.captured { c.captured = false; input.set_mouse_relative(false) }

		if c.captured {
			d := input.mouse_delta()
			c.yaw -= d.x * c.look_speed
			c.pitch = clamp(c.pitch - d.y * c.look_speed, -89, 89)
		}
		yaw := linalg.quaternion_angle_axis_f32(math.to_radians(c.yaw), {0, 1, 0})
		pitch := linalg.quaternion_angle_axis_f32(math.to_radians(c.pitch), {1, 0, 0})
		t.rotation = engine.quat_from_native(yaw * pitch)

		// Move along the flat forward and right of the yaw, so looking up or down
		// does not change how fast you walk.
		a := math.to_radians(c.yaw)
		forward := [3]f32{-math.sin(a), 0, -math.cos(a)}
		right := [3]f32{math.cos(a), 0, -math.sin(a)}

		move: [3]f32
		if input.key_down(.W) do move += forward
		if input.key_down(.S) do move -= forward
		if input.key_down(.D) do move += right
		if input.key_down(.A) do move -= right
		if input.key_down(.E) do move.y += 1
		if input.key_down(.Q) do move.y -= 1

		if move != {} do move = linalg.normalize(move)
		speed := c.speed
		if input.key_down(.LSHIFT) do speed *= c.fast_mult
		t.position += move * speed * dt
	}
}
