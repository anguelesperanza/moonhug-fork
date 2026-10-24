package psx

// Level geometry for the PSX frame: the meshes' CPU vertices, subdivided and
// baked, merged into a few big world-space meshes.
//
// The original loaded each model, copied its meshes per object with the lights
// baked into the vertex colours and drew them one DrawModel at a time. Here the
// scene is made of MeshRenderers, so the same work is done when the frame first
// sees them: every BAKED renderer's submeshes are moved to world space, split
// to `subdivision` metre edges, lit, and appended to one mesh per (material,
// tint). A level of thousands of floor tiles is then a handful of draws. The
// batches rebuild when the set of renderers, their transforms, the lights or
// the subdivision change; a still level costs one hash of its renderers a frame.
//
// Things that move (LIVE renderers) are not merged: they draw through the
// engine's own GPU meshes, lit per object (psx_render.odin).

import "base:runtime"
import "core:encoding/uuid"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"
import "moonhug:packages/engine"

// One MeshRenderer as the frame sees it.
Item :: struct {
	owner:     engine.Transform_Handle,
	mesh:      engine.Asset_GUID,
	part:      i32,
	model:     matrix[4, 4]f32,
	materials: []engine.Asset_GUID, // the renderer's own array, valid for the frame
	lighting:  Lighting_Mode,
	blend:     Blend_Mode,
	tint:      [4]f32,
	loadable:  bool, // the mesh loaded: part of the signature, so one that arrives late rebuilds
	// A PsxTileGrid rather than a MeshRenderer: `columns` by `rows` cells of the
	// mesh, `model` placing the first.
	grid:      ^PsxTileGrid,
}

// Every enabled MeshRenderer the camera's layers show, in pool order.
collect_items :: proc(layer_mask: u32) -> []Item {
	items := make([dynamic]Item, 0, 64, context.temp_allocator)
	w := engine.ctx_world()
	it := engine.pool_iterator(engine.mesh_renderers(w))
	for mr, _ in engine.pool_next(&it) {
		if !mr.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(mr.owner))
		if t == nil || !engine.transform_active_in_hierarchy(mr.owner) do continue
		if t.render_layer & layer_mask == 0 do continue
		if draws, _ := engine.render_pass_includes(.Color, mr.cast_shadows, mr.reflections); !draws do continue

		_, mf := engine.transform_get_comp(mr.owner, engine.MeshFilter)
		if mf == nil || engine.asset_guid_is_empty(mf.mesh.guid) do continue
		part, part_ok := engine.mesh_filter_part(mf)
		if !part_ok do continue

		tw := engine.transform_world(mr.owner)
		item := Item{
			owner     = mr.owner,
			mesh      = mf.mesh.guid,
			part      = part,
			model     = engine.trs_matrix(tw.position, tw.rotation, tw.scale),
			materials = mr.materials[:],
			lighting  = .BAKED,
			tint      = {1, 1, 1, 1},
		}
		if _, pr := get_comp(mr.owner, PsxRenderer); pr != nil && pr.enabled {
			item.lighting = pr.lighting
			item.blend    = pr.blend
			item.tint     = pr.tint
		}
		_, item.loadable = engine.mesh_load(item.mesh, item.part)
		append(&items, item)
	}

	git := engine.pool_iterator(psx_tile_grids(w))
	for g, _ in engine.pool_next(&git) {
		if !g.enabled || engine.asset_guid_is_empty(g.mesh) do continue
		t := engine.pool_get(&w.transforms, engine.Handle(g.owner))
		if t == nil || !engine.transform_active_in_hierarchy(g.owner) do continue
		if t.render_layer & layer_mask == 0 do continue

		tw := engine.transform_world(g.owner)
		item := Item{
			owner     = g.owner,
			mesh      = g.mesh,
			model     = engine.trs_matrix(tw.position, tw.rotation, tw.scale),
			materials = g.materials[:],
			lighting  = .BAKED,
			tint      = {1, 1, 1, 1},
			grid      = g,
		}
		_, item.loadable = engine.mesh_load(item.mesh, 0)
		append(&items, item)
	}
	return items[:]
}

// A material as the PSX shader uses it: the texture its Material names, its
// colour and which faces it draws. A renderer with no material draws white.
Resolved_Material :: struct {
	tex:   ^gfx.Texture, // nil = white
	color: [4]f32,
	cull:  gfx.Cull,
}

