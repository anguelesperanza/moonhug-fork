#!/usr/bin/env python
"""Converts the psx-framework's Stargate levels into MoonHug scenes.

The framework's levels were made in Stargate, the author's own level editor
(levels/*.json). MoonHug has a level editor of its own, so a port only needs
the *content*: this script reads a Stargate level and writes the same level as
a .scene, using the PSX plugins' components:

    model        -> MeshFilter + MeshRenderer (one Material per submesh)
    collider     -> physics3d BoxCollider (Stargate sizes are half extents)
    light        -> PsxLight
    shape        -> PsxEntity            (spawns and triggers)
    camera group -> PsxCameraShot        (the lens object, bounds in world space)
    settings     -> PsxEnvironment

It is a one-off: run it once per level, then edit the result in MoonHug.

Two steps, because MoonHug mints an asset's guid when it first sees the file:

    python stargate_to_scene.py prepare <psx-framework dir>
        copies the models into assets/models and writes each embedded texture
        and its Material next to it. Open the editor (or run any build) once
        so it writes the .meta files.
    python stargate_to_scene.py levels <psx-framework dir>
        reads those guids and writes assets/levels/<name>.scene.
"""

import base64
import json
import math
import os
import random
import shutil
import struct
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
ASSETS = os.path.join(PLUGIN, "assets")
MODELS = os.path.join(ASSETS, "models", "scenery")
LEVELS = os.path.join(ASSETS, "levels")

# Component guids (the @(typ_guid) of each type).
T_MESH_FILTER = "32f52908-51a9-4f3b-819b-fc9d8cbc5972"
T_MESH_RENDERER = "73e161a0-c599-4cfb-9826-447e05baa76c"
T_CAMERA = "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"
T_BOX_COLLIDER = "13101cd5-e0a6-49d4-a310-953001ebae6b"
T_PSX_LIGHT = "ad2fa191-af25-4324-b853-1352c65c533c"
T_PSX_ENVIRONMENT = "5bdf6d7c-4cf9-42c5-9408-ee32b034b656"
T_PSX_ENTITY = "cfee3376-60b0-4c31-8e59-b966433fbd86"
T_PSX_CAMERA_SHOT = "17bbeb0d-554f-41f3-adca-3023712c9ad6"
T_MATERIAL = "4d201ba5-2097-48bb-abd3-1a79e4f6f6f4"
T_RIGIDBODY = "82976d39-c450-4464-87e2-c260c430c157"
T_CAPSULE_COLLIDER = "91ddc047-6a91-4142-bc9c-d219570192b6"
T_PSX_VIEW = "37c12555-5059-4c1c-a0ec-da1227a4e6a6"
T_PSX_RENDERER = "532f96ae-2e44-42ca-895a-69bd97ce1df6"
T_PSX_CAMERA_RIG = "91da62d8-b2dd-4122-9e40-9394d01c033e"
T_PSX_CHARACTER = "d3b0b537-78a1-4168-a953-a22580550825"
T_PSX_TILE_GRID = "6f04a0a6-1b09-4d6d-9b35-7c19e8e8d27c"
T_PSX_DEMO = "a9fb93d4-1e86-4a89-ba27-307c8b704206"
T_PSX_DEMO_PLAYER = "220db10a-b355-4524-9c59-9b310c2bf5ff"

# essentials' unit cube (plugins/essentials/assets/meshes/Cube.glb).
CUBE_MESH = "9b978885-12f8-4d30-be4d-d9c2c2074477"

ZERO_GUID = "00000000-0000-0000-0000-000000000000"


# --- glTF ---------------------------------------------------------------------

def load_gltf(path):
    """Returns (json, binary chunk or None) of a .glb or .gltf."""
    if path.endswith(".glb"):
        data = open(path, "rb").read()
        offset, js, binary = 12, None, None
        while offset < len(data):
            length, kind = struct.unpack("<II", data[offset:offset + 8])
            chunk = data[offset + 8:offset + 8 + length]
            offset += 8 + length
            if kind == 0x4E4F534A:
                js = json.loads(chunk)
            elif kind == 0x004E4942:
                binary = chunk
        return js, binary
    js = json.load(open(path))
    binary = None
    buffers = js.get("buffers", [])
    if buffers and buffers[0].get("uri", "").startswith("data:"):
        binary = base64.b64decode(buffers[0]["uri"].split(",", 1)[1])
    return js, binary


