#!/usr/bin/env python
# weaken_dylibs.py <binary> <path-substring-or-exact> [...]
# For each target path:
#   1. Flip LC_LOAD_DYLIB -> LC_LOAD_WEAK_DYLIB
#   2. In every bind/weak_bind/lazy_bind opcode stream, find bind entries
#      whose source dylib ordinal == that target's ordinal, and OR
#      BIND_SYMBOL_FLAGS_WEAK_IMPORT (0x1) into the corresponding
#      BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM byte.
# Writes <binary>.patched.
import struct, sys, os

LC_LOAD_DYLIB      = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB  = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_LAZY_LOAD_DYLIB = 0x20
LC_DYLD_INFO       = 0x22
LC_DYLD_INFO_ONLY  = 0x80000022

DYLIB_LCS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
             LC_LOAD_UPWARD_DYLIB, LC_LAZY_LOAD_DYLIB}

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH = {0xFEEDFACE: ('<', 28), 0xCEFAEDFE: ('>', 28),
      0xFEEDFACF: ('<', 32), 0xCFFAEDFE: ('>', 32)}

BIND_OPCODE_MASK    = 0xF0
BIND_IMM_MASK       = 0x0F
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


def walk_and_weaken(data, start, size, target_ords, label):
    if size == 0: return 0
    p, end = start, start + size
    cur_ord = 0
    changed = 0
    while p < end:
        b = data[p]
        op, imm = b & BIND_OPCODE_MASK, b & BIND_IMM_MASK
        if op == B_DONE:
            p += 1
        elif op == B_SET_ORD_IMM:
            cur_ord = imm; p += 1
        elif op == B_SET_ORD_ULEB:
            p += 1; cur_ord, p = parse_uleb(data, p)
        elif op == B_SET_SPECIAL_IMM:
            cur_ord = imm - 16 if (imm & 0x8) else imm
            p += 1
        elif op == B_SET_FLAGS_IMM:
            if cur_ord in target_ords:
                # OR in WEAK_IMPORT bit (0x1)
                if (data[p] & 0x01) == 0:
                    name_start = p + 1
                    ne = data.find(b'\x00', name_start)
                    name = bytes(data[name_start:ne]).decode('utf-8', 'replace')
                    data[p] = data[p] | 0x01
                    print("  [%s] weakened bind: %s (ord=%d)" % (label, name, cur_ord))
                    changed += 1
            p += 1
            while data[p] != 0: p += 1
            p += 1
        elif op == B_SET_TYPE_IMM:
            p += 1
        elif op == B_SET_ADDEND_SLEB:
            p += 1; _, p = parse_sleb(data, p)
        elif op == B_SET_SEG_OFF_ULEB:
            p += 1; _, p = parse_uleb(data, p)
        elif op == B_ADD_ADDR_ULEB:
            p += 1; _, p = parse_uleb(data, p)
        elif op == B_DO_BIND:
            p += 1
        elif op == B_DO_BIND_AAU:
            p += 1; _, p = parse_uleb(data, p)
        elif op == B_DO_BIND_AAIS:
            p += 1
        elif op == B_DO_BIND_ULEB_TS:
            p += 1
            _, p = parse_uleb(data, p)
            _, p = parse_uleb(data, p)
        else:
            print("  [%s] unknown bind opcode 0x%x at off=%d, stopping" % (label, b, p - start))
            break
    return changed


def patch_slice(data, off, targets):
    magic = struct.unpack_from('<I', data, off)[0]
    if magic not in MH: return 0
    endian, hsize = MH[magic]
    ncmds = struct.unpack_from(endian + 'I', data, off + 16)[0]
    lc = off + hsize
    dylib_ord = 0
    target_ords = set()
    weakened_lcs = 0
    dyld_info_lcs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + 'II', data, lc)
        if cmd in DYLIB_LCS:
            dylib_ord += 1
            name_off = struct.unpack_from(endian + 'I', data, lc + 8)[0]
            p = lc + name_off
            ep = data.find(b'\x00', p)
            path = bytes(data[p:ep]).decode('utf-8', 'replace')
            for t in targets:
                if t in path or t == path:
                    if cmd == LC_LOAD_DYLIB:
                        struct.pack_into(endian + 'I', data, lc, LC_LOAD_WEAK_DYLIB)
                        print("  weakened load: %s (ord=%d)" % (path, dylib_ord))
                        weakened_lcs += 1
                    target_ords.add(dylib_ord)
                    break
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            dyld_info_lcs.append(lc)
        lc += cmdsize

    if not target_ords:
        print("  (no matching dylib load commands)")
        return 0

    total_binds_changed = 0
    for lc in dyld_info_lcs:
        # dyld_info_command layout (after cmd/cmdsize):
        # rebase_off, rebase_size, bind_off, bind_size, weak_bind_off, weak_bind_size,
        # lazy_bind_off, lazy_bind_size, export_off, export_size
        fields = struct.unpack_from(endian + '10I', data, lc + 8)
        rebase_off, rebase_size, bind_off, bind_size, \
            weak_off, weak_size, lazy_off, lazy_size, _, _ = fields
        total_binds_changed += walk_and_weaken(data, off + bind_off, bind_size, target_ords, "bind")
        total_binds_changed += walk_and_weaken(data, off + weak_off, weak_size, target_ords, "weak_bind")
        total_binds_changed += walk_and_weaken(data, off + lazy_off, lazy_size, target_ords, "lazy_bind")

    print("  -> %d load commands flipped, %d bind entries weakened" % (weakened_lcs, total_binds_changed))
    return weakened_lcs + total_binds_changed


def main():
    if len(sys.argv) < 3:
        print("usage: %s <binary> <path-or-substring> [...]" % sys.argv[0])
        sys.exit(1)
    binary = sys.argv[1]
    targets = list(sys.argv[2:])
    with open(binary, 'rb') as f:
        data = bytearray(f.read())
    magic = struct.unpack('>I', bytes(data[:4]))[0]
    total = 0
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack('>I', bytes(data[4:8]))[0]
        is64 = magic == FAT_MAGIC_64
        for i in range(nfat):
            ao = 8 + i * (32 if is64 else 20)
            if is64:
                slice_off = struct.unpack('>Q', bytes(data[ao+8:ao+16]))[0]
            else:
                slice_off = struct.unpack('>I', bytes(data[ao+8:ao+12]))[0]
            print("slice %d @ 0x%x:" % (i, slice_off))
            total += patch_slice(data, slice_off, targets)
    else:
        print("thin binary:")
        total += patch_slice(data, 0, targets)
    out = binary + '.patched'
    with open(out, 'wb') as f:
        f.write(bytes(data))
    os.chmod(out, 0o755)
    print("wrote %s (%d total mods)" % (out, total))
    if total == 0:
        sys.exit(2)

if __name__ == '__main__':
    main()
