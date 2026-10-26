"""Export the area's grass clumps and their scattered placement.

The area `.set` resource (type 2013) is a plain INI. Its `[GRASS]`...`[GRASS6]`
blocks name a `trawa_setNN` model, a tint, and one entry per clump geometry inside
that model (`Model00MinScale`, `Model00Density`, ...). Those models do exist in the
game data, so the clumps are the original meshes with the original textures; only
the placement has to be derived, and it is taken from the terrain's own
texture-paint layer weights (grass grows where `trn_trawa_*` outweighs rock, mud
and paving).

Outputs, next to the area GLB:

    vizima_outskirts_grass.glb   one merged, alpha-scissored mesh per grass type
    grass.json                   types, clump meshes, scatter transforms
"""
import os, sys, json, re, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mdbtree import load, build_world
from w1gltf import Glb, C, AREA_OFFSET, ROOT, IDX, extract
from w1mesh import mesh_arrays, layer_weights

SET_RESREF = 'gl09'
AREA_MODEL = 'gl09'
OUT = os.path.join(ROOT, 'vizima_outskirts_grass.glb')
MANIFEST = os.path.join(ROOT, 'grass.json')

## Terrain layers that grow ground cover, with a density weight. Forest litter gets a
## thinner covering than open grass so the woods are not bare.
GROUND_COVER = {'trn_trawa_': 1.0, 'trn_sciolka_': 0.45}
GRASS_LAYERS = tuple(GROUND_COVER)

## Each exported grass model is a multi-metre patch of blades, not a single tuft, so
## they are placed like the original's vegetation map does: a few thousand patches
## that tile the grassy ground.
TARGET_INSTANCES = 400000


def read_set():
    raw = IDX.get(SET_RESREF, 2013)
    if not raw:
        raise SystemExit('no .set for ' + SET_RESREF)
    text = raw[0].decode('latin-1')
    sections = {}
    current = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(';'):
            continue
        if line.startswith('[') and line.endswith(']'):
            current = line[1:-1].strip()
            sections[current] = {}
        elif '=' in line and current:
            k, v = line.split('=', 1)
            sections[current][k.strip()] = v.strip()
    return sections


def grass_types(sections):
    """[{name, model, tint, clumps:[{min_scale,max_scale,density,align}]}]."""
    out = []
    seen = {}
    for key in ('GRASS',) + tuple('GRASS%d' % i for i in range(1, 10)):
        block = sections.get(key)
        if not block or block.get('Grass') != '1':
            continue
        model = block.get('Texture', '').lower()
        if not model:
            continue
        signature = (model, tuple(sorted((k, v) for k, v in block.items() if k.startswith('Model'))))
        if signature in seen:
            # Several blocks can name the same model with the same clump settings;
            # only the clump geometry differs, and that lives in the model itself.
            seen[signature].append(key)
            continue
        tint = np.array([float(block.get('DiffuseRed', 1.0)),
                         float(block.get('DiffuseGreen', 1.0)),
                         float(block.get('DiffuseBlue', 1.0))], 'f4')
        clumps = []
        for i in range(32):
            prefix = 'Model%02d' % i
            if prefix + 'Density' not in block:
                break
            clumps.append({'min_scale': float(block.get(prefix + 'MinScale', 1.0)),
                           'max_scale': float(block.get(prefix + 'MaxScale', 1.0)),
                           'density': float(block.get(prefix + 'Density', 1.0)),
                           'align': block.get(prefix + 'AlignToWalkmesh', '1') == '1'})
        entry = {'name': key, 'model': model, 'tint': [float(v) for v in tint],
                 'clumps': clumps, 'also': [key]}
        seen[signature] = entry['also']
        out.append(entry)
    return out


def clump_surfaces(model):
    """Merged (pos, nor, uv0, uv1, idx) for every clump mesh of one grass model.

    The clumps of a type all share one texture, so they can become a single surface
    and therefore a single multimesh.
    """
    path = extract(model, 2070, '.mdb')
    m = load(path)
    build_world(m)
    pos, nor, uv0, uv1, idx = [], [], [], [], []
    base = 0
    texture = ''
    for node in m.nodes:
        me = node.get('mesh')
        if not me or me['kind'] != 'trimesh' or not me.get('render', True):
            continue
        a = mesh_arrays(m, node)
        if a is None:
            continue
        texture = texture or (me['texture'][0] or '')
        w = node['world']
        p = a[0] @ w[:3, :3].T + w[:3, 3]
        n = a[1] @ w[:3, :3].T
        n = np.nan_to_num(n, nan=0.0, posinf=0.0, neginf=0.0)
        # Instance positions already carry the area transform, so only the Witcher
        # Z-up -> Godot Y-up basis change belongs on the geometry itself.
        pos.append(p @ C[:3, :3].T)
        nor.append(n @ C[:3, :3].T)
        uv0.append(a[2])
        uv1.append(a[3])
        idx.append(a[4] + base)
        base += len(p)
    if not pos:
        return None
    return (np.concatenate(pos), np.concatenate(nor), np.concatenate(uv0),
            np.concatenate(uv1), np.concatenate(idx), base, texture)


