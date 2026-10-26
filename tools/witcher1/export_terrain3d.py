"""Bake the Vizima outskirts ground into Terrain3D data.

Outputs, in assets/terrain3d/vizima_test/:

    height.r32      32-bit float heights, 1 m grid
    control.r32     Terrain3D control map bitfield, 1 m grid
    lightmap_p.png  world-projected noon ground lightmap, 0.5 m/px
    terrain.json    grid rectangles and texture order

The height and control grids start at (1280, -2048), padded to Terrain3D
region boundaries with region_size 256 and vertex_spacing 1.0.

Texture layers are reconstructed from the top two of the four layers the
original W1T shader uses. Coverage of all four is baked into the lightmap so
the ground keeps the original brightness. The lightmap is sampled from the
original baked noon pages through each triangle's UV0.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "witcher1"))

from mdbtree import load, build_world
from w1gltf import C, AREA_OFFSET
from w1mesh import mesh_arrays, layer_weights, top4_colors

OUT = os.path.join(ROOT, "assets", "terrain3d", "vizima_test")
TEXTURE_DIR = os.path.join(ROOT, "assets", "witcher1", "textures")
NORMALIZED_DIR = os.path.join(OUT, "textures")
LIGHTMAP_DIR = os.path.join(ROOT, "assets", "witcher1", "lightmaps")

RES = 1.0
X0, Z0 = 1024.0, -2048.0
W, H = 2048, 1024

LM_RES = 0.5
LM_X0, LM_Z0 = 1280.0, -2048.0
LM_W, LM_H = 2560, 2048

GX = None
GZ = None
GY = None
T = None
T_UV0 = None
T_W4 = None
T_IDS = None
T_LM = None
TEXTURES = None
LM_ARRAYS = None


def encode_control(base, overlay, blend, hole):
    c = (np.uint32(base) & np.uint32(31)) << np.uint32(27)
    c |= (np.uint32(overlay) & np.uint32(31)) << np.uint32(22)
    c |= (np.uint32(np.clip(np.rint(blend * 255.0), 0, 255)) & np.uint32(255)) << np.uint32(14)
    c |= np.uint32(hole) << np.uint32(2)
    return c


def load_scene():
    global GX, GZ, GY, T, T_UV0, T_W4, T_IDS, T_LM, TEXTURES, LM_ARRAYS
    m = load(os.path.join(ROOT, ".w1cache", "gl09.2070.mdb"))
    build_world(m)
    to_world = C @ AREA_OFFSET

    tex_usage = {}
    lm_index = json.load(open(os.path.join(LIGHTMAP_DIR, "index.json")))

    tris = []
    uv0s = []
    w4s = []
    idss = []
    lms = []

    for node in m.nodes:
        me = node.get('mesh')
        if not me or me['kind'] != 'paint':
            continue
        a = mesh_arrays(m, node)
        if a is None:
            continue
        pos = a[0] @ node['world'][:3, :3].T + node['world'][:3, 3]
        pos = pos @ to_world[:3, :3].T + to_world[:3, 3]
        idx = a[4].reshape(-1, 3)
        names, cols, _ = top4_colors(layer_weights(m, me, a[5]), a[5])
        for n in names:
            if n:
                tex_usage[n] = tex_usage.get(n, 0) + 1
        lm_name = (me.get('lightMap') or '').strip()
        if lm_name.upper() in ('NULL', '_SHADER_'):
            lm_name = ''
        tris.append(pos[idx])
        uv0s.append(a[2][idx])
        w4s.append(cols[idx])
        idss.append(np.tile(np.array(names, dtype=object), (len(idx), 1)))
        lms.append(np.full(len(idx), lm_name, dtype=object))

    T = np.concatenate(tris)
    T_UV0 = np.concatenate(uv0s)
    T_W4 = np.concatenate(w4s)
    T_IDS = np.concatenate(idss)
    T_LM = np.concatenate(lms)
    GX = (T[:, :, 0] - X0) / RES
    GZ = (T[:, :, 2] - Z0) / RES
    GY = T[:, :, 1]

    TEXTURES = sorted(tex_usage)
    tex_id = {name: i for i, name in enumerate(TEXTURES)}
    mapped = np.zeros(T_IDS.shape, np.int16)
    for name, tid in tex_id.items():
        mapped[T_IDS == name] = tid
    T_IDS = mapped

    lm_sets = sorted(set(n for n in T_LM if n))
    LM_ARRAYS = {}
    for name in lm_sets:
        entry = lm_index.get(name.lower())
        if not entry:
            raise SystemExit("no lightmap set " + name)
        stem = entry.get('p') or next(iter(entry.values()))
        path = os.path.join(LIGHTMAP_DIR, stem + ".png")
        LM_ARRAYS[name] = np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)
        print("lightmap", name, "->", os.path.basename(path), LM_ARRAYS[name].shape,
              "%.1f MB" % (LM_ARRAYS[name].nbytes / 1e6))
    print("triangles", len(T), "textures", len(TEXTURES), "lightmap sets", len(LM_ARRAYS))


def raster_height_control():
    h = H
    w = W
    height = np.full((h, w), -1e9, np.float32)
    weights = np.zeros((h, w, 4), np.float32)
    ids = np.zeros((h, w, 4), np.int16)
    uv = np.zeros((h, w, 2), np.float32)
    lm = np.full((h, w), -1, np.int16)
    lm_names = sorted(LM_ARRAYS)
    lm_id = {n: i for i, n in enumerate(lm_names)}

    for i in range(len(T)):
        ax, az, bx, bz, cx, cz = GX[i, 0], GZ[i, 0], GX[i, 1], GZ[i, 1], GX[i, 2], GZ[i, 2]
        den = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(den) < 1e-12:
            continue
        ix0 = max(int(np.floor(min(ax, bx, cx))), 0)
        ix1 = min(int(np.ceil(max(ax, bx, cx))), w - 1)
        iz0 = max(int(np.floor(min(az, bz, cz))), 0)
        iz1 = min(int(np.ceil(max(az, bz, cz))), h - 1)
        if ix1 < ix0 or iz1 < iz0:
            continue
        gx, gz = np.meshgrid(np.arange(ix0, ix1 + 1, dtype=np.float32),
                             np.arange(iz0, iz1 + 1, dtype=np.float32))
        w0 = ((bz - cz) * (gx - cx) + (cx - bx) * (gz - cz)) / den
        w1 = ((cz - az) * (gx - cx) + (ax - cx) * (gz - cz)) / den
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if not inside.any():
            continue
        yy = GY[i, 0] * w0 + GY[i, 1] * w1 + GY[i, 2] * w2
        sub = height[iz0:iz1 + 1, ix0:ix1 + 1]
        mask = inside & (yy > sub)
        if not mask.any():
            continue
        sub[mask] = yy[mask]
        weights[iz0:iz1 + 1, ix0:ix1 + 1][mask] = (
            T_W4[i, 0] * w0[mask, None] +
            T_W4[i, 1] * w1[mask, None] +
            T_W4[i, 2] * w2[mask, None])
        ids[iz0:iz1 + 1, ix0:ix1 + 1][mask] = T_IDS[i]
        uv[iz0:iz1 + 1, ix0:ix1 + 1][mask] = (
            T_UV0[i, 0] * w0[mask, None] +
            T_UV0[i, 1] * w1[mask, None] +
            T_UV0[i, 2] * w2[mask, None])
        lm[iz0:iz1 + 1, ix0:ix1 + 1][mask] = lm_id[T_LM[i]]

    ground = height > -1e8
    print("height covered", int(ground.sum()), "of", h * w,
          "range", float(height[ground].min()), float(height[ground].max()))

    order = np.argsort(weights, axis=2)
    top0 = order[:, :, 2]
    top1 = order[:, :, 1]
    w0 = np.take_along_axis(weights, top0[:, :, None], axis=2)[:, :, 0]
    w1 = np.take_along_axis(weights, top1[:, :, None], axis=2)[:, :, 0]
    base = np.take_along_axis(ids, top0[:, :, None], axis=2)[:, :, 0]
    over = np.take_along_axis(ids, top1[:, :, None], axis=2)[:, :, 0]
    total = w0 + w1
    blend = np.where(total > 1e-6, w1 / np.maximum(total, 1e-6), 0.0)
    base = np.where(total > 1e-6, base, ids[:, :, 0])
    over = np.where(total > 1e-6, over, base)
    control = encode_control(base, over, blend, (~ground).astype(np.uint32))
    height = np.where(ground, height, 0.0).astype(np.float32)

    coverage = weights.sum(axis=2)
    coverage[~ground] = 0.0
    return height, control, coverage, uv, lm, lm_names


def raster_lightmap():
    h, w = LM_H, LM_W
    height = np.full((h, w), -1e9, np.float32)
    uv = np.zeros((h, w, 2), np.float32)
    lm = np.full((h, w), -1, np.int16)
    lm_names = sorted(LM_ARRAYS)
    lm_id = {n: i for i, n in enumerate(lm_names)}
    gx_all = (T[:, :, 0] - LM_X0) / LM_RES
    gz_all = (T[:, :, 2] - LM_Z0) / LM_RES

    for i in range(len(T)):
        ax, az, bx, bz, cx, cz = gx_all[i, 0], gz_all[i, 0], gx_all[i, 1], gz_all[i, 1], gx_all[i, 2], gz_all[i, 2]
        den = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(den) < 1e-12:
            continue
        ix0 = max(int(np.floor(min(ax, bx, cx))), 0)
        ix1 = min(int(np.ceil(max(ax, bx, cx))), w - 1)
        iz0 = max(int(np.floor(min(az, bz, cz))), 0)
        iz1 = min(int(np.ceil(max(az, bz, cz))), h - 1)
        if ix1 < ix0 or iz1 < iz0:
            continue
        gx, gz = np.meshgrid(np.arange(ix0, ix1 + 1, dtype=np.float32),
                             np.arange(iz0, iz1 + 1, dtype=np.float32))
        w0 = ((bz - cz) * (gx - cx) + (cx - bx) * (gz - cz)) / den
        w1 = ((cz - az) * (gx - cx) + (ax - cx) * (gz - cz)) / den
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if not inside.any():
            continue
        yy = GY[i, 0] * w0 + GY[i, 1] * w1 + GY[i, 2] * w2
        sub = height[iz0:iz1 + 1, ix0:ix1 + 1]
        mask = inside & (yy > sub)
        if not mask.any():
            continue
        sub[mask] = yy[mask]
        uv[iz0:iz1 + 1, ix0:ix1 + 1][mask] = (
            T_UV0[i, 0] * w0[mask, None] +
            T_UV0[i, 1] * w1[mask, None] +
            T_UV0[i, 2] * w2[mask, None])
        lm[iz0:iz1 + 1, ix0:ix1 + 1][mask] = lm_id[T_LM[i]]

    print("lightmap covered", int((height > -1e8).sum()), "of", h * w)
    out = np.zeros((h, w, 3), np.uint8)
    for k, name in enumerate(lm_names):
        mask = (lm == k) & (height > -1e8)
        if not mask.any():
            continue
        arr = LM_ARRAYS[name]
        lh, lw = arr.shape[:2]
        u = np.clip(uv[mask, 0], 0.0, 1.0)
        v = np.clip(uv[mask, 1], 0.0, 1.0)
        px = u * (lw - 1)
        py = v * (lh - 1)
        x0 = np.floor(px).astype(np.int32)
        y0 = np.floor(py).astype(np.int32)
        x1 = np.minimum(x0 + 1, lw - 1)
        y1 = np.minimum(y0 + 1, lh - 1)
        tx = (px - x0)[:, None]
        ty = (py - y0)[:, None]
        c = (arr[y0, x0] * (1 - tx) * (1 - ty) +
             arr[y0, x1] * tx * (1 - ty) +
             arr[y1, x0] * (1 - tx) * ty +
             arr[y1, x1] * tx * ty)
        out[mask] = np.clip(c, 0, 255).astype(np.uint8)
    return out


def write_textures():
    """Copy the layer textures to one uniform import format.

    Terrain3D requires every albedo texture in the array to share one GPU format.
    The originals mix alpha and opaque PNGs, which the importer turns into BC1 and
    BC3. Copying them as opaque RGB and importing losslessly gives every layer the
    same format at the cost of a little VRAM.
    """
    import hashlib
    os.makedirs(NORMALIZED_DIR, exist_ok=True)
    template = open(os.path.join(LIGHTMAP_DIR, "l09_tera00_p.png.import")).read()
    params = template.split("[params]", 1)[1]
    params = params.replace("compress/high_quality=false", "compress/high_quality=true")
    params = params.replace("mipmaps/generate=false", "mipmaps/generate=true")
    params = params.replace("detect_3d/compress_to=1", "detect_3d/compress_to=0")
    for stem in TEXTURES:
        src = os.path.join(TEXTURE_DIR, stem + ".png")
        dst = os.path.join(NORMALIZED_DIR, stem + ".png")
        Image.open(src).convert("RGB").save(dst)
        res_path = "res://assets/terrain3d/vizima_test/textures/%s.png" % stem
        digest = hashlib.md5(res_path.encode()).hexdigest()
        ctex = "res://.godot/imported/%s.png-%s.ctex" % (stem, digest)
        with open(dst + ".import", "w", newline="\n") as f:
            f.write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n')
            f.write('path="%s"\nmetadata={\n"vram_texture": false\n}\n\n' % ctex)
            f.write('[deps]\n\nsource_file="%s"\ndest_files=["%s"]\n' % (res_path, ctex))
            f.write("[params]\n")
            f.write(params)
    print("normalized textures:", len(TEXTURES))


def main():
    os.makedirs(OUT, exist_ok=True)
    load_scene()
    write_textures()
    height, control, coverage, uv1m, lm1m, _ = raster_height_control()
    height.astype('<f4').tofile(os.path.join(OUT, "height.r32"))
    control.astype('<u4').tofile(os.path.join(OUT, "control.r32"))

    lm_img = raster_lightmap().astype(np.float32)
    # Coverage of the four original layers is baked into the lightmap so the
    # two-layer Terrain3D blend keeps the original brightness.
    cx0 = int(round((LM_X0 - X0) / RES))
    cx1 = int(round((LM_X0 + LM_W * LM_RES - X0) / RES))
    cz0 = int(round((LM_Z0 - Z0) / RES))
    cz1 = int(round((LM_Z0 + LM_H * LM_RES - Z0) / RES))
    cov = coverage[cz0:cz1, cx0:cx1]
    step = int(round(RES / LM_RES))
    cov = np.repeat(np.repeat(cov, step, axis=0), step, axis=1)
    assert cov.shape[:2] == (LM_H, LM_W), (cov.shape, LM_H, LM_W)
    lm_img *= cov[:, :, None]
    Image.fromarray(np.clip(lm_img, 0, 255).astype(np.uint8), "RGB").save(
        os.path.join(OUT, "lightmap_p.png"))

    # Terrain3D color map: the baked lightmap at the 1 m terrain grid, with
    # neutral wetness in alpha. Using the color map instead of a separate
    # sampler2D uniform avoids a D3D12 crash when the foliage instancer is active.
    color = np.zeros((H, W, 4), np.uint8)
    color[:, :, 3] = 128
    lw = int(round((LM_W * LM_RES) / RES))
    lh = int(round((LM_H * LM_RES) / RES))
    cx = int(round((LM_X0 - X0) / RES))
    lm_1m = lm_img[::2, ::2][:lh, :lw]
    color[0:lh, cx:cx + lw, :3] = np.clip(lm_1m, 0, 255).astype(np.uint8)
    color.tofile(os.path.join(OUT, "color.rgba"))

    json.dump({
        "height": {"file": "height.r32", "x0": X0, "z0": Z0, "width": W, "height": H, "spacing": RES},
        "control": {"file": "control.r32", "x0": X0, "z0": Z0, "width": W, "height": H, "spacing": RES},
        "color": {"file": "color.rgba", "x0": X0, "z0": Z0, "width": W, "height": H, "spacing": RES},
        "lightmap": {"file": "lightmap_p.png", "x0": LM_X0, "z0": LM_Z0,
                     "width": LM_W, "height": LM_H, "spacing": LM_RES},
        "textures": TEXTURES,
        "texture_uv_scale": 0.5,
        "region_size": 1024,
        "vertex_spacing": RES,
        "ambient": 0.15,
    }, open(os.path.join(OUT, "terrain.json"), "w"), indent=1)

    for name in ("height.r32", "control.r32", "color.rgba", "lightmap_p.png", "terrain.json"):
        p = os.path.join(OUT, name)
        print("%-16s %8.1f MB" % (name, os.path.getsize(p) / 1e6))


if __name__ == "__main__":
    main()
