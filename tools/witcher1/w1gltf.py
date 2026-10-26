"""Shared glTF writing helpers for the Witcher 1 -> Godot asset pipeline.

Material name contract (parsed by the Godot side):
    W1S|<diffuse>|<lightmapSet>|<flags>            static trimesh surface
    W1T|<d0>,<d1>,<d2>,<d3>|<lightmapSet>|<flags>  texture-paint surface, COLOR_0 = layer weights

<lightmapSet> names the per-time-of-day atlas in assets/witcher1/lightmaps as
<lightmapSet>_<tag>.png, tag in d/r/p/w/n; lightmaps/index.json lists what exists.

<flags> is a small integer: 1 = alpha scissor needed, 2 = two-sided.

Geometry is *not* textured inside the glTF on purpose: the Godot side builds its
own shader materials, so keeping textures as loose files leaves import settings,
VRAM compression and day/night variant swapping under our control.
"""
import os, struct, json, io
import numpy as np
from PIL import Image

from w1index import Index

GAME = os.environ.get('W1_GAME',
                      r'E:\Games\GOG Galaxy\Games\The Witcher Enhanced Edition')
PROJECT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
W1DUMP = os.environ.get('W1_CACHE', os.path.join(PROJECT, '.w1cache'))
ROOT = os.path.join(PROJECT, 'assets', 'witcher1')
TEXOUT = os.path.join(ROOT, 'textures')
LMOUT = os.path.join(ROOT, 'lightmaps')
for _d in (W1DUMP, TEXOUT, LMOUT):
    os.makedirs(_d, exist_ok=True)

IDX = Index(os.path.join(GAME, 'Data', 'main.key'))

# Witcher space is Z-up, Godot is Y-up: (x, y, z) -> (x, z, -y).
C = np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0], [0, 0, 0, 1]], dtype=np.float64)
# The area model is authored in tile-local space; GIT coordinates are 1500 further out.
AREA_OFFSET = np.eye(4)
AREA_OFFSET[0, 3] = 1500.0
AREA_OFFSET[1, 3] = 1500.0

DN_TAGS = ('d', 'r', 'p', 'w', 'n')
DN_SUFFIX = {'d': '!d', 'r': '!r', 'p': '!p', 'w': '!w', 'n': '!n'}


def decode_dds(data, stem):
    """DDS bytes -> RGBA PIL image, cached on disk."""
    d = os.path.join(W1DUMP, 'tex')
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, stem + '.dds')
    if not os.path.exists(p):
        open(p, 'wb').write(data)
    return Image.open(p).convert('RGBA')


def extract(resref, rtype, suffix='.bin'):
    """Pull a resource out of the game archives into the cache, returning its path."""
    p = os.path.join(W1DUMP, resref.lower() + '.%d%s' % (rtype, suffix))
    if not os.path.exists(p):
        got = IDX.get(resref.lower(), rtype)
        if not got:
            raise FileNotFoundError('%s (type %d) not in main.key' % (resref, rtype))
        open(p, 'wb').write(got[0])
    return p


def pose_matrix(pos, quat, scale=1.0):
    """GIT position + Witcher quaternion -> Godot 4x4 transform."""
    x, y, z, w = quat  # Witcher stores (x, y, z, w)
    # rotate the axis part through the Z-up -> Y-up change of basis
    vx, vy, vz = x, z, -y
    xx, yy, zz = vx * vx, vy * vy, vz * vz
    xy, xz, yz = vx * vy, vx * vz, vy * vz
    wx, wy, wz = w * vx, w * vy, w * vz
    m = np.eye(4)
    m[0, :3] = [(1 - 2 * (yy + zz)) * scale, 2 * (xy - wz) * scale, 2 * (xz + wy) * scale]
    m[1, :3] = [2 * (xy + wz) * scale, (1 - 2 * (xx + zz)) * scale, 2 * (yz - wx) * scale]
    m[2, :3] = [2 * (xz - wy) * scale, 2 * (yz + wx) * scale, (1 - 2 * (xx + yy)) * scale]
    m[0, 3] = pos[0]
    m[1, 3] = pos[1]
    m[2, 3] = pos[2]
    return m


