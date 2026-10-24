package psx

import "moonhug:packages/engine"

// A grid of one mesh drawn from a single object: a floor of wooden tiles, a
// wall of bricks. MoonHug's pools hold 1024 objects a world, and the
// framework's testbed level had 2749 (its floor alone was 42 by 30 tiles with
// duplicates stacked on them), so a tiled floor is one object with a grid of
// cells instead of a thousand objects.
//
// Cell (column, row) is the mesh placed at `column * spacing.x` along the
// object's X and `row * spacing.y` along its Z, from the object's own
// position, so the object marks the first cell's centre. The cells bake into
// the level's geometry like any other BAKED mesh. A grid has no MeshFilter and
// is not drawn in the editor's scene view (only in the PSX frame), and a
// collider for it is the level author's: one BoxCollider over the whole floor
// does the job of every tile's.
@(component={menu="PSX/PsxTileGrid"})
@(typ_guid={guid = "6f04a0a6-1b09-4d6d-9b35-7c19e8e8d27c"})
PsxTileGrid :: struct {
	using base: engine.CompData `inspect:"-"`,
	mesh:      engine.Asset_GUID `ext:"glb,gltf"`,
	// One Material per submesh of the mesh, as on a MeshRenderer.
	materials: [dynamic]engine.Asset_GUID `ext:"mat" expand`,
	columns:   i32 `decor:min(1)`,
	rows:      i32 `decor:min(1)`,
	// Metres between cell centres, along the object's X and Z.
	spacing:   [2]f32,
	// Each cell is turned a whole number of quarter turns about Y: `turns`
	// names them (row by row, `columns * rows` of them, each 0 to 3) when it has
	// the right length, else `random_rotation` picks them by a hash of the cell's
	// place and `seed`, a floor of one texture that does not repeat in rows.
	turns:     [dynamic]u8,
	random_rotation: bool,
	seed:      u32,
}

cleanup_PsxTileGrid :: proc(g: ^PsxTileGrid) {
	delete(g.materials)
	delete(g.turns)
	engine.comp_zero(g)
}

reset_PsxTileGrid :: proc(g: ^PsxTileGrid) {
	g.columns = 1
	g.rows = 1
	g.spacing = {1, 1}
	g.random_rotation = false
	g.seed = 0
}

// The quarter turns (0 to 3) a cell is rotated by.
tile_quarter_turns :: proc(g: ^PsxTileGrid, column, row: i32) -> u32 {
	if len(g.turns) == int(g.columns * g.rows) do return u32(g.turns[row * g.columns + column]) & 3
	if !g.random_rotation do return 0
	h := u32(column) * 73856093 ~ u32(row) * 19349663 ~ g.seed * 83492791
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return h & 3
}
