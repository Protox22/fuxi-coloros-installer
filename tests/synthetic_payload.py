"""Invented LP metadata for tests, with two tiny slot-A partitions."""
import hashlib
import struct


def lp_prefix():
    raw = bytearray(1024 * 1024)
    geometry = bytearray(52)
    struct.pack_into('<II', geometry, 0, 0x616c4467, 52)
    struct.pack_into('<III', geometry, 40, 65536, 3, 4096)
    geometry[8:40] = hashlib.sha256(geometry).digest()
    for start in (4096, 8192): raw[start:start+52] = geometry
    partitions = b''.join(struct.pack('<36s4I', name, 1, i, 1, 0) for i, name in enumerate((b'system_a', b'vendor_a')))
    extents = b''.join(struct.pack('<QIQI', 8, 0, 2048 + i * 8, 0) for i in range(2))
    groups = struct.pack('<36sIQ', b'test_group', 0, 11811160064)
    devices = struct.pack('<QIIQ36sI', 2048, 1048576, 0, 11811160064, b'super', 0)
    tables = partitions + extents + groups + devices
    header = bytearray(128)
    struct.pack_into('<IHHI', header, 0, 0x414c5030, 10, 0, 128)
    struct.pack_into('<I', header, 44, len(tables))
    header[48:80] = hashlib.sha256(tables).digest()
    offset = 0
    for descriptor, count, size in ((80, 2, 52), (92, 2, 24), (104, 1, 48), (116, 1, 64)):
        struct.pack_into('<III', header, descriptor, offset, count, size)
        offset += count * size
    header[12:44] = hashlib.sha256(header).digest()
    for i in range(6):
        start = 12288 + i * 65536
        raw[start:start+128] = header
        raw[start+128:start+128+len(tables)] = tables
    return bytes(raw)
