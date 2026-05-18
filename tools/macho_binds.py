#!/usr/bin/env python
"""
Shared Mach-O bind-stream parsing for tools/.
"""
import struct

LC_LOAD_DYLIB        = 0x0C
LC_LOAD_WEAK_DYLIB   = 0x80000018
LC_REEXPORT_DYLIB    = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_LAZY_LOAD_DYLIB   = 0x20
LC_DYLD_INFO         = 0x22
LC_DYLD_INFO_ONLY    = 0x80000022
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION      = 0x32
DYLIB_LCS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
             LC_LOAD_UPWARD_DYLIB, LC_LAZY_LOAD_DYLIB}

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH = {0xFEEDFACE: ('<', 28), 0xCEFAEDFE: ('>', 28),
      0xFEEDFACF: ('<', 32), 0xCFFAEDFE: ('>', 32)}

B_OP_MASK    = 0xF0
B_IMM_MASK   = 0x0F
B_DONE              = 0x00
B_SET_ORD_IMM       = 0x10
B_SET_ORD_ULEB      = 0x20
B_SET_SPECIAL_IMM   = 0x30
B_SET_FLAGS_IMM     = 0x40
B_SET_TYPE_IMM      = 0x50
B_SET_ADDEND_SLEB   = 0x60
B_SET_SEG_OFF_ULEB  = 0x70
B_ADD_ADDR_ULEB     = 0x80
B_DO_BIND           = 0x90
B_DO_BIND_AAU       = 0xA0
B_DO_BIND_AAIS      = 0xB0
B_DO_BIND_ULEB_TS   = 0xC0

BIND_SYMBOL_FLAGS_WEAK_IMPORT = 0x01


def parse_uleb(data, off):
    val, shift = 0, 0
    while True:
        b = data[off]; off += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80): return val, off
        shift += 7

def parse_sleb(data, off):
    val, shift = 0, 0
    while True:
        b = data[off]; off += 1
        val |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            if b & 0x40: val |= -(1 << shift)
            return val, off


def iter_slices(data):
    """Yield (slice_offset, endian, header_size) for each Mach-O slice in
    the file. Handles thin and fat (32 / 64-bit fat headers)."""
    magic = struct.unpack('>I', bytes(data[:4]))[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        is64 = (magic == FAT_MAGIC_64)
        nfat = struct.unpack('>I', bytes(data[4:8]))[0]
        for i in range(nfat):
            ao = 8 + i * (32 if is64 else 20)
            if is64:
                off = struct.unpack('>Q', bytes(data[ao+8:ao+16]))[0]
            else:
                off = struct.unpack('>I', bytes(data[ao+8:ao+12]))[0]
            sm = struct.unpack_from('<I', data, off)[0]
            if sm in MH:
                yield (off,) + MH[sm]
    else:
        if magic in MH or magic in (k for k in MH):
            sm = struct.unpack_from('<I', data, 0)[0]
            if sm in MH:
                yield (0,) + MH[sm]


def load_commands(data, slice_off, endian, hsize):
    """Yield (lc_offset, cmd, cmdsize) for each load command in a slice."""
    ncmds = struct.unpack_from(endian + 'I', data, slice_off + 16)[0]
    lc = slice_off + hsize
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + 'II', data, lc)
        yield lc, cmd, cmdsize
        lc += cmdsize


def collect_dylibs(data, slice_off, endian, hsize):
    """Return list of (ordinal, lc_offset, lc_cmd, install_name) for each
    LC_LOAD*_DYLIB in the slice. ordinal is 1-based."""
    out = []
    ord_n = 0
    for lc, cmd, cmdsize in load_commands(data, slice_off, endian, hsize):
        if cmd in DYLIB_LCS:
            ord_n += 1
            name_off = struct.unpack_from(endian + 'I', data, lc + 8)[0]
            p = lc + name_off
            end = data.find(b'\x00', p)
            install_name = bytes(data[p:end]).decode('utf-8', 'replace')
            out.append((ord_n, lc, cmd, install_name))
    return out


def get_dyld_info(data, slice_off, endian, hsize):
    """Return (rebase_off, rebase_size, bind_off, bind_size, weak_off,
    weak_size, lazy_off, lazy_size, export_off, export_size) for the
    LC_DYLD_INFO[_ONLY] in this slice, or None."""
    for lc, cmd, cmdsize in load_commands(data, slice_off, endian, hsize):
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            return struct.unpack_from(endian + '10I', data, lc + 8)
    return None


def walk_bind_stream(data, start, size):
    """Yield records of every bind in a bind/weak_bind/lazy_bind stream:
        {'op_byte_offset': N,    # offset of the SET_FLAGS_IMM byte
         'ordinal': int,          # current dylib ordinal (or negative special)
         'symbol': str,
         'flags': int,
         'ord_op_offset': N or None,  # offset of last SET_ORDINAL byte (for rewriting)
         'ord_op_kind': 'imm'|'uleb'|'special'|None}"""
    if size == 0:
        return
    p, end = start, start + size
    cur_ord = 0
    last_ord_off = None
    last_ord_kind = None
    while p < end:
        b = data[p]
        op, imm = b & B_OP_MASK, b & B_IMM_MASK
        if op == B_DONE:
            p += 1
        elif op == B_SET_ORD_IMM:
            cur_ord = imm
            last_ord_off, last_ord_kind = p, 'imm'
            p += 1
        elif op == B_SET_ORD_ULEB:
            last_ord_off, last_ord_kind = p, 'uleb'
            p += 1
            cur_ord, p = parse_uleb(data, p)
        elif op == B_SET_SPECIAL_IMM:
            cur_ord = imm - 16 if (imm & 0x8) else imm
            last_ord_off, last_ord_kind = p, 'special'
            p += 1
        elif op == B_SET_FLAGS_IMM:
            flags = imm
            name_p = p + 1
            ne = data.find(b'\x00', name_p)
            symbol = bytes(data[name_p:ne]).decode('utf-8', 'replace')
            yield {
                'op_byte_offset': p,
                'ordinal': cur_ord,
                'symbol': symbol,
                'flags': flags,
                'ord_op_offset': last_ord_off,
                'ord_op_kind': last_ord_kind,
            }
            p = ne + 1
        elif op == B_SET_TYPE_IMM:
            p += 1
        elif op == B_SET_ADDEND_SLEB:
            p += 1
            _, p = parse_sleb(data, p)
        elif op == B_SET_SEG_OFF_ULEB:
            p += 1
            _, p = parse_uleb(data, p)
        elif op == B_ADD_ADDR_ULEB:
            p += 1
            _, p = parse_uleb(data, p)
        elif op == B_DO_BIND:
            p += 1
        elif op == B_DO_BIND_AAU:
            p += 1
            _, p = parse_uleb(data, p)
        elif op == B_DO_BIND_AAIS:
            p += 1
        elif op == B_DO_BIND_ULEB_TS:
            p += 1
            _, p = parse_uleb(data, p)
            _, p = parse_uleb(data, p)
        else:
            return