resolve_material :: proc(guid: engine.Asset_GUID) -> Resolved_Material {
	r := Resolved_Material{color = {1, 1, 1, 1}, cull = .Back}
	if engine.asset_guid_is_empty(guid) do return r
	mat, ok := engine.material_load(guid)
	if !ok do return r
	r.color = mat.color
	switch mat.render_face {
	case .Front: r.cull = .Back
	case .Back:  r.cull = .Front
	case .Both:  r.cull = .None
	}
	if !engine.asset_guid_is_empty(mat.texture) {
		if tex, tex_ok := engine.texture_load(mat.texture); tex_ok do r.tex = tex.gfx
	}
	return r
}

// --- CPU meshes -------------------------------------------------------------------

// A mesh asset's vertices, kept on the CPU: the engine uploads them and lets
// go, but baking needs them.
Cpu_Mesh :: struct {
	vertices:  []gfx.Vertex,
	indices:   []u32,
	submeshes: []engine.Mesh_Submesh,
}

@(private = "file") _cpu_cache: map[engine.Mesh_Key]Cpu_Mesh

cpu_mesh :: proc(guid: engine.Asset_GUID, part: i32) -> (^Cpu_Mesh, bool) {
	context.allocator = runtime.default_allocator()
	key := engine.Mesh_Key{guid, part}
	if m, ok := &_cpu_cache[key]; ok do return m, true

	// The engine's own load first: it imports a missing artifact.
	if _, ok := engine.mesh_load(guid, part); !ok do return nil, false

	whole := engine._artifact_path(uuid.Identifier(guid))
	defer delete(whole)
	artifact := whole
	if part > 0 do artifact = engine.mesh_part_artifact_path(whole, int(part - 1), context.temp_allocator)
	blob, err := os.read_entire_file(artifact, context.temp_allocator)
	if err != nil do return nil, false
	_, vertices, indices, submeshes, parsed := engine._mesh_artifact_parse(blob)
	if !parsed do return nil, false

	m := Cpu_Mesh{
		vertices  = make([]gfx.Vertex, len(vertices)),
		indices   = make([]u32, len(indices)),
		submeshes = make([]engine.Mesh_Submesh, len(submeshes)),
	}
	copy(m.vertices, vertices)
	copy(m.indices, indices)
	copy(m.submeshes, submeshes)
	_cpu_cache[key] = m
	return &_cpu_cache[key], true
}

cpu_meshes_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for _, m in _cpu_cache {
		delete(m.vertices)
		delete(m.indices)
		delete(m.submeshes)
	}
	delete(_cpu_cache)
	_cpu_cache = nil
}

// --- subdivision ------------------------------------------------------------------

@(private = "file")
_midpoint :: proc(a, b: gfx.Vertex) -> (m: gfx.Vertex) {
	m.position = (a.position + b.position) * 0.5
	m.uv       = (a.uv + b.uv) * 0.5
	m.uv2      = (a.uv2 + b.uv2) * 0.5
	m.normal   = (a.normal + b.normal) * 0.5
	m.tangent  = (a.tangent + b.tangent) * 0.5
	if m.normal != {} do m.normal = linalg.normalize(m.normal)
	if m.tangent.xyz != {} do m.tangent.xyz = linalg.normalize(m.tangent.xyz)
	for k in 0 ..< 4 do m.color[k] = u8((u32(a.color[k]) + u32(b.color[k]) + 1) / 2)
	return
}

// Splits a triangle along its longest edge until no edge is longer than
// sqrt(max_sq), appending the pieces to `out` (three vertices a triangle).
@(private = "file")
_subdivide_triangle :: proc(out: ^[dynamic]gfx.Vertex, a, b, c: gfx.Vertex, max_sq: f32, depth: int) {
	ab := linalg.length2(b.position - a.position)
	bc := linalg.length2(c.position - b.position)
	ca := linalg.length2(a.position - c.position)

	if (ab <= max_sq && bc <= max_sq && ca <= max_sq) || depth >= 16 {
		append(out, a, b, c)
		return
	}

	if ab >= bc && ab >= ca {
		m := _midpoint(a, b)
		_subdivide_triangle(out, a, m, c, max_sq, depth + 1)
		_subdivide_triangle(out, m, b, c, max_sq, depth + 1)
	} else if bc >= ca {
		m := _midpoint(b, c)
		_subdivide_triangle(out, a, b, m, max_sq, depth + 1)
		_subdivide_triangle(out, a, m, c, max_sq, depth + 1)
	} else {
		m := _midpoint(c, a)
		_subdivide_triangle(out, a, b, m, max_sq, depth + 1)
		_subdivide_triangle(out, m, b, c, max_sq, depth + 1)
	}
}

