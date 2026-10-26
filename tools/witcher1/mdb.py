import struct, sys, os, json

class R:
    def __init__(self, d): self.d = d; self.p = 0
    def seek(self, p): self.p = p
    def skip(self, n): self.p += n
    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]; self.p += 4; return v
    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v
    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]; self.p += 2; return v
    def u8(self):
        v = self.d[self.p]; self.p += 1; return v
    def f32(self):
        v = struct.unpack_from('<f', self.d, self.p)[0]; self.p += 4; return v
    def s(self, n):
        raw = self.d[self.p:self.p+n]; self.p += n
        return raw.split(b'\0')[0].replace(b'\xdc', b'').decode('latin-1').strip()

def adef(r):
    off = r.u32(); used = r.u32(); alloc = r.u32(); return off, used

class MDB:
    def __init__(self, path):
        self.path = path
        self.d = open(path, 'rb').read()
        self.nodes = []
        self.parse_header()
        self.parse_node(self.rootOff + self.offModelData, None, 0)

    def parse_header(self):
        r = R(self.d); d = self.d
        assert r.u8() == 0, 'not mdb'
        r.seek(4)
        self.ver = r.u32() & 0x0FFFFFFF
        cnt = r.u32(); r.skip(4)
        self.modelDataSize = r.u32(); r.skip(4)
        if self.ver == 133:
            self.offRawData = r.u32() + 32; self.offModelData = 32
        else:
            self.offRawData = 32; self.offModelData = 32
            self.offTexData = r.u32() + 32; self.texSize = r.u32()
        r.skip(8)
        self.name = r.s(64)
        self.rootOff = r.u32()
        r.skip(32)
        self.ntype = r.u8(); r.skip(3); r.skip(48)
        self.firstLOD = r.f32(); self.lastLOD = r.f32()
        r.skip(16)
        self.detailMap = r.s(64); r.skip(4)
        self.scale = r.f32()
        self.superModel = r.s(64); r.skip(16)

    def parse_node(self, pos, parent, depth):
        r = R(self.d); r.seek(pos)
        n = {'pos': pos, 'depth': depth}
        r.skip(24)
        n['inheritColor'] = r.u32()
        n['nodeNumber'] = r.u32()
        n['name'] = r.s(64)
        r.skip(8)
        childrenOff, childrenCnt = adef(r)
        ckOff, ckCnt   = adef(r)
        cdOff, cdCnt   = adef(r)
        ctrl = []
        if ckCnt:
            r2 = R(self.d)
            r2.seek(self.offModelData + ckOff)
            for i in range(ckCnt):
                t = r2.u32(); rc = r2.u16(); ti = r2.u16(); di = r2.u16(); cc = r2.u8(); r2.skip(1)
                ctrl.append((t, rc, cc, di))
        n['controllers'] = ctrl
        r.seek(pos + 144)  # after the 3 array defs + skip4
        n['imposterGroup'] = r.u32()
        n['fixedRot'] = r.u32()
        n['minLOD'] = r.i32(); n['maxLOD'] = r.i32()
        n['type'] = r.u32()
        n['children'] = []
        mtype = n['type']
        if mtype == 0x21:
            n['mesh'] = self.read_mesh(pos + 164)
        elif mtype == 0x8001:
            n['mesh'] = self.read_texturepaint(pos + 164)
        self.nodes.append(n)
        children = []
        if childrenCnt:
            r3 = R(self.d); r3.seek(self.offModelData + childrenOff)
            children = [r3.u32() for _ in range(childrenCnt)]
        for c in children:
            ch = self.parse_node(self.offModelData + c, n, depth+1)
            n['children'].append(ch)
        return n

    def read_mesh(self, p):
        r = R(self.d); r.seek(p)
        r.skip(4); r.skip(4)
        offMeshArrays = r.u32()
        r.skip(4)
        bmin = [r.f32() for _ in range(3)]
        bmax = [r.f32() for _ in range(3)]
        r.skip(28)
        volFog = r.f32(); r.skip(16)
        diffuse = [r.f32() for _ in range(3)]
        ambient = [r.f32() for _ in range(3)]
        ttr = [r.f32() for _ in range(3)]
        shininess = r.f32()
        shadow = r.u32() == 1; beaming = r.u32() == 1; render = r.u32() == 1
        transpHint = r.u32() == 1
        r.skip(4)
        tex = [r.s(64) for _ in range(4)]
        tileFade = r.u32() == 1
        controlFade = r.u8() == 1; lightMapped = r.u8() == 1; rotateTex = r.u8() == 1
        r.skip(1)
        transpShift = r.f32()
        defRenderList = r.u32(); preserveVCol = r.u32()
        fourCC = struct.unpack_from('>I', self.d, r.p)[0]; r.p += 4
        r.skip(4)
        depthOffset = r.f32(); corona = r.f32(); fadeStart = r.f32()
        r.u8(); r.skip(3)
        enlargeStart = r.f32()
        r.u8(); r.skip(3)
        damp = r.f32()
        blendGroup = r.u32()
        dnLight = r.u8() == 1
        dnTrans = r.s(200)
        ignoreHit = r.u8() == 1; needsRefl = r.u8() == 1; r.skip(1)
        rpn = [r.f32() for _ in range(3)]
        rpd = r.f32()
        r.u8(); r.u8(); r.u8(); r.u8()
        lightMap = r.s(64)
        r.u8(); r.u8(); r.u8(); r.skip(1)
        detailScape = r.f32()
        offTexInfo = r.u32()
        end = r.p
        # mesh arrays
        a = R(self.d); a.seek(self.offRawData + offMeshArrays)
        a.skip(4)
        arr = {}
        for k in ['v', 'n', 't', 'b', 'uv0', 'uv1', 'uv2', 'uv3', 'unk', 'f']:
            arr[k] = adef(a)
        meta = dict(bmin=bmin, bmax=bmax, diffuse=diffuse, ambient=ambient, shininess=shininess,
                    render=render, shadow=shadow, texture=tex, lightMap=lightMap,
                    dnLight=dnLight, arr=arr, kind='trimesh', end=end, blend=blendGroup,
                    lightMapped=lightMapped, preserveVCol=bool(preserveVCol),
                    tileFade=tileFade, controlFade=controlFade, rotateTex=rotateTex,
                    damp=damp, detailScape=detailScape)
        return meta

    def read_texturepaint(self, p):
        r = R(self.d); r.seek(p)
        layersOff, layersCnt = adef(r)
        r.skip(28)
        offMeshArrays = r.u32()
        sectors = [r.u32() for _ in range(4)]
        bmin = [r.f32() for _ in range(3)]
        bmax = [r.f32() for _ in range(3)]
        diffuse = [r.f32() for _ in range(3)]
        ambient = [r.f32() for _ in range(3)]
        ttr = [r.f32() for _ in range(3)]
        shadow = r.u32() == 1; render = r.u32() == 1
        tileFade = r.u32() == 1
        cf = r.u8(); lm = r.u8(); rt = r.u8(); r.skip(1)
        transpShift = r.f32()
        defRender = r.u32()
        fourCC = struct.unpack_from('>I', self.d, r.p)[0]; r.p += 4
        r.skip(4)
        depthOffset = r.f32()
        blendGroup = r.u32()
        dnLight = r.u8() == 1
        dnTrans = r.s(200)
        ih = r.u8(); nr = r.u8(); r.skip(1)
        rpn = [r.f32() for _ in range(3)]
        rpd = r.f32()
        fc = r.u8(); nss = r.u8(); ir = r.u8(); r.skip(1)
        detailScape = r.f32()
        onlyRefl = r.u8() == 1
        lightMap = r.s(64)
        canDecal = r.u8() == 1; ignoreLODRefl = r.u8() == 1; enableSpec = r.u8() == 1
        end = r.p
        layers = []
        lr = R(self.d)
        for i in range(layersCnt):
            lr.seek(self.offRawData + layersOff + i*52)
            has = lr.u8() == 1
            if not has:
                layers.append(None); continue
            lr.skip(3); lr.skip(4)
            tex = lr.s(32)
            wo, wc = adef(lr)
            layers.append(dict(texture=tex, weights=(wo, wc)))
        a = R(self.d); a.seek(self.offRawData + offMeshArrays)
        a.skip(4)
        arr = {}
        for k in ['v', 'n', 't', 'b', 'uv0', 'uv1', 'uv2', 'uv3', 'unk', 'f']:
            arr[k] = adef(a)
        return dict(bmin=bmin, bmax=bmax, diffuse=diffuse, ambient=ambient, render=render,
                    shadow=shadow, lightMap=lightMap, dnLight=dnLight, arr=arr,
                    kind='paint', layers=layers, blend=blendGroup, end=end)

if __name__ == '__main__':
    m = MDB(sys.argv[1])
    print(f"mdb {m.name!r} ver={m.ver} nodes={len(m.nodes)}")
    from collections import Counter
    print('types:', Counter(hex(n['type']) for n in m.nodes))
    for n in m.nodes:
        if 'mesh' in n:
            me = n['mesh']
            print(f"  [{n['depth']}] {n['name']:34s} type={me['kind']:7s} v={me['arr']['v'][1]:7d} f={me['arr']['f'][1]:7d} "
                  f"uv0={me['arr']['uv0'][1]:7d} uv1={me['arr']['uv1'][1]:7d} bmin={['%.1f'%x for x in me['bmin']]} bmax={['%.1f'%x for x in me['bmax']]}")
        else:
            print(f"  [{n['depth']}] {n['name']:34s} type={hex(n['type'])}")
