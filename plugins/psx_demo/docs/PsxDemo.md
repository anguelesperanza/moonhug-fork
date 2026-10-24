---
title: "PSX Demo"
description: "The psx-framework's demo as a MoonHug game: three levels, tank controls, fixed and drag cameras, every look toggle on a key, exportable as a stand-alone program"
order: 24
tags: ["demo", "plugins", "psx"]
---

The demo is the framework's `main.odin` as a game made of plugins. It is a **runnable package** (its root declares `main`), so it exports as a program of its own, separate from the app plugin's game.

## Playing it

From the editor: open `packages/psx_demo/assets/psx_demo.scene` and look at the Game view, which draws the PSX frame in edit mode too. The run configurations are `packages/psx_demo/run_configs/run.odin` and `run_debug.odin`.

From a terminal, at the repository root:

```
odin run moonhug/packages/psx_demo/run_configs/run.odin -file -collection:moonhug=moonhug -out:builds/psx_demo_run.exe
```

builds the game, stages `builds/psx_demo_data`, assembles `builds/psx_demo_dist/` and runs it. Add `-- --build-only` to stop after assembling, `-- --dev` to play against the editor's live catalog without an export (the quick loop). On Windows `mh play psx_demo:run` names its output without `.exe` and the compiler refuses it, so use the command above.

`builds/psx_demo_dist/` is the whole game: copy it anywhere and run `psx_demo.exe`. It needs nothing installed.

### Keys

| | | | |
|---|---|---|---|
| WASD / arrows | move and turn | H | hide the key list |
| N | next level | R | recentre the drag camera |
| V | vertex snapping | T | affine / perspective textures |
| G | subdivision | L | lighting |
| B | dim ambient | O | overbright |
| C | 15 / 24-bit colour | X | dithering |
| F | draw distance and fog | K | colour key |
| M | player blend mode | P | CRT effects |
| Y | CRT overscan | I | interlaced video mode |
| U | interlacing | TAB | widescreen |
| F11 | fullscreen | F12 | screenshot |

The door in the house: walk into the zone at the end of the corridor facing it.

## What it is made of

| | |
|---|---|
| `assets/psx_demo.scene` | the persistent scene: the camera (Camera with slot `Psx`, PsxView, PsxCameraRig), the player (Rigidbody, capsule, PsxCharacter, a cube model) and the `Demo` object |
| `assets/levels/*.scene` | the testbed, house and bedroom, converted from the framework's Stargate levels |
| `assets/models/scenery/` | the framework's models and their textures, with a Material per submesh |
| `component_PsxDemo.odin` | the level swapper, the debug keys and the key list |
| `component_PsxDemoPlayer.odin` | the player's body offsets and speed |
| `run_configs/`, `README.txt` | the run configurations, and the readme the packaged build carries |
| `tools/stargate_to_scene.py` | the level converter |

### Packaging

The run configurations and `main` use the [game_export](../../game_export/docs/GameExport.md) plugin, which stages and packages the build and works around three problems in the engine's Windows player and export. A second game uses it the same way.

## Porting the levels

`tools/stargate_to_scene.py` reads a Stargate level (`levels/*.json`) and writes the same level as a scene:

| Stargate | MoonHug |
|---|---|
| model | MeshFilter + MeshRenderer, a Material per submesh in the importer's order |
| box collider (half extents) | BoxCollider (full size) |
| light | PsxLight |
| shape / named empty | PsxEntity |
| camera, zone, `track` marker | PsxCameraShot on the lens, bounds in world space |
| lighting settings | PsxEnvironment |
| a complete grid of one model | PsxTileGrid, with the original tile turns |

`prepare` copies the models and writes their textures; open the editor once so it mints the asset ids; `levels` and `boot` write the scenes.

The testbed has 2749 objects, more than MoonHug's pools hold (1024 transforms and mesh components a world). Its floor is two 42 x 30 tile grids with extra tiles stacked on them, which become two PsxTileGrid objects and one collider each (the visible tile of every cell is kept, with its original turn), and exact duplicate objects are dropped. The level has 29 objects.

## How close it is

The framework's own screenshots (the original raylib build, taken after 150 frames at 1920x1080) against this game's, compared pixel by pixel over the half of the image with no text:

| Level | Identical | Within 8 of 255 | Mean difference |
|---|---|---|---|
| house | 95.0 % | 98.9 % | 0.40 |
| bedroom | 88.3 % | 99.3 % | 0.48 |
| testbed | 83.9 % | 96.3 % | 0.90 |
| house, exported and run from another folder | 94.9 % | 98.9 % | 0.49 |

What differs is the dither and rounding at a few edges and the testbed's duplicate stacked tiles. The text is not compared: it is drawn in the engine's 8x8 font rather than raylib's.

## Checking without a keyboard

`--demo-script=` takes events at frames of the demo's own count: `30:N` presses N, `40-100:W` holds W, `50:tp=1/0/2` puts the player at x y z, `60:drag` switches to the drag camera. With `--psx-shot=<file.png>` (and `--psx-shot-frames=<n>`) the game saves its own frame and quits, which is how the table above was made.
