import sys, struct, math, json, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from mdb import MDB, R

W1DUMP = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), '.w1cache')


class NodeInfo:
    pass


def load(path):
    m = MDB(path)
    d = m.d
    # attach controller data
    for n in m.nodes:
        n['pos_l'] = (0.0, 0.0, 0.0)
        n['quat'] = (0.0, 0.0, 0.0, 1.0)
        n['scale_l'] = 1.0
    # re-walk to get cd arrays (need offsets). reparse lightly:
    for n in m.nodes:
        p = n['pos']
        r = R(d); r.seek(p + 116)
        ckOff = r.u32(); ckCnt = r.u32(); r.u32()
        cdOff = r.u32(); cdCnt = r.u32(); r.u32()
        data = struct.unpack_from('<%df' % cdCnt, d, m.offModelData + cdOff) if cdCnt else ()
        for (t, rc, cc, di) in n['controllers']:
            if t == 84 and cc == 3 and di + 2 < len(data):
                n['pos_l'] = (data[di], data[di+1], data[di+2])
            elif t == 96 and cc == 4 and di + 3 < len(data):
                n['quat'] = (data[di], data[di+1], data[di+2], data[di+3])
            elif t == 184 and cc == 1 and di < len(data):
                n['scale_l'] = data[di]
    # build tree
    root = m.nodes[0]
    m.root = root
    return m


def quat_to_mat(q):
    x, y, z, w = q
    n = math.sqrt(x*x + y*y + z*z + w*w)
    if n == 0:
        return np.eye(4)
    x, y, z, w = x/n, y/n, z/n, w/n
    return np.array([
        [1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w),   0],
        [2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w),   0],
        [2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y), 0],
        [0, 0, 0, 1]], dtype=np.float64)


def local_mat(n):
    T = np.eye(4); T[:3, 3] = n['pos_l']
    Rm = quat_to_mat(n['quat'])
    S = np.eye(4); S[0, 0] = S[1, 1] = S[2, 2] = n['scale_l']
    return T @ Rm @ S


def build_world(m):
    def rec(n, parent):
        n['world'] = parent @ local_mat(n)
        for c in n['children']:
            rec(c, n['world'])
    rec(m.root, np.eye(4))


def mesh_bbox(m, n):
    me = n['mesh']
    a = me['arr']
    vc = a['v'][1]
    if vc == 0:
        return None
    xyz = np.frombuffer(m.d, dtype='<f4', count=vc*3, offset=m.offRawData + a['v'][0]).reshape(-1, 3)
    hom = np.hstack([xyz, np.ones((vc, 1))])
    w = (n['world'] @ hom.T).T[:, :3]
    return w.min(0), w.max(0), xyz, w


if __name__ == '__main__':
    m = load(os.path.join(W1DUMP, 'gl09.2070.mdb'))
    build_world(m)
    lo = np.array([1e9]*3); hi = np.array([-1e9]*3)
    tot = 0
    for n in m.nodes:
        me = n.get('mesh')
        if not me: continue
        bb = mesh_bbox(m, n)
        if bb is None: continue
        tot += len(bb[2])
        lo = np.minimum(lo, bb[0]); hi = np.maximum(hi, bb[1])
    print('world bounds after transforms:', lo, hi)
    print('total verts', tot)
    # sample node transforms
    for n in m.nodes[:3]:
        print(n['name'], n['pos_l'], n['quat'], n['world'][:3, 3])
    print('root', m.root['name'], m.root['pos_l'])
