package psx_demo

// Scripted input, for checking the demo without a keyboard: `--demo-script=`
// takes a comma-separated list of events, each at a frame of the demo's own
// count (frames start when the first level is entered):
//
//   30:N         press N at frame 30
//   40-100:W     hold W from frame 40 to frame 100
//   50:tp=1/0/2  put the player at x y z (a teleport, feet position)
//   60:drag      switch to the drag camera behind the player
//
// Keys are named as SDL names them (N, W, TAB, F11, LEFT ...). The script feeds
// the debug keys and, through psx_controls.key_source, the movement keys.

import "core:reflect"
import "core:os"
import "core:strconv"
import "core:strings"
import "moonhug:libs/input"
import "moonhug:packages/psx_controls"

@(private = "file")
Event :: struct {
	from, to: int,
	key:      input.Key,
	teleport: bool,
	drag:     bool,
	position: [3]f32,
}

@(private = "file")
_script: struct {
	events: [dynamic]Event,
	frame:  int,
	loaded: bool,
}

@(private = "file")
_script_load :: proc() {
	if _script.loaded do return
	_script.loaded = true
	for arg in os.args[1:] {
		if !strings.has_prefix(arg, "--demo-script=") do continue
		for item in strings.split(arg[len("--demo-script="):], ",", context.temp_allocator) {
			colon := strings.index_byte(item, ':')
			if colon < 0 do continue
			when_, what := item[:colon], item[colon + 1:]

			e: Event
			if dash := strings.index_byte(when_, '-'); dash >= 0 {
				e.from = strconv.parse_int(when_[:dash]) or_else 0
				e.to = strconv.parse_int(when_[dash + 1:]) or_else 0
			} else {
				e.from = strconv.parse_int(when_) or_else 0
				e.to = e.from
			}

			if what == "drag" {
				e.drag = true
			} else if strings.has_prefix(what, "tp=") {
				e.teleport = true
				parts := strings.split(what[3:], "/", context.temp_allocator)
				for part, i in parts do if i < 3 do e.position[i] = f32(strconv.parse_f64(part) or_else 0)
			} else if key, ok := reflect.enum_from_name(input.Key, what); ok {
				e.key = key
			} else {
				continue
			}
			append(&_script.events, e)
		}
	}
	if len(_script.events) > 0 do psx_controls.key_source = _script_held
}

// One frame of the script: called each tick of the demo. Returns a teleport
// scheduled for this frame, if any.
@(private)
script_step :: proc() -> (position: [3]f32, teleport: bool) {
	_script_load()
	_script.frame += 1
	for e in _script.events {
		if e.teleport && e.from == _script.frame do return e.position, true
	}
	return {}, false
}

// Whether the script switches to the drag camera this frame.
@(private)
script_drag :: proc() -> bool {
	for e in _script.events do if e.drag && e.from == _script.frame do return true
	return false
}

@(private)
script_active :: proc() -> bool {
	_script_load()
	return len(_script.events) > 0
}

// Whether the script presses `key` this frame (a press is one frame).
@(private)
script_pressed :: proc(key: input.Key) -> bool {
	for e in _script.events {
		if !e.teleport && !e.drag && e.key == key && e.from == _script.frame && e.to == e.from do return true
	}
	return false
}

@(private = "file")
_script_held :: proc(key: input.Key) -> bool {
	// A script that holds nothing leaves the keyboard in charge.
	for e in _script.events {
		if !e.teleport && !e.drag && e.key == key && e.to > e.from && _script.frame >= e.from && _script.frame <= e.to do return true
	}
	return input.key_down(key)
}
