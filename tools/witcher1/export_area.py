"""Export the Vizima Outskirts area model (gl09) to assets/witcher1/vizima_outskirts.glb."""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mdbtree import load, build_world
from w1gltf import Glb, C, AREA_OFFSET, ROOT, extract
from w1mesh import describe

OUT = os.path.join(ROOT, 'vizima_outskirts.glb')


def main():
    m = load(extract('gl09', 2070, '.mdb'))
    build_world(m)
    b = Glb()
    meshes = tris = painted = skipped = 0
    residual = 0.0

    for node in m.nodes:
        if not node.get('mesh'):
            continue
        # Only LOD0: the model also carries LOD3..5 billboards that z-fight with the real surface.
        if (node.get('minLOD') or 0) > 0:
            skipped += 1
            continue
        # Collision-only meshes (walkmeshes) are not drawn by the engine. They carry no
        # texture or lightmap, so rendering them just paints white slabs over the terrain.
        if not node['mesh'].get('render', True):
            skipped += 1
            continue
        arrays, matname, res = describe(b, m, node)
        if arrays is None:
            continue
        pos, nor, uv0, uv1, idx, colors = arrays
        if node['name'] == 'river' and matname.startswith('W1S||'):
            matname = 'W1X|proc_water||0'
        mi = b.add_surface(node['name'], pos, nor, uv0, uv1, idx, matname, colors)
        b.add_node(node['name'], mi, C @ AREA_OFFSET @ node['world'])
        meshes += 1
        tris += len(idx) // 3
        if node['mesh']['kind'] == 'paint':
            painted += 1
            residual += res

    size = b.write(OUT)
    print('glb %.1f MB | meshes %d (painted %d, lod skipped %d) | tris %d | materials %d | lightmap sets %d'
          % (size / 1e6, meshes, painted, skipped, tris, len(b.g['materials']), len(b.lm_sets)))
    print('mean weight residual (top-4 truncation): %.3f' % (residual / max(painted, 1)))
    for k, v in sorted(b.lm_sets.items()):
        print('  lm', k, '->', ','.join(sorted(v)))


if __name__ == '__main__':
    main()
