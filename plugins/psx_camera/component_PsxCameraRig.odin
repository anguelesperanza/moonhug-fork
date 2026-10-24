package psx_camera

import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"
import "moonhug:packages/psx"

// What drives the camera.
Rig_Mode :: enum u8 {
	// Cuts between PsxCameraShots as the target crosses their zones.
	FIXED,
	// Circles the origin, slowly.
	ORBITAL,
	// Trails the target at a fixed yaw, pitch and distance around an anchor that
	// is dragged after it past a dead zone (Matchbox's drift camera).
	DRAG,
}

// The drag camera: an anchor the camera looks at, dragged after the target once
// it strays further than `dead_zone` and eased to follow, with the camera
// `distance` away at a `yaw` and `pitch`.
//
// A Silent Hill-style search view: with `swing_speed` above 0 the yaw swings to
// face the way the target walks; `recenter_speed` is how fast it returns to
// the way the character faces when asked to (recenter_drag_camera).
Camera_Drag :: struct {
	pitch:            f32,
	distance:         f32,
	dead_zone:        f32,
	follow_speed:     f32,
	swing_speed:      f32,
	recenter_speed:   f32,
	release_speed:    f32,
	focus_offset:     [3]f32,

	// What the camera works out as it goes.
	anchor:           [3]f32 `json:"-" inspect:"-"`,
	yaw:              f32 `json:"-" inspect:"-"`,
	recentering:      bool `json:"-" inspect:"-"`,
	recenter_yaw:     f32 `json:"-" inspect:"-"`,
	limit:            f32 `json:"-" inspect:"-"`, // 0 = none: the camera is pulled in to this
	current_distance: f32 `json:"-" inspect:"-"`,
}

DRAG_CAMERA_DEFAULTS :: Camera_Drag{
	pitch          = -0.3,
	distance       = 6,
	dead_zone      = 1.5,
	follow_speed   = 3,
	swing_speed    = 0,
	recenter_speed = 4,
	release_speed  = 3,
	focus_offset   = {0, 1.6, 0},
}

// Drives the object it sits on, which carries the engine's Camera: every frame
// camera_update sets that object's transform and the Camera's field of view
// from the rig. A Camera whose `slot` is "Psx" renders it through the PSX frame.
@(component={menu="PSX/PsxCameraRig"})
@(typ_guid={guid = "91da62d8-b2dd-4122-9e40-9394d01c033e"})
PsxCameraRig :: struct {
	using base: engine.CompData `inspect:"-"`,
	mode:  Rig_Mode,
	// What the camera shows while no shot has been entered, and in ORBITAL
	// and DRAG modes.
	fov:   f32 `decor:range(1, 179)`,
	drag:  Camera_Drag,

	// The shot the target is in (-1 = none yet): sticky, so it stays active as
	// long as the target is inside it even if another shot overlaps.
	index:    i32 `json:"-" inspect:"-"`,
	// The flat (xz) direction camera-relative controls treat as forward. For a
	// fixed shot it comes from the shot's authored lens, not the live look-at,
	// so a TRACK camera turning to follow the player does not turn the controls.
	yaw:      f32 `json:"-" inspect:"-"`,
	// The camera as the rig worked it out this frame.
	position: [3]f32 `json:"-" inspect:"-"`,
	target:   [3]f32 `json:"-" inspect:"-"`,
	up:       [3]f32 `json:"-" inspect:"-"`,
}

reset_PsxCameraRig :: proc(r: ^PsxCameraRig) {
	r.mode = .FIXED
	r.fov = 45
	r.drag = DRAG_CAMERA_DEFAULTS
	r.index = -1
	r.position = {0, 10, 10}
	r.target = {}
	r.up = {0, 1, 0}
	r.yaw, _ = psx.flat_yaw(r.position, r.target)
}

// The rig's PsxCameraRig on the camera object, nil without one.
rig_of :: proc(camera: engine.Transform_Handle) -> ^PsxCameraRig {
	_, rig := get_comp(camera, PsxCameraRig)
	return rig
}

