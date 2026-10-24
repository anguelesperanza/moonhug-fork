package psx

// The PSX frame: three render steps in a pipeline slot of their own.
//
//   psx_scene    draws the scene into a low-res HDR target (vertex-snapped,
//                affine-textured, lit per vertex, dithered to 15-bit colour
//                inside the PSX world shader), semi-transparent objects through
//                a layer and a composite, then the FRAME text
//   psx_post     interlacing: redraws one field of the frame a frame
//   psx_present  puts the frame on the camera's target: 4:3 bars, nearest
//                sampling, the CRT effects, then the SCREEN text
//
// A Camera renders through them when its `slot` is "Psx". The engine's frame
// (plugins/engine/docs/RenderPipeline.md) is a pipeline asset, and the project
// owns which asset that is, so the slot is added to the active pipeline in
// memory (slot_ensure) rather than by editing a project setting.
//
// The frame's targets hold raw display values (what the PS1 would write to its
// framebuffer), not linear light: nothing between the scene shader and the
// present shader converts colour. The present shader's output is converted to
// linear once, because ending a pass on the window encodes it back to sRGB.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:strings"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"
import "moonhug:packages/engine"

PSX_SLOT :: "Psx"

STEP_SCENE   :: "psx_scene"
STEP_POST    :: "psx_post"
STEP_PRESENT :: "psx_present"

FRAME_TARGET   :: "psx_frame"   // the scene
SCRATCH_TARGET :: "psx_scratch" // the other half of the composite ping-pong
LAYER_TARGET   :: "psx_layer"   // one blend mode's objects, before they composite
DISPLAY_TARGET :: "psx_display" // the interlaced frame: keeps last frame's other field

// The view of the PSX frame one camera's run works out once and the steps share.
@(private)
Frame :: struct {
	valid:   bool,
	view:    PsxView,           // a copy, as it was when the scene step ran
	size:    [2]i32,            // the low-res frame in pixels
	surface: [2]f32,            // the window or view the frame is shown on, in pixels
	rect:    [4]f32,            // where on that surface: x, y, width, height
	image:   ^gfx.Render_Target, // the finished frame so far: FRAME_TARGET, or a later pass's
}

@(private)
_frame: Frame

// The PSX world shader's per-draw block (psx.frag.glsl PsxUBO), every member a
// vec4 so std140 lays it out as it reads.
@(private)
Psx_UBO :: struct {
	fog_color:      [4]f32,
	flags:          [4]f32, // x affine textures, y 15-bit colour, z dithering, w colour key
	lighting:       [4]f32, // x mode (0 unlit, 1 baked, 2 live), y hemisphere ambient, z max light
	ambient:        [4]f32,
	ambient_ground: [4]f32,
	live_dir:       [3][4]f32,
	live_col:       [3][4]f32,
}

