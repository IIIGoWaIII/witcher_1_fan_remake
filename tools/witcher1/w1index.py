import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from w1archive import Key

G = os.environ.get('W1_DATA', r'E:\Games\GOG Galaxy\Games\The Witcher Enhanced Edition\Data')


class Index:
    """main.key: key entries are ordered by bif, and the u32 is the local index."""

    def __init__(self, keypath):
        self.key = Key(keypath)
        self.bifs = [(n, self.key.bif(n)) for n in self.key.bifs]
        self.bifs = [(n, b) for n, b in self.bifs if b is not None]
        self.entries = []   # (resref, type, bifname, index)
        bi = 0
        expected = 0
        for resref, rtype, rid in self.key.entries:
            if rid == 0 and expected != 0:
                bi += 1
                expected = 0
            while bi < len(self.bifs) and rid >= self.bifs[bi][1].count:
                bi += 1
            expected = rid + 1
            if bi >= len(self.bifs):
                break
            self.entries.append((resref, rtype, self.bifs[bi][0], rid))
        self.by_name = collections.defaultdict(list)
        for e in self.entries:
            self.by_name[e[0]].append(e)
        self._cache = {}

    def bif(self, name):
        if name not in self._cache:
            self._cache[name] = dict(self.bifs)[name]
        return self._cache[name]

    def get(self, resref, rtype=None):
        hits = self.by_name.get(resref.lower())
        if not hits:
            return None
        if rtype is not None:
            hits = [h for h in hits if h[1] == rtype] or hits
        r, t, bname, i = hits[0]
        return self.bif(bname).read(i), t, bname

    def find(self, needle, rtype=None):
        return [e for e in self.entries if needle in e[0] and (rtype is None or e[1] == rtype)]


if __name__ == '__main__':
    idx = Index(os.path.join(G, 'main.key'))
    print('entries', len(idx.entries), 'of', len(idx.key.entries))
    per_bif = collections.Counter(e[2] for e in idx.entries)
    for n, b in idx.bifs:
        print(f'{n:20s} keyed={per_bif[n]:6d} entries={b.count:6d}')
