package game_export_runtool

// What a game's run configurations share, so a second game exports the way the
// first does. A run config is a single-file program (docs/core/Plugins.md) that
// imports the editor's runconfig package, which a game binary must never link,
// so this lives in a subpackage the plugin's root does not import. Its other
// half, for the game's own `main`, is the plugin root (game_export.odin).
//
// What it adds to the engine's run config support is the export on Windows. The editor writes the catalog (moonhug/library/catalog.json) with
// each asset's path in the platform's own spelling, `packages\psx_demo\...`,
// while catalog.export_from makes the directories of a copy by splitting at
// '/', so on Windows it finds no folder to put the copy in and fails with
// "cannot copy". export_data hands it a copy of the catalog spelled with '/'.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "moonhug:libs/catalog"
import rc "moonhug:editor/runconfig"

// The catalog the export reads, beside the editor's own (library/ is the
// editor's cache and is not committed).
@(private)
NORMALIZED :: "moonhug/library/catalog.export.json"

// rc.export_data with the catalog's paths spelled with '/': stages
// `<out>_data` beside the binary from the editor's catalog, with the boot
// scene stamped, and honours the run-only flag as rc.export_data does.
export_data :: proc(out, scene: string) -> bool {
	if !rc.chdir_repo_root() do return false
	data_dir := fmt.tprintf("%s_data", out)
	if rc.run_only() {
		if !os.exists(fmt.tprintf("%s/catalog.json", data_dir)) {
			fmt.eprintf("run config: no staged data at %s: build first (run without Shift)\n", data_dir)
			return false
		}
		return true
	}

	source, err := os.read_entire_file("moonhug/library/catalog.json", context.temp_allocator)
	if err != nil {
		fmt.eprintf("run config: cannot read moonhug/library/catalog.json: open the editor once so it writes the catalog\n")
		return false
	}
	// In the JSON text a backslash is `\\`; a path holds no other escape.
	normalized, _ := strings.replace_all(string(source), "\\\\", "/", context.temp_allocator)
	if os.write_entire_file(NORMALIZED, transmute([]u8)normalized) != nil {
		fmt.eprintf("run config: cannot write %s\n", NORMALIZED)
		return false
	}
	defer os.remove(NORMALIZED)

	// The scene the editor passed (its live snapshot), staged too: it is not in
	// the catalog.
	live := [1]string{rc.scene_arg()}
	extra := live[:] if live[0] != "" else nil
	if !catalog.export_from(NORMALIZED, data_dir, scene, root = "moonhug", extra_roots = extra) {
		fmt.eprintf("run config: data export failed for %s (is the editor's catalog current?)\n", out)
		return false
	}
	return true
}

// Assembles `<out>_dist`: a folder that is the whole game, to copy anywhere and
// run. The program, its data, the SDL libraries it loads (on Windows, from the
// Odin installation that built it), and the two empty folders the player looks
// for to find its home (game_export.prepare_standalone).
//
// `readme` names a text file (repo-root relative) to ship as README.txt, or "".
package_dist :: proc(out: string, readme := "") -> bool {
	if !rc.chdir_repo_root() do return false
	dist := fmt.tprintf("%s_dist", out)
	name := filepath.base(out)
	exe := fmt.tprintf("%s%s", out, rc.EXE_SUFFIX)

	if os.exists(dist) && !_remove_tree(dist) {
		fmt.eprintf("run config: cannot clear %s\n", dist)
		return false
	}
	if os.make_directory_all(dist) != nil {
		fmt.eprintf("run config: cannot make %s\n", dist)
		return false
	}

	if !_copy_file(exe, fmt.tprintf("%s/%s%s", dist, name, rc.EXE_SUFFIX)) {
		fmt.eprintf("run config: cannot copy %s\n", exe)
		return false
	}
	if !_copy_tree(fmt.tprintf("%s_data", out), fmt.tprintf("%s/%s_data", dist, name)) {
		fmt.eprintf("run config: cannot copy %s_data\n", out)
		return false
	}
	// What the player anchors itself by: both must exist, and may be empty.
	_ = os.make_directory_all(fmt.tprintf("%s/assets", dist))
	_ = os.make_directory_all(fmt.tprintf("%s/ProjectSettings", dist))

	when ODIN_OS == .Windows {
		// The libraries the program is linked against: SDL3 and what SDL3_mixer
		// loads beside it. Odin ships them with its vendor packages.
		for folder in ([]string{"vendor/sdl3", "vendor/sdl3/mixer"}) {
			source := fmt.tprintf("%s/%s", ODIN_ROOT, folder)
			handle, err := os.open(source)
			if err != nil do continue
			entries, _ := os.read_dir(handle, -1, context.temp_allocator)
			os.close(handle)
			for entry in entries {
				if entry.type == .Directory || !strings.has_suffix(entry.name, ".dll") do continue
				_copy_file(fmt.tprintf("%s/%s", source, entry.name), fmt.tprintf("%s/%s", dist, entry.name))
			}
		}
	}

	if readme != "" do _ = _copy_file(readme, fmt.tprintf("%s/README.txt", dist))
	fmt.printfln("[Package] %s", dist)
	return true
}

@(private = "file")
_copy_file :: proc(src, dst: string) -> bool {
	data, err := os.read_entire_file(src, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(dst, data) == nil
}

// Copies a folder and everything under it.
@(private = "file")
_copy_tree :: proc(src, dst: string) -> bool {
	if os.make_directory_all(dst) != nil do return false
	handle, err := os.open(src)
	if err != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false
	for entry in entries {
		from := fmt.tprintf("%s/%s", src, entry.name)
		to := fmt.tprintf("%s/%s", dst, entry.name)
		if entry.type == .Directory {
			if !_copy_tree(from, to) do return false
		} else if !_copy_file(from, to) {
			return false
		}
	}
	return true
}

@(private = "file")
_remove_tree :: proc(path: string) -> bool {
	if !os.is_dir(path) do return os.remove(path) == nil
	handle, err := os.open(path)
	if err != nil do return false
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return false
	for entry in entries {
		if !_remove_tree(fmt.tprintf("%s/%s", path, entry.name)) do return false
	}
	return os.remove(path) == nil
}
