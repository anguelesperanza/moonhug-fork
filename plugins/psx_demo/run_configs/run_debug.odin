package run_debug

import rc "moonhug:editor/runconfig"
import tool "moonhug:packages/game_export/runtool"

SCENE :: "packages/psx_demo/assets/psx_demo.scene"

main :: proc() {
	cfg := rc.Config{
		package_path = "moonhug/packages/psx_demo",
		out          = "builds/psx_demo_debug",
		flags        = {"-debug"},
	}

	if rc.dev_run() do rc.play(cfg, SCENE)

	if _, ok := rc.build(cfg); !ok do rc.exit_build_failed(cfg.package_path)
	if !tool.export_data(cfg.out, SCENE) do rc.exit_build_failed("builds/psx_demo_debug data")
	if !tool.package_dist(cfg.out, "moonhug/packages/psx_demo/README.txt") do rc.exit_build_failed("the packaged build")
	rc.run_build(cfg.out)
}