def terrain_triangles():
    """(triangles Nx3x3, grass fraction N) in Godot space for every painted node."""
    m = load(extract(AREA_MODEL, 2070, '.mdb'))
    build_world(m)
    to_world = C @ AREA_OFFSET
    tris, frac = [], []
    for node in m.nodes:
        me = node.get('mesh')
        if not me or me['kind'] != 'paint':
            continue
        a = mesh_arrays(m, node)
        if a is None:
            continue
        p = a[0]
        pos = p @ node['world'][:3, :3].T + node['world'][:3, 3]
        pos = pos @ to_world[:3, :3].T + to_world[:3, 3]
        idx = a[4].reshape(-1, 3)

        layers = layer_weights(m, me, a[5])
        if not layers:
            continue
        # Grass has to beat every other painted layer, not just pass a fraction of the
        # total: road paving and rock also blend into the same vertices.
        grass = np.zeros(a[5], 'f8')
        other = np.zeros(a[5], 'f8')
        for tex, w in layers:
            cover = 0.0
            for prefix, weight in GROUND_COVER.items():
                if tex.startswith(prefix):
                    cover = weight
                    break
            if cover > 0.0:
                grass += np.clip(w, 0.0, None) * cover
            elif tex.startswith('trn_'):
                other += np.clip(w, 0.0, None)
        ratio = np.where(grass + other > 1e-6, grass / np.maximum(grass + other, 1e-6), 0.0)
        # The weakest corner decides: a triangle that straddles the edge of a field and
        # a paved road should stay bare rather than sprout grass on the kerb.
        tri_ratio = ratio[idx].min(axis=1)
        tris.append(pos[idx])
        frac.append(tri_ratio)
    return np.concatenate(tris), np.concatenate(frac)


def scatter(tris, frac, per_type, rng):
    """Sample clump transforms on grass-covered triangles, one list per grass type."""
    v0, v1, v2 = tris[:, 0], tris[:, 1], tris[:, 2]
    area = 0.5 * np.linalg.norm(np.cross(v1 - v0, v2 - v0), axis=1)
    normal = np.cross(v1 - v0, v2 - v0)
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-9)

    # Only near-horizontal ground that the paint layers call grass: cliffs, paving and
    # river beds stay bare.
    ok = (frac > 0.6) & (normal[:, 1] > 0.7) & (area > 1e-4)
    tris, area, frac = tris[ok], area[ok], frac[ok]
    if not len(tris):
        return []

    weights = area * np.clip(frac, 0.0, 1.0)
    cum = np.cumsum(weights)
    total = cum[-1]
    index = np.searchsorted(cum, rng.random(per_type) * total)

    abc = rng.random((per_type, 2))
    flip = abc.sum(axis=1) > 1.0
    abc[flip] = 1.0 - abc[flip]
    u, v = abc[:, 0], abc[:, 1]
    picked = tris[index]
    point = picked[:, 0] + (picked[:, 1] - picked[:, 0]) * u[:, None] \
        + (picked[:, 2] - picked[:, 0]) * v[:, None]
    return point, np.arctan2(normal[index][:, 0], normal[index][:, 2])


def main():
    sections = read_set()
    types = grass_types(sections)
    print('grass types:', [(t['name'], t['model'], len(t['clumps'])) for t in types])

    b = Glb()
    usable = []
    for t in types:
        surf = clump_surfaces(t['model'])
        if surf is None:
            print('  skip', t['name'], '(no clump meshes)')
            continue
        pos, nor, uv0, uv1, idx, verts, texture = surf
        # Litter and rubbish clumps (trw_smieci*) belong next to buildings, not in the
        # open fields the scatter targets, and their meshes are ten times heavier.
        if texture.startswith('trw_smieci'):
            print('  skip', t['name'], '(', texture, 'is litter )')
            continue
        matname = 'W1G|%s|%s|1' % (b.tex(texture), t['name'])
        mi = b.add_surface(t['model'], pos, nor, uv0, uv1, idx, matname)
        b.add_node(t['model'], mi, np.eye(4))
        usable.append((t, len(idx) // 3))
        print('  %-8s %-13s %-13s %4d verts %3d tris' % (t['name'], t['model'], texture, verts, len(idx) // 3))

    print('sampling terrain...')
    tris, frac = terrain_triangles()
    print('  %d terrain triangles, %.1f%% grassy' % (len(tris), 100.0 * float((frac > 0.6).mean())))

    # Each type is exported as one merged patch, so one instance draws the whole patch;
    # its share of the instance budget sets how many patches that type gets.
    rng = np.random.default_rng(7)
    weight_total = sum(len(t['clumps']) for t, _ in usable) or 1
    placements = {}
    for t, tris_per_instance in usable:
        count = int(TARGET_INSTANCES * len(t['clumps']) / weight_total)
        if count == 0:
            continue
        points, yaw = scatter(tris, frac, count, rng)
        lo = sum(c['min_scale'] for c in t['clumps']) / len(t['clumps'])
        hi = sum(c['max_scale'] for c in t['clumps']) / len(t['clumps'])
        scale = rng.uniform(lo, hi, count).astype('f4')
        spread = rng.uniform(0.0, 6.2831853, count).astype('f4')
        placements[t['model']] = np.column_stack(
            [points.astype('f4'), yaw.astype('f4'), scale, spread])

    out = {}
    total = 0
    for model, data in placements.items():
        data = data[rng.permutation(len(data))]
        total += len(data)
        t = next(x for x, _ in usable if x['model'] == model)
        out[model] = {'tint': t['tint'], 'instances': len(data)}
        data.tofile(os.path.join(ROOT, 'grass_%s.bin' % model))
    print('patches placed:', total)

    size = b.write(OUT)
    json.dump({'types': out, 'budget': TARGET_INSTANCES}, open(MANIFEST, 'w'), indent=1)
    print('glb %.2f MB | types %d | clumps %d' % (size / 1e6, len(out), total))


if __name__ == '__main__':
    main()
