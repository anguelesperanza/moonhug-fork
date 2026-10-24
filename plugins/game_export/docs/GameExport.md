---
title: "Game Export"
description: "Staging and packaging a game as a program that runs outside the repository, and the start-up its main needs, with the Windows problems of the engine's player and export it works around"
order: 30
tags: ["build", "plugins", "windows"]
---

A game is a **runnable package** (its root declares `main`) with a run configuration (`run_configs/run.odin`). The engine's `rc.play` builds it, stages `builds/<name>_data` and runs it from the repository. This plugin adds what is needed to ship it: a folder to copy anywhere.

## Using it in a game

The game's `main`, first thing:

```odin
import "moonhug:packages/game_export"

main :: proc() {
	game_export.prepare_standalone()
	// ... the game's window settings ...
	__standalone_run()
}
```

The game's run configuration (a single-file program, `run_configs/run.odin`):

```odin
package run

import rc "moonhug:editor/runconfig"
import tool "moonhug:packages/game_export/runtool"

SCENE :: "packages/mygame/assets/boot.scene"

main :: proc() {
	cfg := rc.Config{package_path = "moonhug/packages/mygame", out = "builds/mygame"}
	if rc.dev_run() do rc.play(cfg, SCENE)                 // the quick loop, no export
	if _, ok := rc.build(cfg); !ok do rc.exit_build_failed(cfg.package_path)
	if !tool.export_data(cfg.out, SCENE) do rc.exit_build_failed("builds/mygame data")
	if !tool.package_dist(cfg.out, "moonhug/packages/mygame/README.txt") do rc.exit_build_failed("the packaged build")
	rc.run_build(cfg.out)
}
```

Run it with `odin run moonhug/packages/mygame/run_configs/run.odin -file -collection:moonhug=moonhug -out:builds/mygame_run.exe`. The result is `builds/mygame_dist/`: the program, its data, the SDL libraries it loads (on Windows, copied from the Odin installation that built it), the two empty folders the player looks for, and the README if one was named. Add `-- --build-only` to stop before running.

## What it works around

| Problem in the engine | Fix |
|---|---|
| On Windows the editor's catalog spells paths with `\`, and `catalog.export_from` makes a copy's folders by splitting at `/`, so the export fails with "cannot copy" | `runtool.export_data` exports from a copy of the catalog spelled with `/` |
| A program started bare looks for `<program>.exe_data` and the export writes `<name>_data` | `prepare_standalone` passes `--catalog=` for the folder beside it |
| The player panics unless a folder holding `assets` and `ProjectSettings` is at or above its working directory, which is any folder at all for a shortcut | `package_dist` keeps the two empty folders, and `prepare_standalone` anchors at the program's own folder when there is none |
| `mh play` names its output without `.exe` on Windows | use the `odin run` command above |

If the engine's own export and player are fixed, the game's `main` and run configuration can go back to `rc.play` and `game_export` can be removed.

## Limits

The SDL libraries are copied only on Windows, and only from the Odin vendor folders (`sdl3`, `sdl3/mixer`): a game that links something else ships it itself. Nothing here is signed or installed; the output is a plain folder.
