package editor

// Relaunch: rebuild and restart the editor the same way it was started.
//
// tools/mh launches the editor with MH_LAUNCH=<mode> ("run" or "debug"). The
// Relaunch button spawns `odin run tools/mh -- <mode>` with MH_RELAUNCH_PID
// set to this process, and the editor keeps running while that builds. mh
// writes builds/relaunch_ready once the build succeeds, this editor sees the
// file and quits through the normal path (settings saved), mh waits for the
// exit and launches the new binary. A failed build writes no marker, so the
// editor stays up and the compiler output is in the terminal mh runs in.
//
// Without MH_LAUNCH (a bare binary started by hand) the mode comes from how
// this binary was compiled: ODIN_DEBUG picks `debug`, otherwise `run`. Both
// produce the same builds/MoonHug, so the restart still rebuilds and runs the
// editor the way it is running now.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "menu"
import "moonhug:editor/runconfig"
import "moonhug:libs/log"

RELAUNCH_MARKER :: "builds/relaunch_ready" // relative to the repository root

@(private = "file")
_relaunch: struct {
	pending:   bool,
	process:   os.Process,
	marker:    string, // absolute path of the ready marker
	repo_root: string,
}

// The mh mode that rebuilds and runs the editor the way it is running now:
// the one that started it, or, for a bare binary, the one matching its build.
relaunch_mode :: proc() -> string {
	if mode, ok := os.lookup_env("MH_LAUNCH", context.temp_allocator); ok && mode != "" {
		return mode
	}
	return "debug" when ODIN_DEBUG else "run"
}

// Where `odin run` puts mh for this editor. Its default, mh<exe> in the repo
// root, is the very program that launched this editor and is still running as
// its parent, so on Windows the compiler cannot overwrite it (exit 13). A name
// per editor pid cannot collide with the launcher's, or with the mh a
// previous relaunch started. It stays in the repository root: mh starts its
// cached tools by paths relative to there, and from a subfolder Windows cannot
// find them.
RELAUNCH_MH_PREFIX :: "mh_relaunch_"

@(private = "file")
_relaunch_out :: proc() -> string {
	return fmt.tprintf("%s%d%s", RELAUNCH_MH_PREFIX, os.get_pid(), runconfig.EXE_SUFFIX)
}

// The exact command Relaunch runs, for the tooltip.
relaunch_command :: proc() -> string {
	return fmt.tprintf("odin run tools/mh -out:%s -- %s", _relaunch_out(), relaunch_mode())
}

// Removes the mh binaries earlier relaunches left behind. One still running
// is locked and stays; the next relaunch tries again.
@(private = "file")
_relaunch_sweep_old_mh :: proc(root: string) {
	dir, err := os.open(root)
	if err != nil do return
	defer os.close(dir)
	files, rerr := os.read_dir(dir, -1, context.temp_allocator)
	if rerr != nil do return
	for f in files {
		if !strings.has_prefix(f.name, RELAUNCH_MH_PREFIX) do continue
		full, _ := filepath.join({root, f.name}, context.temp_allocator)
		_ = os.remove(full)
	}
}

relaunch_pending :: proc() -> bool {
	return _relaunch.pending
}

// The repository root: the working directory is normalized to moonhug/ at
// startup, so the root is one level up.
@(private = "file")
_repo_root :: proc() -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return ".."
	return filepath.dir(cwd)
}

relaunch_request :: proc() {
	if _relaunch.pending do return
	root := _repo_root()
	mode := relaunch_mode()

	marker, _ := filepath.join({root, RELAUNCH_MARKER}, context.temp_allocator)
	if os.exists(marker) do _ = os.remove(marker) // stale from an interrupted run

	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") do continue
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("MH_RELAUNCH_PID=%d", os.get_pid()))
	_relaunch_sweep_old_mh(root)

	process, err := os.process_start({
		working_dir = root,
		command     = {"odin", "run", "tools/mh", fmt.tprintf("-out:%s", _relaunch_out()), "--", mode},
		env         = env[:],
		stdout      = os.stdout,
		stderr      = os.stderr,
	})
	if err != nil {
		log.errorf("[relaunch] cannot start `%s`: %v (is odin on PATH?)", relaunch_command(), err)
		return
	}
	_relaunch = {pending = true, process = process, marker = strings.clone(marker), repo_root = strings.clone(root)}
	log.infof("[relaunch] building with `%s`, the editor restarts when it succeeds", relaunch_command())
}

// Once per frame. Quits when the replacement is built, or drops the request
// when the build fails.
relaunch_tick :: proc() {
	if !_relaunch.pending do return

	if os.exists(_relaunch.marker) {
		log.infof("[relaunch] build ready, restarting")
		_relaunch_clear()
		menu.quit_requested = true
		return
	}

	// A finished mh with no marker means the build failed (a success only
	// exits after this editor is gone).
	state, err := os.process_wait(_relaunch.process, 0)
	if err == nil && state.exited {
		log.errorf("[relaunch] build failed (mh exit %d), editor keeps running", state.exit_code)
		_relaunch_clear()
	}
}

@(private = "file")
_relaunch_clear :: proc() {
	delete(_relaunch.marker)
	delete(_relaunch.repo_root)
	_relaunch = {}
}

@(menu_item={path="File/Relaunch", order=9, shortcut=""})
file_relaunch_menu :: proc() { relaunch_request() }