def image_bytes(js, binary, image):
    if "uri" in image:
        return base64.b64decode(image["uri"].split(",", 1)[1])
    view = js["bufferViews"][image["bufferView"]]
    start = view.get("byteOffset", 0)
    return binary[start:start + view["byteLength"]]


def submesh_materials(js):
    """The model's glTF material indices in the order MoonHug's mesh importer
    makes submeshes: nodes in file order, primitives in order, one submesh per
    material at its first appearance (None is 'no material')."""
    order = []
    for node in js.get("nodes", []):
        if "mesh" not in node:
            continue
        for prim in js["meshes"][node["mesh"]]["primitives"]:
            m = prim.get("material")
            if m not in order:
                order.append(m)
    return order


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as f:
        json.dump(value, f, indent=2)
        f.write("\n")


def meta_guid(path):
    meta = path + ".meta"
    if not os.path.exists(meta):
        return None
    return json.load(open(meta))["guid"]


def ensure_meta(path):
    """Writes a minimal meta for a file this script made, if it has none."""
    meta = path + ".meta"
    if os.path.exists(meta):
        return json.load(open(meta))["guid"]
    guid = str(uuid.uuid4())
    write_json(meta, {"guid": guid})
    return guid


# --- step 1: models, textures, materials --------------------------------------------

def prepare(source):
    scenery = os.path.join(source, "assets", "models", "scenery")
    os.makedirs(MODELS, exist_ok=True)
    for name in sorted(os.listdir(scenery)):
        if not name.endswith((".glb", ".gltf")):
            continue
        shutil.copy(os.path.join(scenery, name), os.path.join(MODELS, name))
        js, binary = load_gltf(os.path.join(scenery, name))
        stem = os.path.splitext(name)[0]

        # Embedded images become plain files beside the model, as the editor's
        # Extract Assets does.
        files = []
        for i, image in enumerate(js.get("images", [])):
            label = None
            for t in js.get("textures", []):
                if t.get("source") == i and t.get("name"):
                    label = os.path.splitext(t["name"])[0]
            ext = "png" if image.get("mimeType", "image/png").endswith("png") else "jpg"
            file = "%s_%s.%s" % (stem, label or i, ext)
            with open(os.path.join(MODELS, file), "wb") as f:
                f.write(image_bytes(js, binary, image))
            files.append(file)
        print(name, "->", len(files), "textures")
    print("now open the editor once so it writes the .meta files, then run: levels")


def write_materials(source):
    """One Material per submesh of every model, textured with the glTF material's
    base colour texture. Written after the editor minted the texture guids."""
    scenery = os.path.join(source, "assets", "models", "scenery")
    table = {}  # model file name -> [material guid per submesh]
    for name in sorted(os.listdir(MODELS)):
        if not name.endswith((".glb", ".gltf")):
            continue
        js, _ = load_gltf(os.path.join(MODELS, name))
        stem = os.path.splitext(name)[0]
        image_file = {}
        for i, image in enumerate(js.get("images", [])):
            label = None
            for t in js.get("textures", []):
                if t.get("source") == i and t.get("name"):
                    label = os.path.splitext(t["name"])[0]
            ext = "png" if image.get("mimeType", "image/png").endswith("png") else "jpg"
            image_file[i] = "%s_%s.%s" % (stem, label or i, ext)

        guids = []
        for m in submesh_materials(js):
            texture = ZERO_GUID
            label = "none"
            if m is not None:
                material = js["materials"][m]
                tex = material.get("pbrMetallicRoughness", {}).get("baseColorTexture")
                if tex is not None:
                    source_index = js["textures"][tex["index"]]["source"]
                    file = image_file[source_index]
                    texture = meta_guid(os.path.join(MODELS, file)) or ZERO_GUID
                    label = os.path.splitext(file)[0]
            path = os.path.join(MODELS, "%s_material_%s.mat" % (stem, label))
            # Unlit in the scene view (the PSX frame does its own lighting),
            # faces culled the way the original's GL state did.
            write_json(path, {
                "__type_guid": T_MATERIAL,
                "shader": 0,
                "custom_shader": ZERO_GUID,
                "texture": texture,
                "color": [1.0, 1.0, 1.0, 1.0],
                "alpha_clip": False,
                "alpha_cutoff": 0.5,
                "render_face": 0,
                "properties": [],
                "textures": [],
            })
            guids.append(ensure_meta(path))
        table[name] = guids
    return table