// A step's registration: reads "scene" so the pipeline window shows it as a
// scene pass. The frame it draws is read back by name from the view's pool.
@(render_step={summary="draws the scene into the low-res PSX frame: vertex snapping, affine textures, baked vertex lighting, 15-bit dithering, fog", reads="scene"})
psx_scene :: proc(ctx: ^engine.Render_Ctx) {
	_frame = {}
	@(static) said := false
	if !said {
		said = true
		log.infof("[PSX] the Psx slot is rendering (camera %v)", ctx.view.camera != {})
	}
	if ctx.view.kind != .Game || !shaders_ensure() do return

	camera := ctx.view.camera
	cam: ^engine.Camera
	if camera != {} do _, cam = engine.transform_get_comp(camera, engine.Camera)
	if cam == nil do return

	view := view_for(camera)^
	surface := _surface_size(ctx)
	if surface.x < 1 || surface.y < 1 do return

	size := frame_size(view, surface)
	rect := display_rect(view.display_aspect, surface)

	f := &_frame
	f.view = view
	f.size = size
	f.surface = surface
	f.rect = rect

	// The camera, projected for the shape the frame is shown at, so the
	// picture is never squashed. Its far plane is the draw distance.
	tw := engine.transform_world(engine.Transform_Handle(cam.owner))
	rot := engine.quat_to_matrix3(tw.rotation)
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	view_matrix := linalg.matrix4_look_at_f32(tw.position, tw.position + forward, up)
	far := cam.far_clip
	if view.draw_distance > cam.near_clip do far = view.draw_distance
	proj := gfx.matrix4_perspective_z01(math.to_radians(cam.fov), rect.z / rect.w, cam.near_clip, far)
	view_proj := proj * view_matrix

	rt := gfx.pool_target(ctx.pool, FRAME_TARGET, size.x, size.y, .HDR)
	if state.last_size != size {
		state.last_size = size
		state.interlace_fresh = true // the display target is a new texture now too
	}
	f.image = rt

	// The clear colour, as the framebuffer would hold it: cut to 5 bits a
	// channel in 15-bit mode, background included.
	bg := _clear_color(cam.clear_color, view.color_depth)

	items := collect_items(cam.render_layer_mask)
	batches := static_batches(items, view.subdivision)

	// What the frame draws, said once and again when it changes.
	report := [3]int{len(items), len(batches), int(size.x) * 10000 + int(size.y)}
	if report != state.last_report {
		state.last_report = report
		log.infof("[PSX] frame %dx%d: %d renderers, %d merged batches", size.x, size.y, len(items), len(batches))
	}

	ubo_static := _make_ubo(view, state.lighting_enabled ? 1 : 0)
	static_bytes := _ubo_bytes(ubo_static)

	gfx.pass_begin_target(rt, gfx.linear_to_srgb(bg))
	gfx.set_view_proj(view_proj, tw.position)
	for &b in batches {
		gfx.draw_mesh(b.mesh, b.tex, _carrier(linalg.MATRIX4F32_IDENTITY, view, size), b.tint, WORLD_SHADER, material = static_bytes, cull = b.cull)
	}
	for &item in items {
		if item.blend == .OPAQUE && item.lighting == .LIVE do _draw_item(item, view, size, ubo_static)
	}
	gfx.pass_end()

	// Semi-transparent objects: each blend mode draws into a layer against the
	// scene's depth and composites onto the frame.
	for mode in Blend_Mode.HALF ..= Blend_Mode.QUARTER_ADD {
		any := false
		for &item in items do if item.blend == mode do any = true
		if !any do continue
		_blend_layer(ctx, f, items, mode, view, size, view_proj, tw.position, ubo_static)
	}

	// FRAME text goes on the finished frame, in a pass of its own: a fresh
	// depth, so it lands over whatever the scene drew.
	if has_queued_text(.FRAME) {
		gfx.pass_begin_target(f.image, nil)
		gfx.set_view_proj(gfx.matrix4_ortho_pixels(f32(size.x), f32(size.y)))
		draw_queued_text(.FRAME)
		gfx.pass_end()
	}

	f.valid = true
}

@(render_step={summary="interlacing: redraws one field of the PSX frame a frame, so motion combs"})
psx_post :: proc(ctx: ^engine.Render_Ctx) {
	f := &_frame
	if !f.valid do return
	active := f.view.interlacing && (f.view.video_mode == .NTCS_I || f.view.video_mode == .PAL_I)
	if !active {
		state.interlace_fresh = true
		return
	}

	display := gfx.pool_target(ctx.pool, DISPLAY_TARGET, f.size.x, f.size.y, .HDR)
	field := f32(state.interlace_fresh ? -1 : state.field)
	params := new_clone([4]f32{field, 0, 0, 0}, context.temp_allocator)

	inputs := make([]^gfx.Texture, 1, context.temp_allocator)
	inputs[0] = new_clone(gfx.rt_color_texture(f.image), context.temp_allocator)

	gfx.pass_begin_target(display, nil) // nil keeps the field the last frame drew
	gfx.draw_fullscreen(INTERLACE_SHADER, inputs, (^[16]u8)(params)[:])
	gfx.pass_end()

	state.field = 1 - state.field
	state.interlace_fresh = false
	f.image = display
}

