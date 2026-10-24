package game_export

// What a MoonHug game needs to run as a program of its own, outside the
// repository it was built in. Two halves:
//
//   this package   prepare_standalone, called first in a game's `main`
//   runtool/       what the game's run configurations call to stage and package
//                  the build (it links the editor's run config support, so no
//                  game binary may import it)
//
// Both work around what the engine's player and export do on Windows (the
// plugin's page, plugins/game_export/docs/GameExport.md, lists them).

import "core:os"
import "core:path/filepath"
import "core:strings"
import "moonhug:libs/assets"

// Makes the program start from wherever it was put. Call it before anything else
// in a game's `main`, before __standalone_run.
//
//   - The player anchors itself at the project directory, a folder holding
//     `assets` and `ProjectSettings` at or above where it runs, and panics when
//     there is none. A copy of the game outside the repository has none above
//     the folder it is started from, and a shortcut starts it from any folder
//     at all, so a game with no project directory anchors at its own folder,
//     where the packaged build keeps the two (runtool.package_dist).
//   - A program started bare looks for its data folder beside it, spelled as its
//     own path plus `_data`. On Windows that path ends in `.exe` and the export
//     writes `<name>_data`, so the data is not found and the game would fall back
//     on the editor's catalog. When the folder is there, `--catalog=` is passed
//     for it.
prepare_standalone :: proc() {
	_find_home()
	_find_data()
}

@(private = "file")
_find_home :: proc() {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return
	if _, found := assets.project_root_find(cwd); found do return
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil do return
	context.allocator = context.temp_allocator // filepath.dir allocates
	_ = os.set_working_directory(filepath.dir(exe))
}

@(private = "file")
_find_data :: proc() {
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--catalog") do return
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return
	catalog := strings.concatenate({strings.trim_suffix(exe, ".exe"), "_data/catalog.json"}, context.temp_allocator)
	if !os.exists(catalog) do return

	// The arguments are the program's for its whole life.
	args := make([dynamic]string)
	append(&args, ..os.args)
	append(&args, strings.concatenate({"--catalog=", catalog}))
	os.args = args[:]
}
