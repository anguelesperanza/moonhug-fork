package psx

// The angle helpers the camera and the character controls share.

import "core:math"
import "core:math/linalg"

// Signed angle from `a` to `b`, wrapped into (-pi, pi]: the short way round.
// Subtracting two yaws directly can give the long way round the compass.
angle_diff :: proc(a, b: f32) -> f32 {
	d := math.mod(b - a + math.PI, math.TAU)
	if d < 0 do d += math.TAU
	return d - math.PI
}

// Turns `angle` toward `target` the short way, at most `speed` radians a second.
turn_toward :: proc(angle: ^f32, target, speed, delta: f32) {
	diff := angle_diff(angle^, target)
	step := speed * delta
	if abs(diff) <= step {
		angle^ = target
		return
	}
	angle^ += math.sign(diff) * step
}

// Yaw (radians, atan2(z, x)) of the direction from `from` to `to` flattened
// onto the xz plane. ok is false when it is (nearly) straight up or down,
// where the yaw is undefined or too unstable to use.
flat_yaw :: proc(from, to: [3]f32) -> (yaw: f32, ok: bool) {
	d := to - from
	flat_sq := d.x * d.x + d.z * d.z
	if flat_sq < 1e-6 * linalg.length2(d) || flat_sq == 0 {
		return 0, false
	}
	return math.atan2(d.z, d.x), true
}
