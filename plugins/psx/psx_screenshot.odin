package psx

// Screenshots of the PSX frame as it reaches the window: the present pass is
// drawn a second time into an offscreen target, read back, and written as a PNG.
// The window's own image cannot be read on every backend, and a capture of the
// screen would catch whatever else is on it.
//
//   psx.request_screenshot("shot.png")   from game code (the demo binds F12)
//   --psx-shot=shot.png                  from the command line: saves after
//   --psx-shot-frames=120                that many frames (default 120) and quits

import "base:runtime"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"
import "moonhug:packages/engine"

SHOT_TARGET :: "psx_shot"

@(private = "file")
_shot: struct {
	path:     string,                  // asked for, not yet drawn
	download: ^gfx.Texture_Download,   // in flight
	saving:   string,                  // where that download goes
	// --psx-shot: a request that waits `frames` frames and ends the program.
	cli_path: string,
	frames:   int,
	quit:     bool,
	armed:    bool,
}

// Writes the next frame to `path` as a PNG.
request_screenshot :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	delete(_shot.path)
	_shot.path = strings.clone(path)
}

screenshot_pending :: proc() -> bool {
	return _shot.path != ""
}

// Called by the present step: has `draw` fill an offscreen target the size of
// the surface and starts reading it back, when a screenshot was asked for.
@(private)
screenshot_capture :: proc(ctx: ^engine.Render_Ctx, surface: [2]f32, draw: proc(ctx: ^engine.Render_Ctx, target: ^gfx.Render_Target)) {
	if _shot.path == "" || _shot.download != nil do return
	context.allocator = runtime.default_allocator()
	rt := gfx.pool_target(ctx.pool, SHOT_TARGET, i32(surface.x), i32(surface.y), .Display)
	draw(ctx, rt)
	_shot.download = gfx.frame_capture_begin(rt)
	if _shot.download == nil {
		log.errorf("[PSX] could not read the frame back for %s", _shot.path)
		delete(_shot.path)
	} else {
		_shot.saving = _shot.path
	}
	_shot.path = ""
}

// Finishes a screenshot once the GPU has the pixels, and runs the command line's
// request. Every frame, after the render has been submitted.
@(late_update)
psx_screenshot_poll :: proc(dt: f32) {
	context.allocator = runtime.default_allocator()

	if !_shot.armed {
		_shot.armed = true
		_shot.frames = 120
		for arg in os.args[1:] {
			if strings.has_prefix(arg, "--psx-shot-frames=") {
				_shot.frames = strconv.parse_int(arg[len("--psx-shot-frames="):]) or_else 0
			} else if strings.has_prefix(arg, "--psx-shot=") {
				_shot.cli_path = strings.clone(arg[len("--psx-shot="):])
				_shot.quit = true
			}
		}
	}
	if _shot.cli_path != "" {
		_shot.frames -= 1
		if _shot.frames <= 0 {
			request_screenshot(_shot.cli_path)
			delete(_shot.cli_path)
			_shot.cli_path = ""
		}
	}

	if _shot.download == nil || !gfx.texture_download_ready(_shot.download) do return

	w, h := _shot.download.width, _shot.download.height
	pixels := gfx.texture_download_take(_shot.download)
	_shot.download = nil
	defer delete(pixels)
	defer {
		delete(_shot.saving)
		_shot.saving = ""
	}
	if pixels == nil do return

	// A display target's alpha is whatever the pass left: the picture is opaque.
	for i := 3; i < len(pixels); i += 4 do pixels[i] = 255
	cpath := strings.clone_to_cstring(_shot.saving, context.temp_allocator)
	if stbi.write_png(cpath, c.int(w), c.int(h), 4, raw_data(pixels), c.int(w * 4)) == 0 {
		log.errorf("[PSX] could not write %s", _shot.saving)
	} else {
		log.infof("[PSX] screenshot: %s", _shot.saving)
	}
	if _shot.quit do gfx.request_quit()
}
