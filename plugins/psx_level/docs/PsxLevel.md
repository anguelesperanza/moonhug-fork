---
title: "PSX Levels"
description: "Named spawn points and trigger shapes in a level scene, and gathering a level's lights for the PSX renderer"
order: 23
tags: ["levels", "plugins", "psx"]
---

A PSX level is a MoonHug scene. Meshes and colliders are the engine's and physics3d's own components. What the framework's Stargate importer added on top is here:

- **PsxEntity**: a named place with a shape. `POINT` is a spawn (`player_spawn`), `BOX` (half extents, scaled and turned by the transform) and `SPHERE` (a radius in `size.x`) are trigger zones. The name is the object's own. `find_entity(name, scene)`, `entity_position`, `entity_facing` and `entity_contains` are the queries the demo's door uses.
- **PsxLight** and **PsxEnvironment** (in the psx plugin) are the level's lights and ambient. `collect_lighting(scene)` gathers them in world space; `apply_lighting(scene)` hands them to the renderer and switches lighting on when the level has lights and its environment enables it.

Levels load additively next to a persistent scene (the player, the camera), and every query takes the level's `^engine.Scene`, so the persistent scene's own lights and entities are not mixed in.

Converting a Stargate level: `plugins/psx_demo/tools/stargate_to_scene.py` (see the psx_demo page).