# --- step 2: levels -------------------------------------------------------------------

class Scene:
    def __init__(self):
        self.transforms = []
        self.components = []
        self.used = set()

    def lid(self):
        while True:
            value = random.randrange(1, 2 ** 52)
            if value not in self.used:
                self.used.add(value)
                return value

    def add_component(self, owner, type_guid, **fields):
        lid = self.lid()
        record = {"__type": type_guid, "base": {"enabled": True, "local_id": lid}}
        record.update(fields)
        self.components.append(record)
        owner["components"].append({"local_id": lid})
        return record

    def add_transform(self, name, position, rotation, scale, parent=None):
        lid = self.lid()
        t = {
            "local_id": lid, "name": name, "is_active": True,
            "position": position, "rotation": rotation, "scale": scale,
            "render_layer": 1,
            "parent": {"pptr": {"local_id": parent["local_id"] if parent else 0, "guid": ZERO_GUID}},
            "children": [], "components": [],
        }
        if parent:
            parent["children"].append({"pptr": {"local_id": lid, "guid": ZERO_GUID}})
        self.transforms.append(t)
        return t

    def write(self, path):
        write_json(path, {
            "root": self.transforms[0]["local_id"],
            "transforms": self.transforms,
            "nested_scenes": [], "breadcrumbs": [],
            "components": self.components,
        })


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def trs(position, rotation, scale):
    x, y, z, w = rotation
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    r = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    m = [[0] * 4 for _ in range(4)]
    for i in range(3):
        for j in range(3):
            m[i][j] = r[i][j] * scale[j]
        m[i][3] = position[i]
    m[3][3] = 1
    return m


def tile_grids(entities, by_id):
    """MoonHug's pools hold 1024 objects a world, and the testbed level has
    2749 (a 42 x 30 floor with copies stacked on its tiles). Groups of
    hundreds of the same model on a complete unit grid become one PsxTileGrid, and
    entities that are exact copies of another are dropped. A grid is a group
    (one model under one parent) of at least a hundred tiles filling a complete
    rectangle of unit cells. Returns the ids to
    leave out and the grids found."""
    skip = set()
    seen = set()
    for e in entities:
        if not (e.get("model") and e["model"].get("path")):
            continue
        t = e["transform"]
        key = (e["model"]["path"], e["parent"], tuple(round(v, 3) for v in t["position"]),
               tuple(round(v, 3) for v in t["rotation"]), tuple(round(v, 3) for v in t["scale"]))
        if key in seen and not by_id.get(e["id"], {}).get("camera"):
            skip.add(e["id"])
        seen.add(key)

    grids = []
    # Per parent: the testbed has two floor groups, one offset from the other, whose
    # tiles overlap in local coordinates.
    by_model = {}
    for e in entities:
        if e["id"] not in skip and e.get("model") and e["model"].get("path"):
            by_model.setdefault((e["model"]["path"], e["parent"]), []).append(e)
    for (path, _parent), tiles in by_model.items():
        if len(tiles) < 100:
            continue
        cells = {}
        for e in tiles:
            p = e["transform"]["position"]
            cells.setdefault((round(p[0]), round(p[2])), []).append(e)
        xs = sorted({c[0] for c in cells}); zs = sorted({c[1] for c in cells})
        y = {round(e["transform"]["position"][1], 3) for e in tiles}
        if len(cells) != len(xs) * len(zs) or len(y) != 1 or xs != list(range(xs[0], xs[-1] + 1)) or zs != list(range(zs[0], zs[-1] + 1)):
            continue
        for e in tiles:
            skip.add(e["id"])
        # The tile that shows in a cell is the last drawn of those stacked on it
        # (equal depth: the later draw wins). Its quarter turn about Y.
        turns = []
        for z in zs:
            for x in xs:
                q = cells[(x, z)][-1]["transform"]["rotation"]
                angle = math.degrees(2 * math.atan2(q[1], q[3])) if any(q) else 0.0
                turns.append(int(round(angle / 90.0)) % 4)
        grids.append({"path": path, "origin": [xs[0], y.pop(), zs[0]], "columns": len(xs), "rows": len(zs),
                      "turns": turns, "collider": tiles[0].get("collider"), "parent": tiles[0]["parent"]})
    return skip, grids


