package mygame

import "core:math"
import "core:math/linalg"

import "moonhug:libs/input"
import "moonhug:packages/engine"


// A first-person walker. Put it on the Camera object (use it instead of
// FlyCamera, not with it). Click the game to capture the mouse, WASD to walk,
// Shift to run, Space to jump, Escape to give the mouse back.
//
// It does not use physics: the eyes stand `eye_height` above a flat ground at
// height `ground_y`, and gravity and the jump act against that. Walls and
// floors that are not at `ground_y` are not collided with.
@(component={menu="MyGame/FirstPersonController"})
@(typ_guid={guid = "6b0f6c52-8f0e-4b5e-9a5d-3d1f4c0e7a21"})
FirstPersonController :: struct {
	using base: engine.CompData `inspect:"-"`,
	walk_speed:   f32,
	run_mult:     f32,
	look_speed:   f32, // degrees per mouse count
	jump_speed:   f32,
	gravity:      f32,
	eye_height:   f32,
	ground_y:     f32,

	yaw:          f32 `json:"-" inspect:"-"`,
	pitch:        f32 `json:"-" inspect:"-"`,
	vel_y:        f32 `json:"-" inspect:"-"`,
	captured:     bool `json:"-" inspect:"-"`,
	flashlight_on:bool, 
}

reset_FirstPersonController :: proc(c: ^FirstPersonController) {
	c.walk_speed = 4
	c.run_mult = 1.8
	c.look_speed = 0.15
	c.jump_speed = 5
	c.gravity = 15
	c.eye_height = 1.7
	c.ground_y = 0
	c.yaw, c.pitch, c.vel_y, c.captured = 0, 0, 0, false
	c.flashlight_on = true
}

cleanup_FirstPersonController :: proc(c: ^FirstPersonController) {
	if c.captured do input.set_mouse_relative(false)
	c.captured = false
}


@(update)
first_person_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(first_person_controllers(w))
	for c, _ in engine.pool_next(&it) {
		if !c.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(c.owner))
		if t == nil do continue

		if input.mouse_pressed(.Left) && !c.captured { c.captured = true;  input.set_mouse_relative(true) }
		if input.key_pressed(.ESCAPE) &&  c.captured { c.captured = false; input.set_mouse_relative(false) }

		// Look.
		if c.captured {
			d := input.mouse_delta()
			c.yaw -= d.x * c.look_speed
			c.pitch = clamp(c.pitch - d.y * c.look_speed, -89, 89)
		}
		yaw := linalg.quaternion_angle_axis_f32(math.to_radians(c.yaw), {0, 1, 0})
		pitch := linalg.quaternion_angle_axis_f32(math.to_radians(c.pitch), {1, 0, 0})
		t.rotation = engine.quat_from_native(yaw * pitch)

		// Walk on the ground plane.
		a := math.to_radians(c.yaw)
		forward := [3]f32{-math.sin(a), 0, -math.cos(a)}
		right := [3]f32{math.cos(a), 0, -math.sin(a)}

		move: [3]f32
		if input.key_down(.W) do move += forward
		if input.key_down(.S) do move -= forward
		if input.key_down(.D) do move += right
		if input.key_down(.A) do move -= right
		if move != {} do move = linalg.normalize(move)

		speed := c.walk_speed
		if input.key_down(.LSHIFT) do speed *= c.run_mult
		t.position += move * speed * dt

		// Jump and fall.
		floor_y := c.ground_y + c.eye_height
		grounded := t.position.y <= floor_y + 0.001
		if grounded && c.vel_y <= 0 {
			c.vel_y = 0
			t.position.y = floor_y
			if input.key_pressed(.SPACE) do c.vel_y = c.jump_speed
		}
		c.vel_y -= c.gravity * dt
		t.position.y += c.vel_y * dt
		if t.position.y < floor_y {
			t.position.y = floor_y
			c.vel_y = 0
		}

		if input.key_pressed(.F) {

			c.flashlight_on = !c.flashlight_on
			lit := engine.pool_iterator(engine.lights(w))
			for l, _ in engine.pool_next(&lit) {
				if l.owner == c.owner do l.enabled = c.flashlight_on
			}
		}
	}
}
