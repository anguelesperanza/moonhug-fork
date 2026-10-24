---
title: "PSX Controls"
description: "Tank controls and camera-relative controls with a held basis across camera cuts"
order: 22
tags: ["input", "plugins", "psx"]
---

**PsxCharacter** holds the controls' settings and result. `update_tank_controls` and `update_camera_relative_controls` read the keys (WASD and the arrows) and set `facing` (radians, `atan2(z, x)`) and `move` (a direction scaled by how hard the keys push). Nothing here moves anything: the game turns `move` into a velocity or a step.

- **TANK**: left and right turn `facing` at `tank_turn_speed`; up and down walk along it, reversing at `backward_speed` of the speed. With `turn_in_place` the character stands still while turning, as in Resident Evil; without it, it walks and turns together.
- **CAMERA_RELATIVE**: the keys are directions on the screen. `hold_basis` locks the camera's yaw and the push on a fresh press, so a camera cut does not change the way the character runs; the lock is renewed when the push swings more than `hold_tolerance` away from the locked one (W then A), not for small corrections (W then W+A). The body turns to face its movement at `turn_speed`.

`psx_controls.key_source` replaces the keyboard: point it at a procedure answering "is this key held" to drive the controls from a recorded demo, a test or an AI. The demo's `--demo-script` option uses it.