@(render_step={summary="puts the PSX frame on the camera's target: 4:3 bars, nearest sampling, CRT effects, screen text"})
psx_present :: proc(ctx: ^engine.Render_Ctx) {
	f := &_frame
	if !f.valid do return
	defer {
		clear_queued_text()
		f.valid = false
	}

	_present_to(ctx, f, ctx.target)
	// A screenshot is the same pass drawn once more into a target that can be read.
	screenshot_capture(ctx, f.surface, proc(ctx: ^engine.Render_Ctx, target: ^gfx.Render_Target) {
		_present_to(ctx, &_frame, target)
	})
}

// The present pass onto `target` (nil is the window): the frame through the
// present shader, then the SCREEN text.
@(private = "file")
_present_to :: proc(ctx: ^engine.Render_Ctx, f: ^Frame, target: ^gfx.Render_Target) {
	post := f.view.post
	on := post != {}
	ubo := new_clone([16]f32{
		f.rect.x, f.rect.y, f.rect.z, f.rect.w,
		f32(f.size.x), f32(f.size.y), 0, 0,
		post.blur, post.scanlines, post.curvature, post.vignette,
		post.mask, post.overscan ? 1 : 0, on ? 1 : 0, 0,
	}, context.temp_allocator)

	inputs := make([]^gfx.Texture, 1, context.temp_allocator)
	inputs[0] = new_clone(gfx.rt_color_texture(f.image), context.temp_allocator)

	if target == nil {
		if !gfx.pass_begin_swapchain([4]f32{0, 0, 0, 1}) do return
	} else {
		gfx.pass_begin_target(target, [4]f32{0, 0, 0, 1})
	}
	gfx.draw_fullscreen(PRESENT_SHADER, inputs, (^[64]u8)(ubo)[:])
	if has_queued_text(.SCREEN) {
		gfx.set_view_proj(gfx.matrix4_ortho_pixels(f.surface.x, f.surface.y))
		draw_queued_text(.SCREEN)
	}
	gfx.pass_end()
}

// Draws one blend mode's objects into a layer and composites it onto the frame.
@(private = "file")
_blend_layer :: proc(ctx: ^engine.Render_Ctx, f: ^Frame, items: []Item, mode: Blend_Mode, view: PsxView, size: [2]i32, view_proj: matrix[4, 4]f32, cam_pos: [3]f32, ubo: Psx_UBO) {
	layer := gfx.pool_target(ctx.pool, LAYER_TARGET, size.x, size.y, .HDR)
	scratch := gfx.pool_target(ctx.pool, SCRATCH_TARGET, size.x, size.y, .HDR)
	frame := gfx.pool_find(ctx.pool, FRAME_TARGET)

	// The layer is drawn against the frame's depth, which is the frame's own
	// target, so objects behind a wall stay hidden.
	gfx.pass_begin_target(layer, [4]f32{0, 0, 0, 0}, keep_depth = true, shared_depth = frame)
	gfx.set_view_proj(view_proj, cam_pos)
	for &item in items {
		if item.blend == mode do _draw_item(item, view, size, ubo)
	}
	gfx.pass_end()

	// Composite the layer onto the frame as it stands, into the other target.
	into := f.image == frame ? scratch : frame
	params := new_clone([4]f32{f32(mode), 0, 0, 0}, context.temp_allocator)
	inputs := make([]^gfx.Texture, 2, context.temp_allocator)
	inputs[0] = new_clone(gfx.rt_color_texture(f.image), context.temp_allocator)
	inputs[1] = new_clone(gfx.rt_color_texture(layer), context.temp_allocator)
	gfx.pass_begin_target(into, nil, keep_depth = true)
	gfx.draw_fullscreen(COMPOSITE_SHADER, inputs, (^[16]u8)(params)[:])
	gfx.pass_end()
	f.image = into
}

