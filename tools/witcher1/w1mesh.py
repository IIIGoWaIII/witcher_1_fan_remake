"""Turn parsed Witcher MDB nodes into (positions, normals, uvs, indices, color) arrays."""
import struct
import numpy as np

from w1gltf import Glb


def mesh_arrays(m, node):
    """(pos, nor, uv0, uv1, indices, vertex_count) or None.

    uv0 is the lightmap atlas channel, uv1 the tiling diffuse channel.
    """
    me = node['mesh']
    a = me['arr']
    vc = a['v'][1]
    if not vc or not a['f'][1]:
        return None
    pos = np.frombuffer(m.d, dtype='<f4', count=vc*3, offset=m.offRawData + a['v'][0]).reshape(-1, 3)
    nc = a['n'][1]
    if nc == vc:
        nor = np.frombuffer(m.d, dtype='<f4', count=nc*3, offset=m.offRawData + a['n'][0]).reshape(-1, 3)
    else:
        nor = np.zeros((vc, 3), 'f4')

    def uv(i):
        c = a['uv%d' % i][1]
        if c == vc:
            return np.frombuffer(m.d, dtype='<f4', count=c*2, offset=m.offRawData + a['uv%d' % i][0]).reshape(-1, 2)
        return np.zeros((vc, 2), '<f4')

    fc = a['f'][1]
    rec = 32 if me['kind'] == 'trimesh' else 80
    skip = 20 if me['kind'] == 'trimesh' else 0
    raw = m.d[m.offRawData + a['f'][0]: m.offRawData + a['f'][0] + fc*rec]
    idx = np.zeros(fc*3, '<u4')
    for i in range(fc):
        idx[i*3:i*3+3] = struct.unpack_from('<3I', raw, i*rec + skip)
    return pos, nor, uv(0), uv(1), idx, vc


def layer_weights(m, me, vc):
    """[(resref, per-vertex weight array)] for every layer that covers all vertices."""
    out = []
    for l in me['layers']:
        if not l or not l['texture']:
            continue
        wo, wc = l['weights']
        if wc != vc:
            continue
        out.append((l['texture'],
                    np.frombuffer(m.d, dtype='<f4', count=wc, offset=m.offRawData + wo)))
    return out


def top4_colors(layers, vc):
    """Keep the four heaviest layers per node, normalise, pack into COLOR_0."""
    if not layers:
        return [], np.tile(np.array([1.0, 0, 0, 0], 'f4'), (vc, 1)), 0.0
    totals = np.zeros(vc, 'f8')
    for _, w in layers:
        totals += np.clip(w, 0.0, None)
    ranked = sorted(layers, key=lambda lw: -np.clip(lw[1], 0, None).sum())[:4]
    names = [n for n, _ in ranked]
    padded = ranked + [(None, np.zeros(vc, 'f4'))] * (4 - len(ranked))
    cols = np.zeros((vc, 4), 'f4')
    covered = np.zeros(vc, 'f8')
    for i, (_, w) in enumerate(padded):
        wc = np.clip(w, 0, None)
        cols[:, i] = wc
        covered += wc
    safe = np.where(totals > 1e-8, totals, 1.0)
    cols /= safe[:, None]
    cols[totals <= 1e-8] = (1.0, 0.0, 0.0, 0.0)
    residual = float(np.where(totals > 1e-8, (totals - covered) / safe, 0.0).mean())
    return names, cols, residual


def describe(b: Glb, m, node):
    """(arrays, material name, weight residual) for one mesh node of an MDB."""
    me = node.get('mesh')
    if not me:
        return None, '', 0.0
    arr = mesh_arrays(m, node)
    if arr is None:
        return None, '', 0.0
    pos, nor, uv0, uv1, idx, vc = arr

    tex0 = (me['texture'][0] if me['kind'] == 'trimesh' else '') or ''
    # texture[0] holding "_shader_" means the slot names an engine shader, not a texture.
    shader = ''
    if tex0.lower() == '_shader_':
        shader = me['texture'][1] or ''
        tex0 = ''

    # Static area geometry binds the lightmap atlas in slot 0 and the diffuse in slot 1,
    # and repeats the lightmap set name in the lightMap field. Props carry no lightmap,
    # so for them slot 0 holds the diffuse and slot 1 stays empty.
    lightmap = ''
    lm_raw = (me.get('lightMap') or '').strip()
    if lm_raw.upper() in ('NULL', '_SHADER_'):
        lm_raw = ''
    if lm_raw and b.lightmap_set(lm_raw):
        lightmap = lm_raw
        diffuse_slot = 1
    else:
        diffuse_slot = 0

    if shader:
        return (pos, nor, uv0, uv1, idx, None), 'W1X|%s|%s|0' % (shader, lightmap), 0.0

    if me['kind'] == 'trimesh':
        names = [me['texture'][diffuse_slot]]
        colors = None
        residual = 0.0
    else:
        names, colors, residual = top4_colors(layer_weights(m, me, vc), vc)
        if not names:
            names = ['']

    stems = [b.tex(n) for n in names]
    flags = b.texture_flags([s for s in stems if s])
    if me['kind'] == 'trimesh':
        matname = 'W1S|%s|%s|%d' % (stems[0], lightmap, flags)
    else:
        slots = ','.join(stems + [''] * (4 - len(stems)))
        matname = 'W1T|%s|%s|%d' % (slots, lightmap, flags)
    return (pos, nor, uv0, uv1, idx, colors), matname, residual
