"""GFF (V3.3) reader for The Witcher 1.

Header (56 bytes):
  0  char type[4]          'GIT ', 'ARE ', 'UTC ', ...
  4  char version[4]       'V3.3'
  8  u32 structTableOffset (56)
 12  u32 structCount
 16  u32 fieldTableOffset
 20  u32 fieldCount
 24  u32 labelTableOffset
 28  u32 labelCount
 32  u32 fieldDataOffset
 36  u32 fieldDataSize
 40  u32 fieldIndicesOffset
 44  u32 fieldIndicesSize
 48  u32 listIndicesOffset
 52  u32 listIndicesSize
Struct entry (12): u32 owner, u32 offset (bytes into field-indices, listed as field index
                   when the struct has one field), u32 fieldCount
Field entry  (12): u32 type, u32 labelIndex, u32 data
Label entry  (16): char label[16]
"""
import struct

BYTE, CHAR, WORD, SHORT, DWORD, INT, DWORD64, INT64, FLOAT, DOUBLE = range(10)
CSTRING, RESREF, LOCSTRING, BINARY, STRUCT, LIST, VECTOR3, VECTOR4 = range(10, 18)

NUMERIC = {BYTE: ('B', 1), CHAR: ('b', 1), WORD: ('H', 2), SHORT: ('h', 2),
           DWORD: ('I', 4), INT: ('i', 4), DWORD64: ('Q', 8), INT64: ('q', 8),
           FLOAT: ('f', 4), DOUBLE: ('d', 8)}


class Gff:
    def __init__(self, data):
        self.data = data
        (self.file_type, self.version, self.struct_off, self.struct_count,
         self.field_off, self.field_count, self.label_off, self.label_count,
         self.fdata_off, self.fdata_size, self.fidx_off, self.fidx_size,
         self.lidx_off, self.lidx_size) = struct.unpack_from('<4s4s12I', data, 0)
        self.labels = []
        for i in range(self.label_count):
            self.labels.append(data[self.label_off + i * 16:self.label_off + i * 16 + 16]
                               .split(b'\x00')[0].decode('latin1'))

    def struct_entry(self, idx):
        return struct.unpack_from('<III', self.data, self.struct_off + idx * 12)

    def field_entry(self, idx):
        return struct.unpack_from('<III', self.data, self.field_off + idx * 12)

    def parse(self, struct_idx=0, depth=0):
        _owner, off, count = self.struct_entry(struct_idx)
        out = {}
        if count == 1:
            indices = [off // 4]
        elif count == 0:
            return out
        else:
            base = self.fidx_off + off
            indices = [struct.unpack_from('<I', self.data, base + i * 4)[0] for i in range(count)]
        for fi in indices:
            ftype, label, value = self.field_entry(fi)
            name = self.labels[label] if label < len(self.labels) else f'?{label}'
            out[name] = self.read_value(ftype, value, depth)
        return out

    def read_value(self, ftype, value, depth):
        if ftype in NUMERIC:
            fmt, size = NUMERIC[ftype]
            return struct.unpack('<' + fmt, struct.pack('<I', value)[:size])[0]
        if ftype == CSTRING:
            base = self.fdata_off + value
            n, = struct.unpack_from('<I', self.data, base)
            return self.data[base + 4:base + 4 + n].decode('utf-8', 'replace')
        if ftype == RESREF:
            base = self.fdata_off + value
            n = self.data[base]
            return self.data[base + 1:base + 1 + n].decode('latin1')
        if ftype == LOCSTRING:
            return self._locstring(value)
        if ftype == BINARY:
            size, = struct.unpack_from('<I', self.data, self.fdata_off + value)
            return self.data[self.fdata_off + value + 4:self.fdata_off + value + 4 + size]
        if ftype == STRUCT:
            return self.parse(value, depth + 1)
        if ftype == LIST:
            size, = struct.unpack_from('<I', self.data, self.lidx_off + value)
            ids = [struct.unpack_from('<I', self.data, self.lidx_off + value + 4 + i * 4)[0]
                   for i in range(size)]
            return [self.parse(i, depth + 1) for i in ids]
        if ftype == VECTOR3:
            return struct.unpack_from('<3f', self.data, self.fdata_off + value)
        if ftype == VECTOR4:
            return struct.unpack_from('<4f', self.data, self.fdata_off + value)
        return ('unknown', ftype, value)

    def _locstring(self, off):
        base = self.fdata_off + off
        total, strref, nstr = struct.unpack_from('<III', self.data, base)
        substrings = {'strref': strref}
        for i in range(nstr):
            sid, length, soff = struct.unpack_from('<III', self.data, base + 12 + i * 12)
            s = self.data[base + soff:base + soff + length]
            substrings[sid] = s.decode('latin1', 'replace')
        return substrings


def parse_git(path_or_bytes):
    data = path_or_bytes
    return Gff(data)