def convert_level(source_path, out_path, materials):
    level = json.load(open(source_path))
    entities = level["entities"]
    by_id = {e["id"]: e for e in entities}
    skip, grids = tile_grids(entities, by_id)

    # World matrices, to place camera lenses and zones.
    world = {}

    def resolve(e):
        if e["id"] in world:
            return world[e["id"]]
        t = e["transform"]
        scale = [s if s != 0 else 1 for s in t["scale"]]
        rotation = t["rotation"] if any(t["rotation"]) else [0, 0, 0, 1]
        local = trs(t["position"], rotation, scale)
        parent = by_id.get(e["parent"])
        world[e["id"]] = mat_mul(resolve(parent), local) if parent and parent is not e else local
        return world[e["id"]]

    for e in entities:
        resolve(e)

    scene = Scene()
    root = scene.add_transform(os.path.splitext(os.path.basename(out_path))[0], [0, 0, 0], [0, 0, 0, 1], [1, 1, 1])
    made = {}

    settings = level.get("settings", {}).get("lighting", {})
    ambient = settings.get("ambient", {})
    scene.add_component(
        root, T_PSX_ENVIRONMENT,
        lighting_enabled=bool(settings.get("enabled", False)),
        ambient_kind=1 if ambient.get("kind") == "HEMISPHERE" else 0,
        ambient_color=[c for c in ambient.get("color", [0, 0, 0, 1])],
        ambient_ground_color=[c for c in ambient.get("ground_color", [0, 0, 0, 1])],
    )

    # Entities appear in the order of the file, parents before children where
    # the file lists them so; a child listed first is attached when its parent
    # is made.
    pending = [e for e in entities if e["id"] not in skip]
    while pending:
        progressed = False
        for e in list(pending):
            parent = e["parent"]
            if parent and parent in by_id and parent not in made and parent != e["id"]:
                continue
            t = e["transform"]
            node = scene.add_transform(
                e["name"], t["position"],
                t["rotation"] if any(t["rotation"]) else [0, 0, 0, 1],
                [s if s != 0 else 1 for s in t["scale"]],
                made.get(parent, root))
            made[e["id"]] = node
            pending.remove(e)
            progressed = True
            add_components(scene, node, e, by_id, world, materials)
        if not progressed:
            raise SystemExit("a parent cycle in " + source_path)

    for grid in grids:
        add_grid(scene, grid, made.get(grid["parent"], root), materials)

    scene.write(out_path)
    print(os.path.basename(out_path), len(entities), "entities")


def add_grid(scene, grid, parent, materials):
    file = os.path.basename(grid["path"])
    guid = meta_guid(os.path.join(MODELS, file))
    columns, rows = grid["columns"], grid["rows"]
    node = scene.add_transform("tiles", grid["origin"], [0, 0, 0, 1], [1, 1, 1], parent)
    scene.add_component(node, T_PSX_TILE_GRID, mesh=guid, materials=materials.get(file, []),
                        columns=columns, rows=rows, spacing=[1.0, 1.0], turns=grid["turns"], random_rotation=False, seed=0)
    # One collider over the whole floor does what every tile's did: the tile's
    # box spans its top 1/16 m, the floor's spans all the cells.
    collider = grid["collider"]
    if collider and collider["kind"] == "BOX":
        half = [s or 0.5 for s in collider["size"]]
        offset = collider["offset"]
        scene.add_component(
            node, T_BOX_COLLIDER,
            size=[columns, half[1] * 2, rows],
            center=[(columns - 1) / 2, offset[1], (rows - 1) / 2],
            density=collider.get("density") or 1.0, is_trigger=False, layers=1,
            layer_overrides={"include": 0, "exclude": 0}, material=ZERO_GUID)


