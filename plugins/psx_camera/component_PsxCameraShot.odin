package psx_camera

import "moonhug:packages/engine"

// How a shot looks at the world while the player is in its zone.
Shot_Kind :: enum u8 {
	// A CCTV camera: it looks where its object points and never turns.
	STATIC,
	// Stays where it is but turns to follow the player.
	TRACK,
}

// One fixed camera angle: the object it sits on is the lens (its position,
// forward -Z and up +Y), and the player being inside `bounds` makes it the
// active shot of the PsxCameraRig.
//
// The Stargate editor built a shot from a group of three entities, a lens, a
// zone and a marker; here the zone is two numbers on the lens, in world space,
// and the marker is `kind`.
@(component={menu="PSX/PsxCameraShot"})
@(typ_guid={guid = "17bbeb0d-554f-41f3-adca-3023712c9ad6"})
PsxCameraShot :: struct {
	using base: engine.CompData `inspect:"-"`,
	kind:            Shot_Kind,
	// Vertical field of view in degrees.
	fov:             f32 `decor:range(1, 179)`,
	bounds_min:      [3]f32,
	bounds_max:      [3]f32,
	// TRACK only: added to the player's position, e.g. {0, 1, 0} to look at
	// the middle of the body instead of the feet.
	target_offset:   [3]f32,
	// TRACK only: how fast the look-at catches up, per second. 0 snaps every
	// frame. Cutting to a new shot always snaps.
	track_smoothing: f32 `decor:min(0)`,
}

reset_PsxCameraShot :: proc(s: ^PsxCameraShot) {
	s.kind = .STATIC
	s.fov = 70
	s.bounds_min = {-0.5, -0.5, -0.5}
	s.bounds_max = {0.5, 0.5, 0.5}
	s.target_offset = {0, 1, 0}
	s.track_smoothing = 8
}

// Whether `point` is inside the shot's bounds (inclusive).
shot_contains :: proc(shot: ^PsxCameraShot, point: [3]f32) -> bool {
	return point.x >= shot.bounds_min.x && point.x <= shot.bounds_max.x &&
	       point.y >= shot.bounds_min.y && point.y <= shot.bounds_max.y &&
	       point.z >= shot.bounds_min.z && point.z <= shot.bounds_max.z
}

// How many enabled shots `scene` holds (any loaded scene when nil): a level
// with none is followed by the drag camera instead.
count_shots :: proc(scene: ^engine.Scene = nil) -> (count: int) {
	w := engine.ctx_world()
	it := engine.pool_iterator(psx_camera_shots(w))
	for s, _ in engine.pool_next(&it) {
		if !s.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(s.owner))
		if t == nil || (scene != nil && t.scene != scene) do continue
		count += 1
	}
	return
}
