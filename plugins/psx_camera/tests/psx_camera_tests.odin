package psx_camera_tests

// The cameras' logic that needs no world: shot zones and the drag camera's
// anchor, distance and wall limit.

import "core:math"
import "core:testing"
import psx_camera ".."

@(private = "file")
_near :: proc(a, b: f32, eps: f32 = 1e-3) -> bool {
	return abs(a - b) <= eps
}

@(test)
psx_camera_shot_zone :: proc(t: ^testing.T) {
	shot := psx_camera.PsxCameraShot{bounds_min = {-1, 0, -2}, bounds_max = {1, 3, 2}}
	testing.expect(t, psx_camera.shot_contains(&shot, {0, 1, 0}), "inside")
	testing.expect(t, psx_camera.shot_contains(&shot, {1, 3, 2}), "the bounds are inclusive")
	testing.expect(t, !psx_camera.shot_contains(&shot, {1.01, 1, 0}), "outside in x")
	testing.expect(t, !psx_camera.shot_contains(&shot, {0, -0.1, 0}), "outside in y")
	testing.expect(t, !psx_camera.shot_contains(&shot, {0, 1, 2.5}), "outside in z")
}

@(test)
psx_camera_drag_settles_behind_the_target :: proc(t: ^testing.T) {
	rig: psx_camera.PsxCameraRig
	psx_camera.reset_PsxCameraRig(&rig)
	rig.mode = .DRAG
	rig.drag.yaw = 0 // looks along +X

	psx_camera.snap_drag_camera(&rig, {5, 0, 5})
	// The camera sits `distance` away at the pitch, behind the focus.
	focus := [3]f32{5, 0, 5} + rig.drag.focus_offset
	testing.expect_value(t, rig.target, focus)
	back := rig.target - rig.position
	length := math.sqrt(back.x * back.x + back.y * back.y + back.z * back.z)
	testing.expect(t, _near(length, rig.drag.distance), "at the drag distance")
	testing.expect(t, rig.position.x < focus.x, "behind a camera that looks along +X")
	testing.expect(t, rig.position.y > focus.y, "above it: the pitch looks down")
}

@(test)
psx_camera_drag_ray_and_limit :: proc(t: ^testing.T) {
	rig: psx_camera.PsxCameraRig
	psx_camera.reset_PsxCameraRig(&rig)
	psx_camera.snap_drag_camera(&rig, {})

	origin, translation := psx_camera.drag_camera_ray(&rig)
	testing.expect_value(t, origin, rig.drag.focus_offset)
	// The ray runs from the focus to where the camera is, `distance` long.
	reach := math.sqrt(translation.x * translation.x + translation.y * translation.y + translation.z * translation.z)
	testing.expect(t, _near(reach, rig.drag.distance), "the ray is the drag distance long")

	// A wall 2 m behind pulls the camera in at once, and it stays pulled in.
	psx_camera.set_drag_camera_limit(&rig, 2)
	testing.expect_value(t, rig.drag.current_distance, f32(2))
	d := rig.target - rig.position
	testing.expect(t, _near(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z), 2), "seated at the limit")
	// Lifting the limit does not snap it back out: the drag camera eases.
	psx_camera.set_drag_camera_limit(&rig, 0)
	testing.expect_value(t, rig.drag.current_distance, f32(2))
}
