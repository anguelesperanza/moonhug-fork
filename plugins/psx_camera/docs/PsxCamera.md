---
title: "PSX Cameras"
description: "Fixed camera shots that cut as the player crosses their zones, and a drag camera that trails the player and stays in front of walls"
order: 21
tags: ["camera", "plugins", "psx"]
---

Two camera behaviours from survival-horror games, both moving the object that carries the engine's Camera.

## The rig

**PsxCameraRig** sits on the Camera's object. Call `psx_camera.camera_update(camera, target, delta)` once a frame with the object it follows (usually the player's feet): it moves the object's transform and sets the Camera's field of view. The rig has a mode:

- **FIXED** cuts between **PsxCameraShot**s. Each shot is an object whose position and -Z / +Y are the lens, with a zone (`bounds_min`, `bounds_max`, world space). The shot the target is in is active, and is sticky: it stays active while the target is inside it even if another shot overlaps. Give neighbouring shots a small overlap and it becomes hysteresis. A `STATIC` shot looks where its object points; a `TRACK` shot stays where it is and turns toward the target (`target_offset`, eased by `track_smoothing`, snapping on a cut).
- **DRAG** keeps a fixed yaw, pitch and distance around an anchor that is dragged after the target once it leaves a dead zone and eased to follow. `drag_camera_ray` gives the ray a game casts against its walls, and `set_drag_camera_limit` pulls the camera in to what it hit, instantly, easing it back out. `recenter_drag_camera` swings it round to a facing; `swing_speed` above 0 makes the yaw follow the way the target walks.
- **ORBITAL** circles the origin.

`rig.yaw` is the flat direction camera-relative controls treat as forward. For a fixed shot it comes from the shot's authored lens, not the live look-at, so a TRACK shot turning to follow the player does not turn the controls.

## Level changes

A new level has new shots: call `reset_shots(camera)` to forget the active one, and `count_shots(scene)` to decide between FIXED (the level has shots) and `use_drag_camera` (it has none).