// One renderer drawn on its own: through the engine's GPU mesh for it, one
// draw a submesh, lit live by the three strongest lights at its centre when it
// asks for that.
@(private = "file")
_draw_item :: proc(item: Item, view: PsxView, size: [2]i32, base: Psx_UBO) {
	mesh, ok := engine.mesh_load(item.mesh, item.part)
	if !ok do return

	ubo := base
	if !state.lighting_enabled || item.lighting == .UNLIT || item.lighting == .BAKED {
		// Nothing was baked for this draw, so it shows its texture as it is.
		ubo.lighting[0] = 0
	} else {
		ubo.lighting[0] = 2
		center := [3]f32{item.model[0, 3], item.model[1, 3], item.model[2, 3]}
		live := live_lights_at(state.lights[:], center)
		for k in 0 ..< 3 {
			ubo.live_dir[k] = {live.directions[k].x, live.directions[k].y, live.directions[k].z, 0}
			ubo.live_col[k] = {live.colors[k].x, live.colors[k].y, live.colors[k].z, 0}
		}
	}
	bytes := _ubo_bytes(ubo)
	model := _carrier(item.model, view, size)
	mirrored := engine.render_mirrored(item.model)

	for sub, i in mesh.submeshes {
		material: engine.Asset_GUID
		if i < len(item.materials) do material = item.materials[i]
		mat := resolve_material(material)
		gfx.draw_mesh(mesh.gpu, mat.tex, model, item.tint * mat.color, WORLD_SHADER, sub.first_index, sub.index_count, material = bytes, cull = mat.cull, mirrored = mirrored)
	}
}

// The model matrix with the PSX vertex shader's settings in its bottom row
// (psx.vert.glsl): the frame's size when vertex snapping is on, the fog range.
@(private = "file")
_carrier :: proc(model: matrix[4, 4]f32, view: PsxView, size: [2]i32) -> matrix[4, 4]f32 {
	m := model
	m[3, 0] = view.vertex_snapping ? f32(size.x) : 0
	m[3, 1] = view.vertex_snapping ? f32(size.y) : 0
	m[3, 2] = view.fog_start
	m[3, 3] = view.fog_end
	return m
}

@(private = "file")
_make_ubo :: proc(view: PsxView, lighting: f32) -> (u: Psx_UBO) {
	u.fog_color = {view.fog_color.r, view.fog_color.g, view.fog_color.b, 1}
	u.flags = {
		view.texture_mode == .AFFINE ? 1 : 0,
		view.color_depth == .BITS_15 ? 1 : 0,
		view.dithering ? 1 : 0,
		view.color_key ? 1 : 0,
	}
	u.lighting = {lighting, state.ambient.kind == .HEMISPHERE ? 1 : 0, view.overbright ? 2 : 1, 0}
	a, g := state.ambient.color, state.ambient.ground_color
	u.ambient = {a.r, a.g, a.b, 0}
	u.ambient_ground = {g.r, g.g, g.b, 0}
	return
}

// The block's bytes for gfx.draw_mesh, which keeps them until the pass ends.
@(private = "file")
_ubo_bytes :: proc(u: Psx_UBO) -> []u8 {
	p := new_clone(u, context.temp_allocator)
	return ([^]u8)(p)[:size_of(Psx_UBO)]
}

// --- geometry of the frame ----------------------------------------------------------

// The pixels of the surface the camera renders to: the window's, or the
// editor's game view target.
@(private = "file")
_surface_size :: proc(ctx: ^engine.Render_Ctx) -> [2]f32 {
	if ctx.target != nil do return {f32(ctx.target.width), f32(ctx.target.height)}
	px := gfx.pixel_size()
	return {f32(px.x), f32(px.y)}
}