def add_components(scene, node, e, by_id, world, materials):
    model = e.get("model")
    if not model and e.get("instance"):
        pass  # the levels use no shared instances
    if model and model.get("path"):
        file = os.path.basename(model["path"])
        guid = meta_guid(os.path.join(MODELS, file))
        if guid is None:
            raise SystemExit("no meta for " + file + ": open the editor once after `prepare`")
        scene.add_component(node, T_MESH_FILTER, mesh={"guid": guid, "local_id": 0})
        scene.add_component(node, T_MESH_RENDERER, materials=materials.get(file, []), cast_shadows=0, reflections=0)

    collider = e.get("collider")
    if collider and collider["kind"] == "BOX":
        size = [max(s, 0) or 0.5 for s in collider["size"]]
        scene.add_component(
            node, T_BOX_COLLIDER,
            size=[s * 2 for s in size], center=collider["offset"],
            density=collider.get("density") or 1.0, is_trigger=False, layers=1,
            layer_overrides={"include": 0, "exclude": 0}, material=ZERO_GUID)

    light = e.get("light")
    if light:
        kinds = {"DIRECTIONAL": 0, "POINT": 1, "SPOT": 2, "AREA_RECT": 3, "AREA_DISK": 4}
        color = light.get("color") or [1, 1, 1, 1]
        if not any(color):
            color = [1, 1, 1, 1]
        spot = light["kind"] == "SPOT" and not light.get("inner_angle") and not light.get("outer_angle")
        scene.add_component(
            node, T_PSX_LIGHT,
            kind=kinds[light["kind"]], color=color,
            intensity=light.get("intensity") or 1.0, range=10.0,
            inner_angle=20.0 if spot else light.get("inner_angle", 20.0),
            outer_angle=30.0 if spot else light.get("outer_angle", 30.0))

    shape = e.get("shape")
    # An empty entity nothing hangs off is a named place (player_spawn): a POINT.
    # The static and track markers of a camera group are read into the shot.
    if (not shape and not model and not collider and not light and not e.get("camera")
            and e["name"].lower() not in ("static", "track")
            and not any(o["parent"] == e["id"] for o in by_id.values())):
        scene.add_component(node, T_PSX_ENTITY, kind=0, size=[0.5, 0.5, 0.5])
    if shape:
        size = list(shape["size"])
        if shape["kind"] == "BOX" and not any(size):
            size = [0.5, 0.5, 0.5]
        if shape["kind"] == "SPHERE" and not size[0]:
            size[0] = 0.5
        scene.add_component(node, T_PSX_ENTITY, kind={"POINT": 0, "BOX": 1, "SPHERE": 2}[shape["kind"]], size=size)

    camera = e.get("camera")
    if camera:
        add_shot(scene, node, e, camera, by_id, world)


def add_shot(scene, node, e, camera, by_id, world):
    """A lens (the camera entity) with a zone (a sibling shape) under one group
    becomes one PsxCameraShot on the lens, its bounds in world space."""
    group = by_id.get(e["parent"])
    if not group:
        return
    zone = None
    for other in by_id.values():
        if other["parent"] == group["id"] and other is not e and not other.get("camera") and other.get("shape"):
            zone = other
            break
    if not zone:
        return
    shape = dict(zone["shape"])
    size = list(shape["size"]) if any(shape["size"]) else [0.5, 0.5, 0.5]
    w = world[zone["id"]]
    xs, ys, zs = [], [], []
    if shape["kind"] == "BOX":
        for corner in range(8):
            local = [size[0] if corner & 1 == 0 else -size[0],
                     size[1] if corner & 2 == 0 else -size[1],
                     size[2] if corner & 4 == 0 else -size[2], 1]
            p = [sum(w[i][k] * local[k] for k in range(4)) for i in range(3)]
            xs.append(p[0]); ys.append(p[1]); zs.append(p[2])
        low, high = [min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)]
    else:
        centre = [w[0][3], w[1][3], w[2][3]]
        r = size[0] or 0.5
        low, high = [c - r for c in centre], [c + r for c in centre]
    track = any(o["parent"] == group["id"] and o["name"].lower() == "track" for o in by_id.values())
    scene.add_component(
        node, T_PSX_CAMERA_SHOT,
        kind=1 if track else 0, fov=camera.get("fov") or 70.0,
        bounds_min=low, bounds_max=high,
        target_offset=[0, 1, 0], track_smoothing=8.0)


def levels(source):
    materials = write_materials(source)
    os.makedirs(LEVELS, exist_ok=True)
    random.seed(1)  # the same ids every run
    for name in ("testbed", "house", "bedroom"):
        convert_level(os.path.join(source, "levels", name + ".json"), os.path.join(LEVELS, name + ".scene"), materials)
        ensure_meta(os.path.join(LEVELS, name + ".scene"))


