package psx_demo

// The psx-framework's demo (its main.odin) as a MoonHug game: a runnable
// package, so its run configuration builds it, stages its data and runs it as
// a stand-alone program (docs/core/Plugins.md, Run configurations).
//
// The framework's pieces are plugins: psx renders the frame, psx_camera and
// psx_controls move the camera and the player, psx_level reads a level's
// spawns, triggers and lights. This package is the game made of them: the
// player, the level swapping, the debug keys (component_PsxDemo.odin) and the
// scenes in assets/. Its `main` is all the engine asks of a game, plus
// game_export.prepare_standalone, which a program that is not run from the
// repository needs.

import "moonhug:packages/engine"
import "moonhug:packages/game_export"

main :: proc() {
	game_export.prepare_standalone()

	// The window the demo asks for, over the project's Player setting (which
	// belongs to the app plugin's game). The setting is loaded once, here, so the
	// player's boot finds it loaded and leaves what is set.
	engine._ensure_player_settings()
	engine.player_settings.title = "PSX Framework Demo"
	engine.player_settings.width = 1920
	engine.player_settings.height = 1080

	__standalone_run()
}