// The low-res frame's size: the resolution picks its width, the video mode its
// height. WIDESCREEN adds columns until the frame has the surface's shape,
// keeping each pixel the shape it has on a 4:3 display.
frame_size :: proc(view: PsxView, surface: [2]f32) -> [2]i32 {
	widths := [Resolution]i32{.RES_ONE = 256, .RES_TWO = 320, .RES_THREE = 368, .RES_FOUR = 512, .RES_FIVE = 640, .NONE = 0}
	width := widths[view.resolution]
	if view.resolution == .NONE {
		width = i32(surface.x) // already the surface's shape: never widened
	} else if view.display_aspect == .WIDESCREEN {
		width = i32(math.round(f32(width) * (surface.x / surface.y) / FOUR_THIRDS))
	}

	height: i32
	switch view.video_mode {
	case .NTCS_P: height = 240
	case .NTCS_I: height = 480
	case .PAL_P:  height = 256
	case .PAL_I:  height = 512
	case .NONE:   height = i32(surface.y)
	}
	return {max(width, 1), max(height, 1)}
}

// Where on the surface the frame is drawn (x, y, width, height in pixels).
display_rect :: proc(aspect: Display_Aspect, surface: [2]f32) -> [4]f32 {
	if aspect != .FOUR_THREE do return {0, 0, surface.x, surface.y}

	// The largest 4:3 rectangle that fits, centred.
	w := min(surface.x, surface.y * FOUR_THIRDS)
	h := w / FOUR_THIRDS
	return {(surface.x - w) * 0.5, (surface.y - h) * 0.5, w, h}
}

// A clear colour as the PS1's framebuffer would hold it.
@(private = "file")
_clear_color :: proc(c: [4]f32, depth: Color_Depth) -> [4]f32 {
	out := [4]f32{c.r, c.g, c.b, 1}
	if depth == .BITS_15 {
		for k in 0 ..< 3 {
			b := u32(clamp(out[k], 0, 1) * 255 + 0.5)
			out[k] = f32(((b >> 3) * 255 + 15) / 31) / 255
		}
	}
	return out
}

// --- the slot -----------------------------------------------------------------------

// A render collector that collects nothing: the engine calls every collector
// before it runs a camera's pipeline lane, which makes this the hook that
// puts the Psx slot in the active pipeline in time (slot_ensure).
@(phase={key=ImportersInit, order=3})
psx_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.render_register_collector(_collect_nothing)
}

@(private = "file")
_collect_nothing :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	slot_ensure()
}

// Adds the Psx slot, with the three steps in order, to the active render
// pipeline when it is not there. The pipeline is rebuilt from its asset when
// the project's Rendering setting changes, which drops the slot: this runs
// before every camera's lane, so it comes straight back. Nothing is saved: the
// project's .renderpipeline asset is the project's, and is left alone.
slot_ensure :: proc() {
	context.allocator = runtime.default_allocator()
	runtime_pipeline := engine.render_pipeline_active()
	if PSX_SLOT in runtime_pipeline.slots do return

	lane := make([dynamic]engine.Pipeline_Instance)
	ids := [?]i32{900001, 900002, 900003}
	names := [?]string{STEP_SCENE, STEP_POST, STEP_PRESENT}
	for name, i in names {
		step := engine.render_step_find(name)
		if step == nil {
			log.errorf("[PSX] render step %q is not registered", name)
			delete(lane)
			return
		}
		// Everything an instance owns is freed with it when the pipeline is
		// rebuilt (engine._pipeline_runtime_destroy), so it is all on the heap.
		inst := engine.Pipeline_Instance{id = ids[i], step = step}
		inst.reads = make([]string, len(step.reads))
		for r, k in step.reads do inst.reads[k] = strings.clone(r)
		inst.writes = make([]engine.Render_Target_Decl, len(step.writes))
		for w, k in step.writes {
			inst.writes[k] = w
			inst.writes[k].name = strings.clone(w.name)
		}
		append(&lane, inst)
	}
	slot_name := make([]u8, len(PSX_SLOT))
	copy(slot_name, PSX_SLOT)
	runtime_pipeline.slots[string(slot_name)] = lane
}
