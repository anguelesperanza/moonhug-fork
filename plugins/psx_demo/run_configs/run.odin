package run

import rc "moonhug:editor/runconfig"
import tool "moonhug:packages/game_export/runtool"

// The scene the demo boots: the player, the camera and the level swapper. The
// levels are scenes it lists, so the export carries them too.
SCENE :: "packages/psx_demo/assets/psx_demo.scene"

main :: proc() {
	cfg := rc.Config{package_path = "moonhug/packages/psx_demo", out = "builds/psx_demo"}

	// A dev run (the toolbar's plain click) plays against the editor's live
	// catalog and needs no export.
	if rc.dev_run() do rc.play(cfg, SCENE)

	// The shipping shape: build, stage `builds/psx_demo_data` beside the program
	// (the export is game_export's: see there for why), run it.
	if _, ok := rc.build(cfg); !ok do rc.exit_build_failed(cfg.package_path)
	if !tool.export_data(cfg.out, SCENE) do rc.exit_build_failed("builds/psx_demo data")
	if !tool.package_dist(cfg.out, "moonhug/packages/psx_demo/README.txt") do rc.exit_build_failed("the packaged build")
	rc.run_build(cfg.out)
}
