"""Prepare the third-party tree pack for Godot.

`various_forest_assets_pack.glb` ships Sketchfab specular/glossiness materials
(`KHR_materials_pbrSpecularGlossiness`) with no metallic/roughness fallback. Godot
does not implement that extension, so every material imports as untextured white
metal: the trees come in as white blobs.

This rewrites the materials into the metallic/roughness form Godot understands, and
switches the foliage cards from alpha *blend* to alpha *mask*, which is what you want
for branch atlases - blending sorts per object and makes leaves pop in and out.

Usage: python fix_tree_pack.py [in.glb] [out.glb]
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'source_assets', 'various_forest_assets_pack.glb')
DST = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'assets', 'forest', 'forest_assets.glb')

SPEC_GLOSS = 'KHR_materials_pbrSpecularGlossiness'
ALPHA_CUTOFF = 0.35


def read_glb(path):
    data = open(path, 'rb').read()
    magic, version, length = struct.unpack_from('<III', data, 0)
    if magic != 0x46546C67:
        raise SystemExit('not a GLB: ' + path)
    offset = 12
    gltf, binary = None, b''
    while offset < length:
        size, kind = struct.unpack_from('<II', data, offset)
        chunk = data[offset + 8: offset + 8 + size]
        if kind == 0x4E4F534A:
            gltf = json.loads(chunk)
        elif kind == 0x004E4942:
            binary = chunk
        offset += 8 + size
    return gltf, binary


def write_glb(path, gltf, binary):
    js = json.dumps(gltf, separators=(',', ':')).encode('utf-8')
    js += b' ' * (-len(js) % 4)
    bn = binary + b'\0' * (-len(binary) % 4)
    total = 12 + 8 + len(js) + (8 + len(bn) if bn else 0)
    out = bytearray()
    out += struct.pack('<III', 0x46546C67, 2, total)
    out += struct.pack('<II', len(js), 0x4E4F534A) + js
    if bn:
        out += struct.pack('<II', len(bn), 0x004E4942) + bn
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(bytes(out))


def convert_material(mat):
    changed = []
    ext = (mat.get('extensions') or {}).pop(SPEC_GLOSS, None)
    if ext is not None:
        pbr = {}
        if 'diffuseFactor' in ext:
            pbr['baseColorFactor'] = ext['diffuseFactor']
        if 'diffuseTexture' in ext:
            pbr['baseColorTexture'] = ext['diffuseTexture']
        pbr['metallicFactor'] = 0.0
        pbr['roughnessFactor'] = round(min(1.0, max(0.0, 1.0 - ext.get('glossinessFactor', 1.0))), 4)
        mat['pbrMetallicRoughness'] = pbr
        changed.append('pbr')
    if not mat.get('extensions'):
        mat.pop('extensions', None)
    if mat.get('alphaMode') == 'BLEND':
        # Foliage cards: cut them out instead of blending, so they sort correctly.
        mat['alphaMode'] = 'MASK'
        mat['alphaCutoff'] = ALPHA_CUTOFF
        changed.append('mask')
    return changed


def main():
    gltf, binary = read_glb(SRC)
    stats = {'pbr': 0, 'mask': 0}
    for mat in gltf.get('materials', []):
        for what in convert_material(mat):
            stats[what] += 1

    for key in ('extensionsUsed', 'extensionsRequired'):
        if key in gltf:
            gltf[key] = [e for e in gltf[key] if e != SPEC_GLOSS]
            if not gltf[key]:
                del gltf[key]

    write_glb(DST, gltf, binary)
    size = os.path.getsize(DST) / 1e6
    print('%s -> %s' % (os.path.basename(SRC), os.path.basename(DST)))
    print('  %d materials converted to metallic/roughness, %d foliage cards set to alpha mask'
          % (stats['pbr'], stats['mask']))
    print('  %.1f MB' % size)


if __name__ == '__main__':
    main()
