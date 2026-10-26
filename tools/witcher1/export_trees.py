"""Place the third-party tree pack at the area's original SpeedTree transforms.

`gl09` carries 2,813 SpeedTree placements (type 0x10001) - position, rotation and
scale only, because the SpeedTree descriptors ship without geometry. Those same
placements have their shadows baked into the ground lightmaps, so reusing the exact
transforms keeps the baked shadows lined up with the new trees.

Species: the original models are opaque (`l09_drzewo_01..20`, `l09_krzak_01..15`), so
the mapping to the pack is curated - it keeps the forest deciduous-dominant with a few
conifers, and gives the most frequent species the most generic trees.

Outputs:
    assets/witcher1/trees.json   asset -> pack node name, plus the global scale
    assets/witcher1/trees.bin    17 floats per tree: 4x4 transform, then asset index
"""
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mdbtree import load, build_world
from w1gltf import C, AREA_OFFSET, ROOT, extract

MODEL = 'gl09'
OUT_JSON = os.path.join(ROOT, 'trees.json')
OUT_BIN = os.path.join(ROOT, 'trees.bin')

## The pack is modelled a little taller than the original trees; a uniform 0.8 brings
## a 20 m birch down to 16 m, which sits right against the 7 m cottages. The pack's
## "shrubs" are 5-15 m wide, though, and the area has 1,444 bush placements - at full
## size they merge into a hedge and wall off every sightline, so they get 0.3.
TREE_SCALE = 0.8
BUSH_SCALE = 0.3

## Witcher species -> pack node. Counts in brackets, from the area's own GIT model.
TREE_MAP = {
    'l09_drzewo_01': 'Birch2_21',            # 246
    'l09_drzewo_02': 'BirchOrange2_23',      # 11
    'l09_drzewo_03': 'Oak_25',               # 192
    'l09_drzewo_04': 'AshTree_1',            # 91
    'l09_drzewo_05': 'Maple_24',             # 64
    'l09_drzewo_06': 'Birch1_20',            # 47
    'l09_drzewo_07': 'Birch3_26',            # 128
    'l09_drzewo_08': 'PineTree_19',          # 22
    'l09_drzewo_09': 'FirTree_17',           # 15
    'l09_drzewo_10': 'NobleFirTree_18',      # 16
    'l09_drzewo_11': 'AppleTree_0',          # 64
    'l09_drzewo_12': 'CherryTree_2',         # 118
    'l09_drzewo_13': 'PlumTree_3',           # 79
    'l09_drzewo_14': 'BirchOrange1_22',      # 4
    'l09_drzewo_15': 'DeciduousDead1_29',    # 7
    'l09_drzewo_18': 'Coniferous Dead Tree_13',  # 21
}

BUSH_MAP = {
    'l09_krzak_01': 'HollyShrub_4',
    'l09_krzak_02': 'RaspberryShrub_5',
    'l09_krzak_03': 'DeciduousShrub_27',
    'l09_krzak_04': 'ConiferousShrub_16',
    'l09_krzak_05': 'DeciduousShrub2_31',
    'l09_krzak_06': 'DeciduousShrub_27',
    'l09_krzak_07': 'DeciduousShrub2_31',
    'l09_krzak_08': 'DeciduousShrub_27',
    'l09_krzak_09': 'RaspberryShrub_5',
    'l09_krzak_10': 'HollyShrub_4',
    'l09_krzak_11': 'DeciduousShrub2_31',
    'l09_krzak_12': 'DeciduousSapling_32',
    'l09_krzak_13': 'DeciduousShrub_27',
    'l09_krzak_14': 'DeciduousSapling2_33',
    'l09_krzak_15': 'ConiferousShrub_16',
    'l09_krzak': 'DeciduousShrub_27',
}

BROKEN = re.compile(r'\[(.+?)\]')


def species_of(name):
    """`l09_drzewo_11_57[l09_drzewo_11]` -> `l09_drzewo_11`."""
    match = BROKEN.search(name)
    if match:
        return match.group(1).lower()
    return re.sub(r'_\d+$', '', name).lower()


def main():
    m = load(extract(MODEL, 2070, '.mdb'))
    build_world(m)
    to_world = C @ AREA_OFFSET

    assets = []
    rows = []
    missing = {}
    for node in m.nodes:
        if node.get('type') != 0x10001:
            continue
        species = species_of(node['name'])
        asset = TREE_MAP.get(species) or BUSH_MAP.get(species)
        if asset is None:
            missing[species] = missing.get(species, 0) + 1
            continue
        if asset not in assets:
            assets.append(asset)
        world = to_world @ node['world']
        # SpeedTree placements are upright, so a yaw and a uniform scale carry the
        # orientation without any matrix row/column convention games.
        x_axis = world[:3, 0]
        scale = float(np.linalg.norm(x_axis)) * (TREE_SCALE if species in TREE_MAP else BUSH_SCALE)
        yaw = float(np.arctan2(-x_axis[2], x_axis[0]))
        rows.append((world[:3, 3], yaw, scale, assets.index(asset)))

    data = np.zeros((len(rows), 6), '<f4')
    for i, (pos, yaw, scale, asset) in enumerate(rows):
        data[i, 0:3] = pos
        data[i, 3] = yaw
        data[i, 4] = scale
        data[i, 5] = asset
    data.tofile(OUT_BIN)

    json.dump({'assets': assets, 'count': len(rows),
               'tree_scale': TREE_SCALE, 'bush_scale': BUSH_SCALE},
              open(OUT_JSON, 'w'), indent=1)

    counts = {}
    for _, _, _, asset in rows:
        counts[assets[asset]] = counts.get(assets[asset], 0) + 1
    print('trees placed:', len(rows), 'across', len(assets), 'pack assets')
    for name in assets:
        print('  %-26s %4d' % (name, counts[name]))
    if missing:
        print('unmapped species:', missing)
    print('wrote', os.path.basename(OUT_BIN), '%.0f KB' % (os.path.getsize(OUT_BIN) / 1024))


if __name__ == '__main__':
    main()
