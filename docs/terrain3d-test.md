# Terrain3D comparison scene

`scenes/Vizima_outskirts_03.tscn` is a separate test scene for judging Terrain3D
as a replacement for the original ground. Scene 02 is untouched and remains the
reference.

The scene keeps the original buildings, props, water, sky and player. It hides
the 186 original texture-paint terrain meshes and draws the ground with a
Terrain3D node instead. The original 400,000 grass patches are imported into the
Terrain3D foliage instancer, so the grass is also painted and erased with the
Terrain3D tools.

## What was built

| Item | Value |
| --- | --- |
| Heightfield | 1 m grid, 2 regions at 1024 m, heights -9.7 to 11.8 m |
| Ground color | 1 m/px top-down render of the original ground, albedo x noon lightmap |
| Grass assets | 5 `trawa_set*` patch meshes, original `w1_grass` shader |
| Grass baseline | 399,998 imported transforms, original positions and Y |
| Original ground | hidden, not deleted |
| Original grass node | `grass_enabled = false`, all grass lives in the instancer |

The height projection was measured against the original mesh before building:

| Heightmap spacing | Mean error | 95th percentile | Area off by more than 25 cm |
| --- | --- | --- | --- |
| 1 m | 1.5 cm | 3.7 cm | 0.8% |
| 0.5 m | 0.9 cm | 1.1 cm | 0.42% |

The missed parts are cliffs, the rock entrance and overhangs. A heightfield
cannot represent those.

The color map is the literal version of "project the ground texture onto
Terrain3D". The original ground was rendered orthographically from above into a
2048 x 1024 image, then imported as the Terrain3D color map. Colors and baked
shadows match the original at a distance. Up close the 1 m/px projection is soft
because it has no tiling layers and no per-texel lightmap.

What is not reproduced: the original 15-layer terrain paint, the 0.5 m mesh, and
the four time-of-day lightmap sets. The test scene is fixed to noon.

## Painting grass

1. Open `scenes/Vizima_outskirts_03.tscn`.
2. Select the `Terrain3D` node in the Scene dock.
3. Open the Foliage tool in the Terrain3D toolbar.
4. Pick one of the five meshes in the Asset Dock: `trawa_set03`, `05`, `07`,
   `08` or `09`.
5. Paint on the ground. `Ctrl` removes the selected mesh type. `Ctrl + Shift +
   LMB` removes every mesh type under the brush.
6. Save the scene. Terrain3D writes the region files under
   `assets/terrain3d/vizima_test/data/`.

The brush places whole multi-metre patches, not individual blades. That is the
same unit the original exporter used. To start from an empty ground, middle-click
a mesh in the Asset Dock to clear all its instances, once per type. To inspect the
projected ground without grass, turn off `show_instances` on the `Terrain3D` node.

Newly painted grass snaps to the 1 m heightfield. The imported baseline keeps
the exact original Y. Avoid painting on cliffs and under the rock entrance, where
the heightfield is an approximation.

## Rebuilding the test data

Run from the project root, in this order:

```powershell
# 1. Bake height, control and the normalized layer textures
python tools\witcher1\export_terrain3d.py

# 2. Import the normalized textures and the flat normal
& "D:\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" `
  --headless --path . --editor --quit

# 3. Render the original ground from above and overwrite color.rgba
& "D:\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" `
  --path . res://tools/w1_ortho_ground.tscn

# 4. Import the Terrain3D regions, build the assets and import the grass baseline
& "D:\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" `
  --headless --path . --script res://tools/build_terrain3d_test.gd
```

Step 3 must run after step 1 and before step 4. The Python bake writes a
lightmap-times-coverage color map first; the orthographic render replaces it with
the actual ground projection.

Do not set `region_size` on the `Terrain3D` node in the scene. Terrain3D reads the
region size from the data files. Setting it in the scene before the data loads
crashed this build.

## Files

| Path | Purpose |
| --- | --- |
| `scenes/Vizima_outskirts_03.tscn` | the comparison scene |
| `shaders/w1_terrain3d.gdshader` | unshaded color-map terrain shader |
| `assets/terrain3d/vizima_test/height.r32` | 1 m height grid |
| `assets/terrain3d/vizima_test/control.r32` | Terrain3D control map, holes and layer ids |
| `assets/terrain3d/vizima_test/color.rgba` | projected ground color map |
| `assets/terrain3d/vizima_test/ortho_ground.png` | preview of the projected ground |
| `assets/terrain3d/vizima_test/data/` | Terrain3D regions and grass instances |
| `assets/terrain3d/vizima_test/assets.tres` | terrain textures and five grass mesh assets |
| `assets/terrain3d/vizima_test/material.tres` | Terrain3D material using the projected color map |
| `tools/witcher1/export_terrain3d.py` | height, control and texture bake |
| `tools/w1_ortho_ground.gd` | orthographic ground render |
| `tools/build_terrain3d_test.gd` | Terrain3D data, assets and grass import |
| `tools/w1_playtest_03.gd` | loads scene 03, settles the player and saves a screenshot |

## Verdict so far

The geometry projection is close enough to be useful. The color projection is
good at a distance and soft up close. The brush workflow works, but Terrain3D
holds only two texture layers per vertex and no original lightmap atlas, so this
is not a drop-in replacement for the original ground. Keep scene 02 as the
reference and use scene 03 to judge the tradeoff.