// Updates the camera for its mode and writes it to the object's transform and
// the Camera's field of view. Call once a frame.
//   target  what the camera follows (usually the player): FIXED uses it to pick
//           the shot and for TRACK shots, ORBITAL ignores it
//   delta   frame time, for TRACK smoothing and the drag camera's easing
// Returns the active shot, or nil (not FIXED, or the target has never been
// inside one).
camera_update :: proc(camera: engine.Transform_Handle, target: [3]f32, delta: f32) -> ^PsxCameraShot {
	rig := rig_of(camera)
	if rig == nil do return nil

	active: ^PsxCameraShot
	switch rig.mode {
	case .FIXED:
		active = _update_fixed(rig, target, delta)
	case .ORBITAL:
		_update_orbital(rig, delta)
	case .DRAG:
		_update_drag(rig, target, delta)
	}

	// A look direction parallel to `up` makes the look-at degenerate (NaNs, the
	// view flips). For top-down views use the controls' forward as screen up,
	// so pushing forward moves the player up the screen.
	forward := rig.target - rig.position
	if linalg.length2(linalg.cross(forward, rig.up)) < 1e-6 * linalg.length2(forward) * linalg.length2(rig.up) {
		rig.up = {math.cos(rig.yaw), 0, math.sin(rig.yaw)}
	}

	_apply(rig, camera)
	return active
}

// Puts the rig's camera on the object: position and the rotation whose -Z is
// the look direction and +Y the up the shot asked for.
@(private = "file")
_apply :: proc(rig: ^PsxCameraRig, camera: engine.Transform_Handle) {
	forward := rig.target - rig.position
	if linalg.length2(forward) < 1e-12 do return
	f := linalg.normalize(forward)
	right := linalg.normalize0(linalg.cross(f, rig.up))
	if right == {} do return
	up := linalg.cross(right, f)

	basis := matrix[3, 3]f32{
		right.x, up.x, -f.x,
		right.y, up.y, -f.y,
		right.z, up.z, -f.z,
	}
	q := engine.quat_from_native(linalg.quaternion_from_matrix3_f32(basis))
	engine.transform_set_world_position(camera, rig.position)
	engine.transform_set_world_rotation(camera, q)

	if _, cam := engine.transform_get_comp(camera, engine.Camera); cam != nil {
		cam.fov = rig.fov
	}
}

// --- fixed shots -----------------------------------------------------------------

@(private = "file")
_update_fixed :: proc(rig: ^PsxCameraRig, target: [3]f32, delta: f32) -> ^PsxCameraShot {
	w := engine.ctx_world()
	shots := make([dynamic]^PsxCameraShot, context.temp_allocator)
	it := engine.pool_iterator(psx_camera_shots(w))
	for s, _ in engine.pool_next(&it) {
		if s.enabled && engine.transform_active_in_hierarchy(s.owner) do append(&shots, s)
	}

	active: ^PsxCameraShot
	previous := rig.index
	if rig.index >= 0 && int(rig.index) < len(shots) && shot_contains(shots[rig.index], target) {
		active = shots[rig.index]
	} else {
		for shot, i in shots {
			if shot_contains(shot, target) {
				active = shot
				rig.index = i32(i)
				break
			}
		}
	}
	if active == nil do return nil

	cut := rig.index != previous

	// The lens: the shot object's world position, forward (-Z) and up (+Y).
	tw := engine.transform_world(active.owner)
	rot := engine.quat_to_matrix3(tw.rotation)
	forward := linalg.normalize([3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]})
	rig.position = tw.position
	rig.up = linalg.normalize([3]f32{rot[0, 1], rot[1, 1], rot[2, 1]})
	rig.fov = active.fov
	rig.yaw = _shot_yaw(active, tw.position, tw.position + forward, rig.yaw)

	switch active.kind {
	case .STATIC:
		rig.target = tw.position + forward
	case .TRACK:
		desired := target + active.target_offset
		if cut || active.track_smoothing <= 0 {
			rig.target = desired
		} else {
			// Exponential ease: the same speed at any frame rate.
			t := 1 - math.exp(-active.track_smoothing * delta)
			rig.target = linalg.lerp(rig.target, desired, t)
		}
	}
	return active
}

// The controls' yaw for a fixed shot: toward its lens target, or, if that is
// straight down, toward the middle of its bounds. If both are vertical, keep
// `fallback`.
@(private = "file")
_shot_yaw :: proc(shot: ^PsxCameraShot, position, look_at: [3]f32, fallback: f32) -> f32 {
	if yaw, ok := psx.flat_yaw(position, look_at); ok do return yaw
	if yaw, ok := psx.flat_yaw(position, (shot.bounds_min + shot.bounds_max) * 0.5); ok do return yaw
	return fallback
}

// Forgets the active shot, so the next frame picks one by the target's place
// (a level changed, and the shots are other objects now).
reset_shots :: proc(camera: engine.Transform_Handle) {
	if rig := rig_of(camera); rig != nil do rig.index = -1
}

// --- orbital ---------------------------------------------------------------------