class Glb:
    def __init__(self):
        self.bin = bytearray()
        self.g = {'asset': {'version': '2.0', 'generator': 'w1-mdb-export'},
                  'buffers': [], 'bufferViews': [], 'accessors': [], 'meshes': [],
                  'nodes': [], 'materials': [],
                  'scene': 0, 'scenes': [{'nodes': []}]}
        self.mc = {}       # material name -> index
        self.ic = {}       # resref -> png stem ('' when absent)
        self.lm_sets = {}  # lightmap set name -> {tag: file stem}
        self.mesh_cache = {}  # (mdb path, node index) -> glTF mesh index

    def _pad(self):
        while len(self.bin) % 4:
            self.bin.append(0)

    def view(self, data, target=None):
        self._pad()
        off = len(self.bin); self.bin += data
        v = {'buffer': 0, 'byteOffset': off, 'byteLength': len(data)}
        if target:
            v['target'] = target
        self.g['bufferViews'].append(v)
        return len(self.g['bufferViews']) - 1

    def acc(self, view, comp, count, ctype, mn=None, mx=None):
        a = {'bufferView': view, 'componentType': comp, 'count': count, 'type': ctype}
        if mn is not None:
            a['min'] = [float(x) for x in mn]; a['max'] = [float(x) for x in mx]
        self.g['accessors'].append(a)
        return len(self.g['accessors']) - 1

    def tex(self, resref):
        """Loose PNG for a diffuse texture; returns its file stem ('' when absent)."""
        name = resref.lower() if resref else ''
        if not name:
            return ''
        if name in self.ic:
            return self.ic[name]
        got = IDX.get(name, 2033)
        if not got or got[1] != 2033:
            print('  ! missing texture', name)
            self.ic[name] = ''
            return ''
        try:
            im = decode_dds(got[0], name)
        except Exception as e:
            print('  ! texture failed', name, e)
            self.ic[name] = ''
            return ''
        im.save(os.path.join(TEXOUT, name + '.png'))
        self.ic[name] = name
        return name

    def lightmap_set(self, set_name):
        """Write every available time-of-day variant as loose PNGs."""
        key = set_name.lower()
        if key in self.lm_sets:
            return self.lm_sets[key]
        found = {}
        for tag in DN_TAGS:
            resref = key + DN_SUFFIX[tag]
            got = IDX.get(resref, 2033)
            if got and got[1] == 2033:
                stem = '%s_%s' % (key, tag)
                try:
                    decode_dds(got[0], stem).save(os.path.join(LMOUT, stem + '.png'))
                except Exception as e:
                    print('  ! lightmap failed', resref, e)
                    continue
                found[tag] = stem
        if not found:  # static, non-day/night lightmap
            got = IDX.get(key, 2033)
            if got and got[1] == 2033:
                im = decode_dds(got[0], key)
                im.save(os.path.join(LMOUT, key + '.png'))
                for tag in DN_TAGS:
                    found[tag] = key
        self.lm_sets[key] = found
        return found

    def mat(self, name):
        if name in self.mc:
            return self.mc[name]
        parts = name.split('|')
        self.g['materials'].append({
            'name': name,
            'doubleSided': True,
            'pbrMetallicRoughness': {'metallicFactor': 0.0, 'roughnessFactor': 1.0},
            'extras': {'diffuse': [d for d in parts[1].split(',') if d],
                       'lightmap': parts[2] if len(parts) > 2 else '',
                       'flags': int(parts[3]) if len(parts) > 3 and parts[3] else 0}})
        self.mc[name] = len(self.g['materials']) - 1
        return self.mc[name]

    def add_surface(self, name, pos, nor, uv0, uv1, idx, matname, colors=None):
        """Append a mesh + node with an explicit 4x4 world transform."""
        vpos = self.view(np.asarray(pos, '<f4').tobytes(), 34962)
        vnor = self.view(np.asarray(nor, '<f4').tobytes(), 34962)
        vu0 = self.view(np.asarray(uv0, '<f4').tobytes(), 34962)
        vu1 = self.view(np.asarray(uv1, '<f4').tobytes(), 34962)
        vidx = self.view(np.asarray(idx, '<u4').tobytes(), 34963)
        attrs = {
            'POSITION': self.acc(vpos, 5126, len(pos), 'VEC3', pos.min(0), pos.max(0)),
            'NORMAL': self.acc(vnor, 5126, len(nor), 'VEC3'),
            'TEXCOORD_0': self.acc(vu0, 5126, len(uv0), 'VEC2'),
            'TEXCOORD_1': self.acc(vu1, 5126, len(uv1), 'VEC2'),
        }
        if colors is not None:
            vc = self.view(np.asarray(colors, '<f4').tobytes(), 34962)
            attrs['COLOR_0'] = self.acc(vc, 5126, len(colors), 'VEC4')
        mesh = {'name': name, 'primitives': [{
            'attributes': attrs,
            'indices': self.acc(vidx, 5125, len(idx), 'SCALAR'),
            'material': self.mat(matname), 'mode': 4}]}
        self.g['meshes'].append(mesh)
        return len(self.g['meshes']) - 1

    def add_node(self, name, mesh_index, matrix):
        gl = np.array(matrix, dtype='<f4').T.reshape(-1)
        self.g['nodes'].append({'name': name, 'mesh': mesh_index,
                                'matrix': [float(x) for x in gl]})
        self.g['scenes'][0]['nodes'].append(len(self.g['nodes']) - 1)

    def write(self, path):
        self._pad()
        self.g['buffers'].append({'byteLength': len(self.bin)})
        glb = bytearray()
        js = json.dumps(self.g, separators=(',', ':')).encode()
        while len(js) % 4:
            js += b' '
        glb += struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(self.bin))
        glb += struct.pack('<II', len(js), 0x4E4F534A) + js
        glb += struct.pack('<II', len(self.bin), 0x004E4942) + self.bin
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'wb').write(glb)
        # Several exporters share one lightmap folder, so merge instead of overwriting.
        index_path = os.path.join(LMOUT, 'index.json')
        index = {}
        if os.path.exists(index_path):
            index = json.load(open(index_path))
        index.update(self.lm_sets)
        json.dump(index, open(index_path, 'w'), indent=1, sort_keys=True)
        return len(glb)

    def texture_flags(self, stems):
        """1 = the diffuse needs alpha testing, 2 = two-sided."""
        for s in stems:
            if not s:
                continue
            p = os.path.join(TEXOUT, s + '.png')
            try:
                if Image.open(p).getchannel('A').getextrema()[0] < 250:
                    return 1
            except Exception:
                pass
        return 0
