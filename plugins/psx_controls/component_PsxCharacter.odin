package psx_controls

import "core:math"
import "moonhug:libs/input"
import "moonhug:packages/engine"
import "moonhug:packages/psx"

// How the keys move the character.
Control_Scheme :: enum u8 {
	// Turn in place with left and right, walk forward and back along the
	// facing: Resident Evil.
	TANK,
	// Push toward the screen's up, down, left or right: the character runs that
	// way and turns to face it.
	CAMERA_RELATIVE,
}

// The character's controls: what the keys ask for, as a facing and a move
// direction. Reading them does not move anything: update_tank_controls and
// update_camera_relative_controls set `facing` and `move` (a direction, scaled
// by how hard the keys push), and the game turns that into a velocity or a
// step, as it likes. WASD and the arrow keys both work.
@(component={menu="PSX/PsxCharacter"})
@(typ_guid={guid = "d3b0b537-78a1-4168-a953-a22580550825"})
PsxCharacter :: struct {
	using base: engine.CompData `inspect:"-"`,
	scheme:          Control_Scheme,

	// TANK: radians a second at full turn, and how much slower reversing is.
	tank_turn_speed: f32 `decor:min(0)`,
	backward_speed:  f32 `decor:range(0, 1)`,
	// TANK: standing still while turning (otherwise walk and turn together).
	turn_in_place:   bool,

	// CAMERA_RELATIVE: how fast the body turns to face the way it runs.
	turn_speed:      f32 `decor:min(0)`,
	// CAMERA_RELATIVE: on a fresh press the camera's yaw and the direction
	// pushed are locked, so a camera cut does not turn the way the character
	// runs; the lock is renewed when the push swings more than this away.
	hold_basis:      bool,
	hold_tolerance:  f32 `decor:range(0, 3.1416)`,

	// The result.
	facing:          f32 `json:"-" inspect:"-"`, // radians, atan2(z, x)
	move:            [3]f32 `json:"-" inspect:"-"`,

	basis_yaw:       f32 `json:"-" inspect:"-"`,
	basis_input:     [2]f32 `json:"-" inspect:"-"`,
	basis_held:      bool `json:"-" inspect:"-"`,
}

Movement_Defaults :: struct {
	tank_turn_speed: f32,
	backward_speed:  f32,
	hold_tolerance:  f32,
}

MOVEMENT_DEFAULTS :: Movement_Defaults{
	tank_turn_speed = 3,
	backward_speed  = 0.6,
	hold_tolerance  = math.PI / 3,
}

reset_PsxCharacter :: proc(c: ^PsxCharacter) {
	c.scheme          = .TANK
	c.tank_turn_speed = MOVEMENT_DEFAULTS.tank_turn_speed
	c.backward_speed  = MOVEMENT_DEFAULTS.backward_speed
	c.turn_in_place   = true
	c.turn_speed      = MOVEMENT_DEFAULTS.tank_turn_speed
	c.hold_basis      = true
	c.hold_tolerance  = MOVEMENT_DEFAULTS.hold_tolerance
	c.facing = 0
	c.move = {}
}

// Where the controls read keys from: the keyboard, unless a game points this at
// something else (a recorded demo, a test's script, an AI). Return whether the
// key is held.
key_source: proc(key: input.Key) -> bool

@(private = "file")
_held :: proc(key: input.Key) -> bool {
	return key_source != nil ? key_source(key) : input.key_down(key)
}

@(private = "file")
_left  :: proc() -> bool { return _held(.A) || _held(.LEFT) }
@(private = "file")
_right :: proc() -> bool { return _held(.D) || _held(.RIGHT) }
@(private = "file")
_up    :: proc() -> bool { return _held(.W) || _held(.UP) }
@(private = "file")
_down  :: proc() -> bool { return _held(.S) || _held(.DOWN) }

// Reads the keys and updates `facing` and `move` for the TANK scheme. Left and
// right turn `facing` directly; up and down move along whatever `facing` is,
// with back scaled by `backward_speed`, so reversing is slower than walking.
update_tank_controls :: proc(c: ^PsxCharacter, delta: f32) {
	turn, move_axis: f32
	if _left()  do turn -= 1
	if _right() do turn += 1
	if _up()    do move_axis += 1
	if _down()  do move_axis -= 1

	c.facing += turn * c.tank_turn_speed * delta

	if c.turn_in_place && turn != 0 do move_axis = 0

	scale := move_axis >= 0 ? f32(1) : c.backward_speed
	c.move = {math.cos(c.facing), 0, math.sin(c.facing)} * move_axis * scale
}

// Reads the keys and updates `facing` and `move` for the CAMERA_RELATIVE
// scheme, against `camera_yaw`: the flat direction the camera looks (the rig's
// `yaw`). A fixed camera's yaw is the shot's authored one, not the live
// look-at, so a TRACK shot turning to follow the player does not turn the
// controls.
update_camera_relative_controls :: proc(c: ^PsxCharacter, camera_yaw: f32, delta: f32) {
	input_axis: [2]f32 // x = strafe, y = forward, both camera-relative
	if _left()  do input_axis.x -= 1
	if _right() do input_axis.x += 1
	if _up()    do input_axis.y += 1
	if _down()  do input_axis.y -= 1

	held := input_axis != {0, 0}

	// Held basis: on a fresh press, lock the camera's yaw and the direction
	// being pushed. The lock survives camera cuts. It re-locks to the current
	// camera once the push swings more than `hold_tolerance` away from the
	// locked direction (W -> A or W -> S), but not for small corrections.
	if c.hold_basis {
		if held {
			relock := !c.basis_held
			if !relock {
				locked_angle := math.atan2(c.basis_input.y, c.basis_input.x)
				input_angle  := math.atan2(input_axis.y, input_axis.x)
				relock = abs(psx.angle_diff(locked_angle, input_angle)) > c.hold_tolerance
			}
			if relock {
				c.basis_yaw   = camera_yaw
				c.basis_input = input_axis
			}
		}
		c.basis_held = held
	} else {
		c.basis_yaw  = camera_yaw // no locking: always the camera's current yaw
		c.basis_held = false
	}

	basis := c.basis_yaw
	forward := [3]f32{math.cos(basis), 0, math.sin(basis)}
	right   := [3]f32{-math.sin(basis), 0, math.cos(basis)}

	move_dir := forward * input_axis.y + right * input_axis.x
	if move_dir != {0, 0, 0} {
		length := math.sqrt(move_dir.x * move_dir.x + move_dir.z * move_dir.z)
		move_dir /= length
	}
	c.move = move_dir

	if move_dir != {0, 0, 0} {
		target_facing := math.atan2(move_dir.z, move_dir.x)
		psx.turn_toward(&c.facing, target_facing, c.turn_speed, delta)
	}
}
