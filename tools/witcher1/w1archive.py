"""Witcher 1 (Aurora) KEY/BIF/ERF reader.

Formats in The Witcher 1 Enhanced Edition:
  KEY V1.1 : resref -> (type id, index into a BIF)
  BIFFV1.1 : 20-byte header, 20-byte entries, resource index == position
  MOD V1.0 : ERF-style container, 160-byte header, 24-byte keys, 8-byte resource table
"""
import struct, os


class Bif:
    def __init__(self, path):
        self.path = path
        self._data = None
        with open(path, 'rb') as f:
            raw = f.read()
        sig, count, _a, _b = struct.unpack_from('<8sIII', raw, 0)
        assert sig.startswith(b'BIFF'), (path, sig)
        self.count = count
        self.entries = []  # index -> (offset, size, bif_type)
        for i in range(count):
            o = 20 + i * 20
            _id, _pad, off, size, rtype = struct.unpack_from('<IIIII', raw, o)
            self.entries.append((off, size, rtype))
        self._data = raw

    def read(self, index):
        off, size, rtype = self.entries[index]
        return self._data[off:off + size]


class Key:
    def __init__(self, path):
        self.path = path
        d = open(path, 'rb').read()
        assert d[:8].startswith(b'KEY '), (path, d[:8])
        bif_count, key_count, _a, off_filetab, off_keytab = struct.unpack_from('<5I', d, 8)
        self.bifs = []
        for i in range(bif_count):
            _size, nameoff, _namelen = struct.unpack_from('<III', d, off_filetab + i * 12)
            # names are packed back-to-back with no separator, and the length field
            # is unreliable by a byte, so read to the .bif/.biff suffix instead.
            raw = d[nameoff:nameoff + 64].decode('latin1')
            low = raw.lower()
            p4, p3 = low.find('.biff'), low.find('.bif')
            if p4 != -1 and (p3 == -1 or p4 <= p3):
                end = p4 + 5
            elif p3 != -1:
                end = p3 + 4
            else:
                end = len(raw.rstrip('\x00'))
            name = raw[:end]
            self.bifs.append(name)
        self.entries = []  # (resref, type, bif index, resource index)
        for i in range(key_count):
            o = off_keytab + i * 26
            resref = d[o:o + 16].split(b'\x00')[0].decode('latin1').lower()
            rtype, rid = struct.unpack_from('<HI', d, o + 16)
            self.entries.append((resref, rtype, rid))
        self._bifs = {}

    @property
    def dir(self):
        return os.path.dirname(self.path)

    def bif(self, name):
        if name not in self._bifs:
            p = os.path.join(self.dir, name)
            if not os.path.exists(p):
                alt = os.path.join(self.dir, name.replace('.biff', '.bif'))
                p = alt if os.path.exists(alt) else p
            self._bifs[name] = Bif(p) if os.path.exists(p) else None
        return self._bifs[name]


class Erf:
    """MOD V1.0 / ERF V1.0 container (areas live here)."""

    def __init__(self, path):
        self.path = path
        d = open(path, 'rb').read()
        assert d[:8].startswith((b'MOD', b'ERF')), (path, d[:8])
        count, off_keys, _off_str, off_res = struct.unpack_from('<IIII', d, 16)
        self.count = count
        self.entries = {}
        for i in range(count):
            o = off_keys + i * 24
            resref = d[o:o + 16].split(b'\x00')[0].decode('latin1').lower()
            rid, rtype = struct.unpack_from('<IH', d, o + 16)
            off, size = struct.unpack_from('<II', d, off_res + i * 8)
            self.entries[resref] = (rid, rtype, off, size)
        self._data = d

    def read(self, resref):
        rid, rtype, off, size = self.entries[resref]
        return self._data[off:off + size], rtype

    def list(self):
        return self.entries


# Aurora resource type ids used by The Witcher 1.
TYPES = {
    1: 'bmp', 3: 'tga', 4: 'wav', 6: 'plt', 7: 'ini', 8: 'bmu', 9: 'mp3', 10: 'ttf',
    11: 'nwm', 12: 'bik', 13: 'ndb', 14: 'txi',
    2002: 'mdl', 2003: 'mdx', 2005: 'mdb', 2007: 'mds', 2008: 'mda',
    2010: 'ifo', 2012: 'are', 2013: 'set', 2014: 'nss', 2015: 'ncs',
    2016: 'wok', 2017: '2da', 2018: 'tlk', 2019: 'mod', 2020: 'utc',
    2021: 'uti', 2022: 'txi', 2023: 'utm', 2025: 'utp', 2026: 'uts', 2027: 'utt',
    2029: 'git', 2030: 'gic', 2031: 'guic', 2032: 'utw', 2033: 'uta', 2034: 'jrl',
    2035: 'utd', 2036: 'utx', 2037: 'fac', 2038: 'utr', 2039: 'trn',
    2041: 'dds', 2042: 'tga', 2045: 'vis', 2046: 'wok',
}
