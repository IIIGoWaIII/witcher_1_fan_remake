"""Export every GIT placeable and door of an area as one instanced GLB.

Usage: python export_props.py [gitResRef] [modFile] [outFile]
Defaults to Vizima Outskirts (l09 in outskirts_1.mod).
"""
import os, sys, json, collections
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mdbtree import load, build_world
from w1archive import Erf
from gff import Gff
from w1gltf import Glb, C, IDX, GAME, ROOT, pose_matrix, extract
from w1mesh import describe

GIT = sys.argv[1] if len(sys.argv) > 1 else 'l09'
MOD = sys.argv[2] if len(sys.argv) > 2 else r'Data\modules\!Final\outskirts_1.mod'
OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, 'vizima_outskirts_props.glb')
MANIFEST = os.path.join(ROOT, 'props.json')

# The skybox is a GIT placeable too, but its layers are textured and animated by the
# engine (its texture slots are all empty here). Rendering it as static geometry just
# puts an untextured shell around the map, so the scene supplies its own sky instead.
SKIP_MODELS = ('skaybox_',)


def read_git(resref, mod):
    erf = Erf(os.path.join(GAME, mod))
    rid, rtype, off, size = erf.entries[resref]
    return Gff(erf._data[off:off + size]).parse()


def instances(git):
    """[(instance name, model resref, godot 4x4)] for placeables + doors."""
    out = []
    for kind, field in (('p', 'Placeable List'), ('d', 'Door List')):
        for i, e in enumerate(git.get(field, [])):
            model = (e.get('ModelName') or e.get('TemplateResRef') or '').lower()
            if not model:
                continue
            pos = (e.get('X', 0.0), e.get('Z', 0.0), -e.get('Y', 0.0))  # Z-up -> Y-up
            quat = (e.get('OrientationX', 0.0), e.get('OrientationY', 0.0),
                    e.get('OrientationZ', 0.0), e.get('OrientationW', 1.0))
            scale = float(e.get('ModelScale', 1.0) or 1.0)
            name = e.get('Tag') or '%s%03d' % (kind, i)
            out.append((name, model, pose_matrix(pos, quat, scale), kind))
    return out


def main():
    git = read_git(GIT, MOD)
    inst = [i for i in instances(git) if not i[1].startswith(SKIP_MODELS)]
    print('instances', len(inst), 'unique models',
          len(set(i[1] for i in inst)))

    # resolve + parse every unique model once
    models = {}
    missing = collections.Counter()
    for _, model, _, _ in inst:
        if model in models:
            continue
        got = IDX.get(model, 2070)
        if not got or got[1] != 2070:
            missing[model] += 1
            models[model] = None
            continue
        path = extract(model, 2070, '.mdb')
        m = load(path)
        build_world(m)
        models[model] = m

    if missing:
        print('unresolved models (%d):' % len(missing), dict(missing))

    b = Glb()
    cache = {}
    placed = nodes = 0
    for name, model, xform, _kind in inst:
        m = models.get(model)
        if m is None:
            continue
        for i, node in enumerate(m.nodes):
            if not node.get('mesh'):
                continue
            if (node.get('minLOD') or 0) > 0:
                continue
            # Collision dummies and hit-check proxies are never drawn in game.
            if not node['mesh'].get('render', True):
                continue
            key = (model, i)
            if key not in cache:
                arrays, matname, _ = describe(b, m, node)
                if arrays is None:
                    cache[key] = None
                    continue
                pos, nor, uv0, uv1, idx, colors = arrays
                cache[key] = b.add_surface('%s_%d' % (model, i), pos, nor, uv0, uv1,
                                           idx, matname, colors)
            mi = cache[key]
            if mi is None:
                continue
            b.add_node('%s.%s.%d' % (name, model, i), mi, xform @ C @ node['world'])
            nodes += 1
        placed += 1

    size = b.write(OUT)
    spawns = []
    for e in git.get('SpawnpointList', []):
        spawns.append({'name': e.get('Tag') or '',
                       'pos': [e.get('PositionX', 0.0), e.get('PositionZ', 0.0) + 1.7,
                               -e.get('PositionY', 0.0)],
                       'quat': [e.get('OrientationX', 0.0), e.get('OrientationY', 0.0),
                                e.get('OrientationZ', 0.0), e.get('OrientationW', 1.0)]})
    json.dump({'instances': [{'name': n, 'model': mo, 'kind': k,
                              'matrix': [float(v) for v in np.array(x, dtype='<f4').T.reshape(-1)]}
                             for n, mo, x, k in inst],
               'spawns': spawns},
              open(MANIFEST, 'w'), indent=0)
    print('glb %.1f MB | instances %d | nodes %d | spawns %d'
          % (size / 1e6, placed, nodes, len(spawns)))
    print('meshes', len(b.g['meshes']), 'materials', len(b.g['materials']),
          'lightmap sets', len(b.lm_sets))
    for k, v in sorted(b.lm_sets.items()):
        print('  lm', k, '->', ','.join(sorted(v)))


if __name__ == '__main__':
    main()
