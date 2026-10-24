# Changes on `windows-fixes-and-psx`

Based on `main` at v0.143.0. Eight commits, none touching `CHANGELOG.md`, which the release tooling writes.

## Fixes

### Lighting works on Windows (`cdf5fa7`)
SDL 3.4.2's Vulkan GPU backend binds every uniform buffer with a 4096-byte range and reads past it as zero. The cluster uniform was about 21 KB, so the light list read as zero: lights did nothing and only ambient showed.
- `MAX_LIGHTS` 256 -> 24, with one `uvec4` of light bits per tile instead of two.
- `#assert(size_of(_Cluster_Uniform) <= 4096)` keeps it under the limit.
- `surface.glsl` and the compiled `lit.frag`, `caster.frag` and `skin.comp` shaders rebuilt to match.
- Known limit: the light UBO has the same cap, so spot and point shadows are lost (use Shadows None on them). Directional cascade shadows work. A storage buffer for the light list would lift both limits.

### `draw_fullscreen` copies what it queues (`6c2de1c`)
The draw is read at `pass_end`, after the caller's frame is gone, but it kept the caller's stack slices and texture pointers. The inputs and the material are now copied into the temp allocator. This clears the 26 "may keep a reference to the stack memory" compiler warnings (ssao, ssr, taa, sky, postfx, gfx).

### Importer extensions and unused hooks (`2649b79`)
- The animation importer's `extensions` is a package-level slice. An inline literal handed to `importer_register` dangled after the registering proc returned.
- The six engine hooks no game uses yet (`comp_update`, `comp_late_update`, `comp_on_collision_enter/exit`, `comp_on_trigger_enter/exit`) are marked `@(reserved)`, so the prebuild stops warning about them.
- Not changed: the shadergraph importer has the same inline `{".shadergraph"}`.

### Relaunch works on Windows (`ce38545`)
Two file locks made the editor's Relaunch button fail with `mh exit 13`:
- `odin run tools/mh` could not overwrite `mh.exe`, which is the editor's running parent. Relaunch now builds `mh_relaunch_<pid>.exe` in the repo root (gitignored) and sweeps the old ones.
- The linker could not overwrite the running `builds/MoonHug.exe`. On Windows `mh` now renames the running editor aside for the build, restores it if the build fails, and deletes it after the editor exits.

### Smaller (`f13d0ec`)
- `log.odin`: removed an unused `import "core:c"`.
- `tools/mh/proc_windows.odin`: `process_alive` uses the Win32 `OpenProcess` call.

## Additions

### psx plugins and game_export (`00d9602`)
`psx`, `psx_camera`, `psx_controls`, `psx_level`, `psx_demo` and `game_export`, with their package links. The demo script and screenshot arguments parse with `strconv.parse_int` and `parse_f64` instead of the deprecated `atoi` and `atof`.

### mygame and the postfx link (`d5f91fa`)
The `mygame` plugin (a first-person test scene with a sun and a flashlight) and the `moonhug/packages/postfx` link.

### Config (`7e26f4e`)
`ols.json` knows the `moonhug` collection, and `plugins/app/mh_plugin.json` lists `physics3d`. Both are what `mh setup` writes.

## Not changed
Nothing was changed for the microui question or the run button, which were answered without edits.
