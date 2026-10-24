---
title: "PSX Renderer"
description: "A PlayStation 1 look for MoonHug: vertex snapping, affine texturing, baked vertex lighting, 15-bit dithering, fog and CRT effects, as a render slot a camera draws through"
order: 20
tags: ["rendering", "plugins", "psx"]
---

The psx plugin is the rendering half of the psx-framework, ported from raylib to MoonHug. A Camera whose `slot` is `Psx` draws through three render steps instead of the engine's PBR frame, and everything the framework did to a picture to make it look like a PS1 happens in them.

```
scene (MeshRenderers, PsxTileGrids, lights)
   |  psx_scene     low-res HDR frame: vertex snapping, affine textures, baked or live
   |                vertex lighting, fog, 15-bit colour + 4x4 dither, colour key;
   |                semi-transparent objects through a layer and a composite; FRAME text
   |  psx_post      interlacing: one field of the frame redrawn a frame
   v  psx_present   the camera's target: 4:3 bars or stretch, nearest sampling,
                    CRT blur / scanlines / curvature / mask / vignette; SCREEN text
```

## Using it

1. Put a **PsxView** on the camera object and set the Camera's `slot` to `Psx`. PsxView holds the look: resolution, video mode, aspect, vertex snapping, texture mode, colour depth, dithering, colour key, overbright, fog, draw distance, subdivision and the CRT effects. Edit it in the inspector; the game's `psx.set_*` procs change the same component.
2. Meshes are the engine's: **MeshFilter + MeshRenderer**, one Material per submesh, whose `texture` is what the PSX shader samples (nearest, repeating, no mip levels). A **PsxRenderer** next to them picks the lighting (BAKED for level geometry, LIVE for things that move, UNLIT), a tint and a blend mode.
3. Lights are **PsxLight** (directional, point, spot, area rect and disk) and the ambient is a **PsxEnvironment**. `psx_level.apply_lighting` hands both to the renderer.
4. A **PsxTileGrid** draws a grid of one mesh from a single object: a floor of a thousand tiles costs one object, which matters because MoonHug's pools hold 1024 objects a world.

The slot is added to the active render pipeline in memory when a camera first asks for it (`slot_ensure`), so no project setting or `.renderpipeline` asset changes. A camera on the engine's own slots is unaffected.

## How the look is made

| Feature | Where |
|---|---|
| Low render resolution (256x240 .. 640x480), nearest upscale, 4:3 / stretch / widescreen | `frame_size`, `display_rect`, `psx_present` |
| Vertex snapping | `psx.vert.glsl`: positions land on whole pixels of the frame |
| Affine texture mapping | `noperspective` varying in `psx.vert.glsl`, chosen in `psx.frag.glsl` |
| Fog per vertex, draw distance | `psx.vert.glsl` computes it from clip w; the far plane is `draw_distance` |
| Baked vertex lighting (Gouraud) | `psx_mesh.odin`: lights folded into vertex colours when the level first draws |
| Live lighting for moving objects | `psx_lighting.odin`: the three strongest lights per object, per-vertex normal in `psx.frag.glsl` |
| Overbright (2x lighting), 15-bit colour, 4x4 ordered dither | `psx.frag.glsl` |
| Colour-key transparency | `psx.frag.glsl` |
| Semi-transparency: half, add, subtract, quarter add | a layer pass and `psx_composite.frag.glsl` |
| Interlacing | `psx_interlace.frag.glsl`, a persistent display target |
| CRT: blur, scanlines, curvature, vignette, aperture grille | `psx_present.frag.glsl` |
| Polygon subdivision | `psx_mesh.odin`, at bake time, in world space |
| Frame rate cap (NTSC 30, PAL 25) | `psx_frame_limit`, standalone player only |
| Text in the frame or over the screen | `render_text`, the engine's 8x8 font |
| Screenshots of the final frame | `request_screenshot`, `--psx-shot=` |

### The shaders

`shaders/*.glsl` compile offline to `shaders/compiled/*.spv` and `.msl` with `shaders/compile_shaders.sh` (glslc and spirv-cross, the way `mh shaders` does the engine's), and are embedded with `#load`. Registering them needs a GPU device, so it happens the first frame a camera draws (`shaders_ensure`). The engine's vertex stage is fixed (one uniform block), so the PSX vertex shader reads its settings from the model matrix's bottom row (always 0 0 0 1 for an affine transform): the frame's size for snapping and the fog range (`psx_render.odin`, `_carrier`).

### Colour

The frame holds raw display values, what a PS1 would write to its framebuffer, not linear light: nothing between the scene shader and the present shader converts colour, because the PS1 lit and blended in gamma space. The present shader's output goes through the sRGB decode once because ending a pass on a Display target encodes it again, which makes the window show exactly the bytes the shaders computed.

## Differences from the raylib framework

- **Lighting is per fragment where the original was per vertex, for moving objects.** Baked level lighting is per vertex exactly as before. Live lighting needs light data in the vertex stage, which the engine's fixed vertex contract has no room for, so the fragment shader works the three lights out from the interpolated normal. On a cube the two are identical; on a rounded model the shading is smoother than the PS1's.
- **The ambient and the overbright clamp are applied after interpolation**, not before. Constant ambient is linear, so it is identical; the clamp at 2.0 differs only where a triangle's lighting crosses it.
- **Text is the engine's 8x8 bitmap font**, not raylib's default font, and colours other than white and black are darkened by the engine's colour decode in the vertex stage.
- **ORBITAL camera mode** circles the origin at 0.5 rad/s as raylib's did, but is not used by the demo.
- **Skinned meshes are not drawn** by the PSX frame (the original had no animation either).
- **Scene view**: the editor's scene view draws with the engine's own pipeline; the Game view and the standalone player draw the PSX frame. A PsxTileGrid appears only in the PSX frame.