// --- baking -----------------------------------------------------------------------

// The vertex colour a lit vertex stores: the lights' sum times the vertex's own
// colour, halved (the shader doubles it back, overbright's 2x range).
@(private = "file")
_baked_color :: proc(lights: []Light, position, normal: [3]f32, base: [4]u8) -> [4]u8 {
	light := light_at(lights, position, normal)
	c := [4]f32{light.r, light.g, light.b, 1}
	c *= [4]f32{f32(base.r), f32(base.g), f32(base.b), f32(base.a)} / 255
	c.rgb *= 0.5
	return {
		u8(clamp(c.r, 0, 1) * 255 + 0.5),
		u8(clamp(c.g, 0, 1) * 255 + 0.5),
		u8(clamp(c.b, 0, 1) * 255 + 0.5),
		u8(clamp(c.a, 0, 1) * 255 + 0.5),
	}
}

// --- batches ----------------------------------------------------------------------

// One merged mesh: everything in the level that draws with one material and
// tint, in world space with its lighting in the vertex colours.
Batch :: struct {
	mesh: gfx.Mesh,
	tex:  ^gfx.Texture,
	tint: [4]f32,
	cull: gfx.Cull,
}

@(private = "file")
_Group_Key :: struct {
	material: engine.Asset_GUID,
	tint:     [4]u32,
}

@(private = "file")
_Group :: struct {
	resolved: Resolved_Material,
	tint:     [4]f32,
	vertices: [dynamic]gfx.Vertex,
	indices:  [dynamic]u32,
}

@(private = "file")
_static: struct {
	signature: u64,
	built:     bool,
	batches:   [dynamic]Batch,
}

// The merged world-space meshes of the BAKED and UNLIT renderers in `items`,
// built when anything they depend on changed since the last call.
static_batches :: proc(items: []Item, subdivision: f32) -> []Batch {
	context.allocator = runtime.default_allocator()

	sig := _signature(items, subdivision)
	if _static.built && _static.signature == sig do return _static.batches[:]

	_static_destroy()
	groups := make(map[_Group_Key]int, context.temp_allocator)
	order  := make([dynamic]_Group, context.temp_allocator)

	for item in items {
		if item.lighting == .LIVE || item.blend != .OPAQUE || !item.loadable do continue
		cpu, ok := cpu_mesh(item.mesh, item.part)
		if !ok do continue
		_add_item(&order, &groups, item, cpu, item.lighting == .BAKED, subdivision)
	}

	for &g in order {
		if len(g.indices) == 0 do continue
		mesh := gfx.mesh_create(g.vertices[:], g.indices[:])
		if mesh.index_count == 0 {
			log.errorf("[PSX] could not upload a batch of %d vertices", len(g.vertices))
			continue
		}
		append(&_static.batches, Batch{mesh = mesh, tex = g.resolved.tex, tint = g.tint, cull = g.resolved.cull})
	}
	for &g in order {
		delete(g.vertices)
		delete(g.indices)
	}

	_static.signature = sig
	_static.built = true
	return _static.batches[:]
}

@(private = "file")
_add_item :: proc(order: ^[dynamic]_Group, groups: ^map[_Group_Key]int, item: Item, cpu: ^Cpu_Mesh, bake: bool, subdivision: f32) {
	g := item.grid
	if g == nil {
		_add_geometry(order, groups, item, item.model, cpu, bake, subdivision)
		return
	}
	// A grid: every cell is the mesh through the object's transform, moved along
	// the object's own X and Z and turned a quarter turn at a time.
	for row in 0 ..< max(g.rows, 1) {
		for column in 0 ..< max(g.columns, 1) {
			offset := linalg.matrix4_translate_f32({f32(column) * g.spacing.x, 0, f32(row) * g.spacing.y})
			turn := linalg.matrix4_rotate_f32(f32(tile_quarter_turns(g, column, row)) * (math.PI / 2), {0, 1, 0})
			_add_geometry(order, groups, item, item.model * offset * turn, cpu, bake, subdivision)
		}
	}
}