def boot(_source):
    """The persistent scene the demo boots: the camera, the player and the
    object that swaps levels. Written once; edit it in the editor."""
    random.seed(2)
    scene = Scene()
    root = scene.add_transform("psx_demo", [0, 0, 0], [0, 0, 0, 1], [1, 1, 1])

    levels = []
    for name in ("testbed", "house", "bedroom"):
        guid = meta_guid(os.path.join(LEVELS, name + ".scene"))
        if guid is None:
            raise SystemExit("run `levels` first")
        levels.append(guid)

    demo = scene.add_transform("Demo", [0, 0, 0], [0, 0, 0, 1], [1, 1, 1], root)
    scene.add_component(demo, T_PSX_DEMO, levels=levels, first_level=0, subdivision=1.0)

    # The camera: the engine's Camera drawing through the Psx slot, the look in
    # PsxView (the demo's settings: 256x240, fog from 11 m to the 17 m draw
    # distance in the clear colour) and the rig that moves it.
    sky = [30 / 255, 50 / 255, 70 / 255, 1.0]
    camera = scene.add_transform("Camera", [0, 10, 10], [-0.38268343, 0, 0, 0.92387953], [1, 1, 1], root)
    scene.add_component(camera, T_CAMERA, order=0, fov=45.0, near_clip=0.05, far_clip=1000.0,
                        clear_color=sky, render_layer_mask=4294967295, slot="Psx")
    scene.add_component(camera, T_PSX_VIEW, resolution=0, video_mode=0, display_aspect=1, interlacing=True,
                        vertex_snapping=True, texture_mode=0, color_depth=0, dithering=True, color_key=False,
                        overbright=True, fog_start=11.0, fog_end=17.0, fog_color=sky, draw_distance=17.0,
                        subdivision=1.0,
                        post={"blur": 0.0, "scanlines": 0.0, "curvature": 0.0, "vignette": 0.0, "mask": 0.0, "overscan": False})
    scene.add_component(camera, T_PSX_CAMERA_RIG, mode=0, fov=45.0)

    # The player: a capsule body that cannot rise or turn, driven by its
    # PsxCharacter, with a 0.7 x 1.7 x 0.7 box for a model.
    player = scene.add_transform("Player", [0, 0.95, 0], [0, 0, 0, 1], [1, 1, 1], root)
    scene.add_component(player, T_RIGIDBODY, mass=1.0, use_gravity=False, is_kinematic=False, continuous=False,
                        linear_damping=0.0, angular_damping=0.0,
                        freeze_position=[False, True, False], freeze_rotation=[True, True, True],
                        layer_overrides={"include": 0, "exclude": 0})
    scene.add_component(player, T_CAPSULE_COLLIDER, radius=0.35, height=1.7, direction=1, center=[0, 0, 0],
                        density=1.0, is_trigger=False, layers=2, material=ZERO_GUID,
                        layer_overrides={"include": 0, "exclude": 0})
    scene.add_component(player, T_PSX_CHARACTER, scheme=0, tank_turn_speed=3.0, backward_speed=0.6,
                        turn_in_place=True, turn_speed=3.0, hold_basis=True, hold_tolerance=math.pi / 3)
    scene.add_component(player, T_PSX_DEMO_PLAYER, move_speed=3.0)

    model = scene.add_transform("Model", [0, -0.1, 0], [0, 0, 0, 1], [0.7, 1.7, 0.7], player)
    scene.add_component(model, T_MESH_FILTER, mesh={"guid": CUBE_MESH, "local_id": 0})
    scene.add_component(model, T_MESH_RENDERER, materials=[], cast_shadows=0, reflections=0)
    scene.add_component(model, T_PSX_RENDERER, lighting=1, blend=0, tint=[1.0, 1.0, 1.0, 1.0])

    path = os.path.join(ASSETS, "psx_demo.scene")
    scene.write(path)
    ensure_meta(path)
    print("psx_demo.scene")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "levels", "boot"):
        raise SystemExit(__doc__)
    {"prepare": prepare, "levels": levels, "boot": boot}[sys.argv[1]](sys.argv[2])
