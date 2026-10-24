package psx_demo

import "moonhug:packages/engine"

// The demo's player: the object the Rigidbody, the capsule collider and the
// PsxCharacter sit on, with the visible model as its first child. The capsule
// is upright and never rotates, the body does not move vertically (the floor's
// height is set when the level is entered), and the PsxCharacter's `move`
// becomes its velocity every frame, so a wall stops the player.
//
// The transform is the body's centre, 0.95 m above the floor, so the player's
// feet are `PLAYER_BODY_OFFSET` below it.
@(component={max=1, menu="PSX Demo/PsxDemoPlayer"})
@(typ_guid={guid = "220db10a-b355-4524-9c59-9b310c2bf5ff"})
PsxDemoPlayer :: struct {
	using base: engine.CompData `inspect:"-"`,
	// Metres a second at full push.
	move_speed: f32 `decor:min(0)`,
}

reset_PsxDemoPlayer :: proc(p: ^PsxDemoPlayer) {
	p.move_speed = 3
}

PLAYER_RADIUS      :: f32(0.35)
PLAYER_HALF_HEIGHT :: f32(0.5)
// From the feet to the body's centre: the capsule's half height plus its radius,
// and a margin so it clears the floor's surface.
PLAYER_BODY_OFFSET :: [3]f32{0, PLAYER_HALF_HEIGHT + PLAYER_RADIUS + 0.1, 0}
