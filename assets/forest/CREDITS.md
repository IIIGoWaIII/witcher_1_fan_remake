# Third-party assets

## Various Forest Assets Pack

* File: `forest_assets.glb` (source: `../various_forest_assets_pack.glb`)
* Author: Dari — https://sketchfab.com/dariiiii
* Source: https://sketchfab.com/3d-models/various-forest-assets-pack-cf138b8eb2d340cda643ed59f824989c
* Licence: **CC-BY-4.0** — attribution is required if this project is distributed.

`forest_assets.glb` is not the file as downloaded. `tools/witcher1/fix_tree_pack.py`
rewrites its materials:

* the pack ships Sketchfab specular/glossiness materials
  (`KHR_materials_pbrSpecularGlossiness`) with no metallic/roughness fallback, which
  Godot does not implement — everything imports as untextured white metal
* the 13 branch/leaf atlas materials are alpha *blended*, which sorts per object and
  makes foliage pop; they are converted to alpha *mask* instead

Contents: 34 assets in 130,487 triangles (20 trees, 5 shrubs, 6 rocks, 3 dead
trees/logs), modelled in metres — tree heights 13–22 m, which matches the Witcher
world scale of 1 unit = 1 m.