@(private = "file")
_update_orbital :: proc(rig: ^PsxCameraRig, delta: f32) {
	offset := rig.position - rig.target
	angle := 0.5 * delta
	c, s := math.cos(angle), math.sin(angle)
	rig.position = rig.target + {offset.x * c - offset.z * s, offset.y, offset.x * s + offset.z * c}
	rig.up = {0, 1, 0}
	if yaw, ok := psx.flat_yaw(rig.position, rig.target); ok do rig.yaw = yaw
}

// --- drag camera -------------------------------------------------------------------

// Sets the rig to the drag camera with the camera settled behind the target,
// facing `yaw`.
use_drag_camera :: proc(camera: engine.Transform_Handle, target: [3]f32, yaw: f32) {
	rig := rig_of(camera)
	if rig == nil do return
	rig.mode = .DRAG
	rig.drag = DRAG_CAMERA_DEFAULTS
	rig.drag.yaw = yaw
	snap_drag_camera(rig, target)
}

// Puts the camera where it would settle: anchored on the target, at full
// distance.
snap_drag_camera :: proc(rig: ^PsxCameraRig, target: [3]f32) {
	rig.drag.anchor = target
	rig.drag.recentering = false
	rig.drag.current_distance = _drag_target_distance(rig.drag)
	_seat_drag_camera(rig)
}

// The ray from the drag camera's focus back toward where the camera sits: what
// the game casts against its walls to keep the camera in front of them.
drag_camera_ray :: proc(rig: ^PsxCameraRig) -> (origin, translation: [3]f32) {
	origin = rig.drag.anchor + rig.drag.focus_offset
	translation = -_drag_forward(rig.drag) * rig.drag.distance
	return
}

// Pulls the camera in to `limit` (0 = no limit): at once when it is closer
// than it is now, eased back out when the way clears.
set_drag_camera_limit :: proc(rig: ^PsxCameraRig, limit: f32) {
	rig.drag.limit = limit
	target := _drag_target_distance(rig.drag)
	if target < rig.drag.current_distance {
		rig.drag.current_distance = target
		_seat_drag_camera(rig)
	}
}

// Swings the camera round to look the way `facing` points.
recenter_drag_camera :: proc(rig: ^PsxCameraRig, facing: f32) {
	rig.drag.recentering = true
	rig.drag.recenter_yaw = facing
}

@(private = "file")
_update_drag :: proc(rig: ^PsxCameraRig, target: [3]f32, delta: f32) {
	drag := &rig.drag

	goal := [3]f32{drag.anchor.x, target.y, drag.anchor.z}
	leash := max(drag.dead_zone, 0)
	away := [3]f32{target.x - drag.anchor.x, 0, target.z - drag.anchor.z}

	if reach := linalg.length(away); reach > leash && reach > 0 {
		direction := away / reach
		goal.x = target.x - direction.x * leash
		goal.z = target.z - direction.z * leash

		if drag.swing_speed > 0 && !drag.recentering {
			psx.turn_toward(&drag.yaw, math.atan2(direction.z, direction.x), drag.swing_speed, delta)
		}
	}

	if drag.follow_speed > 0 && delta > 0 {
		drag.anchor += (goal - drag.anchor) * (1 - math.exp(-drag.follow_speed * delta))
	}

	if drag.recentering {
		psx.turn_toward(&drag.yaw, drag.recenter_yaw, drag.recenter_speed, delta)
		if drag.yaw == drag.recenter_yaw do drag.recentering = false
	}

	want := _drag_target_distance(drag^)
	if want < drag.current_distance || drag.release_speed <= 0 || drag.current_distance <= 0 {
		drag.current_distance = want
	} else if delta > 0 {
		drag.current_distance += (want - drag.current_distance) * (1 - math.exp(-drag.release_speed * delta))
	}

	_seat_drag_camera(rig)
}

@(private = "file")
_drag_target_distance :: proc(drag: Camera_Drag) -> f32 {
	if drag.limit > 0 do return min(drag.distance, drag.limit)
	return drag.distance
}

@(private = "file")
_drag_forward :: proc(drag: Camera_Drag) -> [3]f32 {
	return {
		math.cos(drag.pitch) * math.cos(drag.yaw),
		math.sin(drag.pitch),
		math.cos(drag.pitch) * math.sin(drag.yaw),
	}
}

@(private = "file")
_seat_drag_camera :: proc(rig: ^PsxCameraRig) {
	drag := rig.drag
	focus := drag.anchor + drag.focus_offset
	rig.position = focus - _drag_forward(drag) * drag.current_distance
	rig.target   = focus
	rig.up       = {0, 1, 0}
	rig.yaw      = drag.yaw
}
