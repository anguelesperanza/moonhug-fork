package psx_controls_tests

// The character controls, driven by a key source instead of a keyboard.

import "core:math"
import "core:testing"
import "moonhug:libs/input"
import psx_controls ".."

@(private = "file")
_held: bit_set[enum {W, A, S, D}]

@(private = "file")
_source :: proc(key: input.Key) -> bool {
	#partial switch key {
	case .W: return .W in _held
	case .A: return .A in _held
	case .S: return .S in _held
	case .D: return .D in _held
	}
	return false
}

@(private = "file")
_begin :: proc() -> psx_controls.PsxCharacter {
	psx_controls.key_source = _source
	_held = {}
	c: psx_controls.PsxCharacter
	psx_controls.reset_PsxCharacter(&c)
	return c
}

@(private = "file")
_end :: proc() {
	psx_controls.key_source = nil
}

@(test)
psx_controls_tank_walks_along_the_facing :: proc(t: ^testing.T) {
	c := _begin()
	defer _end()
	c.facing = math.PI / 2 // along +Z

	_held = {.W}
	psx_controls.update_tank_controls(&c, 1.0 / 60)
	testing.expect(t, abs(c.move.x) < 1e-5 && abs(c.move.z - 1) < 1e-5, "forward is along the facing")

	// Reversing is slower than walking.
	_held = {.S}
	psx_controls.update_tank_controls(&c, 1.0 / 60)
	testing.expect(t, abs(c.move.z + c.backward_speed) < 1e-5, "backward at backward_speed")

	_held = {}
	psx_controls.update_tank_controls(&c, 1.0 / 60)
	testing.expect_value(t, c.move, [3]f32{0, 0, 0})
}

@(test)
psx_controls_tank_turns :: proc(t: ^testing.T) {
	c := _begin()
	defer _end()
	start := c.facing

	// Left turns one way, right the other, at tank_turn_speed.
	_held = {.D}
	psx_controls.update_tank_controls(&c, 0.5)
	testing.expect(t, abs(c.facing - (start + c.tank_turn_speed * 0.5)) < 1e-5, "right turns up the angle")
	_held = {.A}
	psx_controls.update_tank_controls(&c, 0.5)
	testing.expect(t, abs(c.facing - start) < 1e-5, "left undoes it")

	// Turning in place walks nowhere, even with forward held.
	_held = {.D, .W}
	psx_controls.update_tank_controls(&c, 0.1)
	testing.expect_value(t, c.move, [3]f32{0, 0, 0})
	// With it off, the character walks and turns together.
	c.turn_in_place = false
	psx_controls.update_tank_controls(&c, 0.1)
	testing.expect(t, c.move != [3]f32{0, 0, 0}, "walks while turning")
}

@(test)
psx_controls_camera_relative_follows_the_camera :: proc(t: ^testing.T) {
	c := _begin()
	defer _end()
	c.scheme = .CAMERA_RELATIVE

	// A camera looking along +X: forward runs +X, and the body turns to face it.
	_held = {.W}
	psx_controls.update_camera_relative_controls(&c, 0, 1.0 / 60)
	testing.expect(t, abs(c.move.x - 1) < 1e-5 && abs(c.move.z) < 1e-5, "forward is the camera's forward")

	// Right is a quarter turn clockwise from forward (+Z for a camera along +X).
	_held = {.D}
	c.basis_held = false
	psx_controls.update_camera_relative_controls(&c, 0, 1.0 / 60)
	testing.expect(t, abs(c.move.x) < 1e-5 && abs(c.move.z - 1) < 1e-5, "right is the camera's right")
}

@(test)
psx_controls_held_basis_survives_a_camera_cut :: proc(t: ^testing.T) {
	c := _begin()
	defer _end()
	c.scheme = .CAMERA_RELATIVE

	_held = {.W}
	psx_controls.update_camera_relative_controls(&c, 0, 1.0 / 60)
	before := c.move
	// The camera cuts to a view turned a quarter round: a key still held keeps
	// running the way it was.
	psx_controls.update_camera_relative_controls(&c, math.PI / 2, 1.0 / 60)
	testing.expect_value(t, c.move, before)

	// With the lock off the new camera's forward applies at once.
	c.hold_basis = false
	psx_controls.update_camera_relative_controls(&c, math.PI / 2, 1.0 / 60)
	testing.expect(t, abs(c.move.z - 1) < 1e-5, "no lock: the new camera's forward")
}