@(private = "file")
_add_geometry :: proc(order: ^[dynamic]_Group, groups: ^map[_Group_Key]int, item: Item, model: matrix[4, 4]f32, cpu: ^Cpu_Mesh, bake: bool, subdivision: f32) {
	m := model
	upper := matrix[3, 3]f32{
		m[0, 0], m[0, 1], m[0, 2],
		m[1, 0], m[1, 1], m[1, 2],
		m[2, 0], m[2, 1], m[2, 2],
	}
	det := linalg.determinant(upper)
	normal_matrix := linalg.MATRIX3F32_IDENTITY
	if abs(det) > 1e-12 do normal_matrix = linalg.transpose(linalg.inverse(upper))
	mirrored := det < 0

	// The mesh's vertices in world space, once, for all its submeshes.
	world := make([]gfx.Vertex, len(cpu.vertices), context.temp_allocator)
	for v, i in cpu.vertices {
		w := v
		p := m * [4]f32{v.position.x, v.position.y, v.position.z, 1}
		w.position = p.xyz
		n := normal_matrix * v.normal
		w.normal = n != {} ? linalg.normalize(n) : n
		world[i] = w
	}

	scratch := make([dynamic]gfx.Vertex, 0, 64, context.temp_allocator)
	max_sq := subdivision * subdivision

	for sub, si in cpu.submeshes {
		material: engine.Asset_GUID
		if si < len(item.materials) do material = item.materials[si]

		key := _Group_Key{material = material, tint = {transmute(u32)item.tint.r, transmute(u32)item.tint.g, transmute(u32)item.tint.b, transmute(u32)item.tint.a}}
		gi, seen := groups[key]
		if !seen {
			gi = len(order)
			groups[key] = gi
			resolved := resolve_material(material)
			append(order, _Group{resolved = resolved, tint = item.tint * resolved.color})
		}
		g := &(order^)[gi]

		first := int(sub.first_index)
		last  := min(first + int(sub.index_count), len(cpu.indices))
		for t := first; t + 2 < last; t += 3 {
			a, b, c := world[cpu.indices[t]], world[cpu.indices[t + 1]], world[cpu.indices[t + 2]]
			if mirrored do b, c = c, b // a mirrored transform turns the winding around

			clear(&scratch)
			if subdivision > 0 {
				_subdivide_triangle(&scratch, a, b, c, max_sq, 0)
			} else {
				append(&scratch, a, b, c)
			}

			base := u32(len(g.vertices))
			for &v, k in scratch {
				v.color = bake ? _baked_color(state.lights[:], v.position, v.normal, v.color) : {255, 255, 255, 255}
				append(&g.vertices, v)
				append(&g.indices, base + u32(k))
			}
		}
	}
}

@(private = "file")
_feed :: proc(h: ^u64, value: ^$T) {
	h^ = hash.fnv64a(mem.ptr_to_bytes(value), h^)
}

@(private = "file")
_signature :: proc(items: []Item, subdivision: f32) -> u64 {
	h := u64(0xcbf29ce484222325)
	sub := subdivision
	version := state.lights_version
	_feed(&h, &sub)
	_feed(&h, &version)
	for &item in items {
		if item.lighting == .LIVE || item.blend != .OPAQUE do continue
		_feed(&h, &item.owner)
		_feed(&h, &item.mesh)
		_feed(&h, &item.part)
		_feed(&h, &item.model)
		_feed(&h, &item.lighting)
		_feed(&h, &item.tint)
		_feed(&h, &item.loadable)
		if g := item.grid; g != nil {
			_feed(&h, &g.columns)
			_feed(&h, &g.rows)
			_feed(&h, &g.spacing)
			_feed(&h, &g.random_rotation)
			_feed(&h, &g.seed)
			h = hash.fnv64a(g.turns[:], h)
		}
		for &mat in item.materials do _feed(&h, &mat)
	}
	return h
}

@(private = "file")
_static_destroy :: proc() {
	for &b in _static.batches do gfx.mesh_destroy(&b.mesh)
	clear(&_static.batches)
	_static.built = false
}

batches_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	_static_destroy()
	delete(_static.batches)
	_static = {}
}
