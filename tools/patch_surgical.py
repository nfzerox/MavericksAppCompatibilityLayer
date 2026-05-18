#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch_surgical.py <binary> <manifest.json> [--out <out>] [--inject-dylib <path>]

Drives a minimal-impact Mach-O patch from the manifest produced by
diff_imports.py:

  1. Each LC_LOAD_DYLIB whose install_name is in manifest.missing_libraries
     is flipped to LC_LOAD_WEAK_DYLIB so dyld tolerates the missing image.

  2. For every bind/lazy_bind/weak_bind entry whose (lib, symbol) appears in
     manifest.missing_symbols:
       a. The preceding ordinal-setting opcode is rewritten to
          BIND_SPECIAL_DYLIB_FLAT_LOOKUP (-2) so dyld searches all loaded
          images for the symbol. Our injected stub dylib then provides it.
       b. The SET_SYMBOL_TRAILING_FLAGS_IMM byte gets BIND_SYMBOL_FLAGS_WEAK_IMPORT
          OR'd in so missing-and-not-stubbed symbols resolve to NULL instead
          of aborting dyld.

  SET_ORD_IMM(N)   -> single byte 0x3E (SET_SPECIAL_IMM(-2)).
  SET_ORD_ULEB(N)  -> 0x3E + pad bytes 0x51 (SET_TYPE_IMM(POINTER) — a no-op
                      when type is already pointer, which it is for normal
                      data bindings).

Output: <binary>.patched alongside the input, or use --out to specify.
"""
from __future__ import print_function
import sys, json, struct, os
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from macho_binds import (iter_slices, load_commands, collect_dylibs,
                         get_dyld_info, walk_bind_stream,
                         DYLIB_LCS, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
                         BIND_SYMBOL_FLAGS_WEAK_IMPORT)

LC_SEGMENT_64 = 0x19
LC_SEGMENT    = 0x01

B_SET_SPECIAL_FLAT_BYTE = 0x3E  # SET_SPECIAL_IMM with imm -2 (high nibble 0x3, low nibble 0xE = -2 in 4-bit signed)
B_SET_TYPE_POINTER_BYTE = 0x51  # SET_TYPE_IMM with imm = BIND_TYPE_POINTER (1)


def flip_ord_op(data, off, kind):
    """Convert the SET_ORDINAL opcode at `off` to SET_SPECIAL_IMM(-2),
    padding any trailing ULEB bytes with no-op SET_TYPE_IMM(POINTER).
    Returns number of bytes occupied (for caller's accounting)."""
    if kind == 'imm':
        data[off] = B_SET_SPECIAL_FLAT_BYTE
        return 1
    if kind == 'uleb':
        # Length: 1 byte opcode + ULEB-encoded ordinal. Walk the ULEB to
        # discover length.
        n = 1
        p = off + 1
        while data[p] & 0x80:
            n += 1; p += 1
        n += 1  # final byte (top bit clear)
        data[off] = B_SET_SPECIAL_FLAT_BYTE
        for i in range(1, n):
            data[off + i] = B_SET_TYPE_POINTER_BYTE
        return n
    if kind == 'special':
        # Already SET_SPECIAL — leave alone, caller should check whether
        # the existing value already is -2 (flat) before flipping.
        return 1
    raise ValueError("unknown ord_op_kind %r" % kind)


def lowest_data_offset(data, slice_off, endian, hsize):
    """Return the smallest section file offset (>0) in this slice -- the
    end of the load-command area's available slack space. Anything we
    write past sizeofcmds but before this offset is free space."""
    ncmds, sizeofcmds = struct.unpack_from(endian + 'II', data, slice_off + 16)
    p = slice_off + hsize
    lowest = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + 'II', data, p)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from(endian + 'I', data, p + 64)[0]
            for s in range(nsects):
                # section_64 layout: 16(sectname) + 16(segname) + 8(addr)
                # + 8(size) + 4(offset) ...   offset field at section_off + 48
                sect_fileoff = struct.unpack_from(endian + 'I', data,
                                                  p + 72 + s * 80 + 48)[0]
                if sect_fileoff > 0 and (lowest is None or sect_fileoff < lowest):
                    lowest = sect_fileoff
        elif cmd == LC_SEGMENT:
            nsects = struct.unpack_from(endian + 'I', data, p + 48)[0]
            for s in range(nsects):
                # section layout: 16+16+4+4+4 = section_off + 40 holds offset
                sect_fileoff = struct.unpack_from(endian + 'I', data,
                                                  p + 56 + s * 68 + 40)[0]
                if sect_fileoff > 0 and (lowest is None or sect_fileoff < lowest):
                    lowest = sect_fileoff
        p += cmdsize
    return slice_off + (lowest if lowest is not None else 0xFFFFFFFF)


def add_load_dylib(data, slice_off, endian, hsize, dylib_path, log,
                   prepend=False):
    """Insert a new LC_LOAD_DYLIB pointing to `dylib_path`. Default appends
    at the end of the load-command area; prepend=True shifts all existing
    LCs down and writes the new one at offset 0 of the load-command area,
    so dyld processes the new dylib BEFORE any existing dependent.
    Prepending matters when the injected dylib's initializers must run
    before another image's (e.g. kpf_stubs must populate __NSArray0__
    before TSCoreSOS's static initializers read it)."""
    ncmds, sizeofcmds = struct.unpack_from(endian + 'II', data, slice_off + 16)
    lc_start = slice_off + hsize
    lc_end = lc_start + sizeofcmds
    first_data = lowest_data_offset(data, slice_off, endian, hsize)

    path_bytes = dylib_path.encode('utf-8') + b'\0'
    cmdsize = (24 + len(path_bytes) + 7) & ~7

    if lc_end + cmdsize > first_data:
        raise RuntimeError("not enough load-command slack: need %d, have %d"
                           % (cmdsize, first_data - lc_end))

    if prepend:
        # Shift existing LCs down by cmdsize bytes. Use slice copy
        # (Python handles overlap by buffering); then zero the head.
        data[lc_start + cmdsize : lc_end + cmdsize] = bytes(data[lc_start : lc_end])
        write_at = lc_start
    else:
        write_at = lc_end

    # Zero the region first in case there's leftover junk.
    for i in range(write_at, write_at + cmdsize):
        data[i] = 0
    # cmd, cmdsize
    struct.pack_into(endian + 'II', data, write_at, LC_LOAD_DYLIB, cmdsize)
    # name offset (struct dylib starts at write_at+8; the offset is from
    # the start of the load command).
    struct.pack_into(endian + 'I', data, write_at + 8, 24)
    # timestamp, current_version, compatibility_version. compat=0 lets
    # dyld accept stub dylibs that report 0.0.0.
    struct.pack_into(endian + 'III', data, write_at + 12, 2, 0, 0)
    # path string
    data[write_at + 24 : write_at + 24 + len(path_bytes)] = path_bytes

    # Update header
    struct.pack_into(endian + 'I', data, slice_off + 16, ncmds + 1)
    struct.pack_into(endian + 'I', data, slice_off + 20, sizeofcmds + cmdsize)
    log.append("added LC_LOAD_DYLIB %s (cmdsize=%d, %s, slack remaining=%d)" %
               (dylib_path, cmdsize, "prepended" if prepend else "appended",
                first_data - lc_end - cmdsize))


def patch_slice(data, slice_off, endian, hsize, missing_libs, missing_pairs, log):
    dylibs = collect_dylibs(data, slice_off, endian, hsize)
    ord_to_name = {o: n for o, _, _, n in dylibs}

    # 1) Flip LC_LOAD_DYLIB to weak for missing libs
    for ord_n, lc, cmd, install_name in dylibs:
        if install_name in missing_libs and cmd == LC_LOAD_DYLIB:
            struct.pack_into(endian + 'I', data, lc, LC_LOAD_WEAK_DYLIB)
            log.append("flipped LC_LOAD_DYLIB -> WEAK: %s" % install_name)

    info = get_dyld_info(data, slice_off, endian, hsize)
    if info is None:
        return
    _, _, bind_off, bind_sz, weak_off, weak_sz, lazy_off, lazy_sz, _, _ = info

    streams = (("bind", bind_off, bind_sz),
               ("weak_bind", weak_off, weak_sz),
               ("lazy_bind", lazy_off, lazy_sz))

    # 2) First pass: identify ord_op offsets to flip and flag bytes to weaken
    ord_ops_to_flip = {}  # offset -> kind
    flag_byte_offsets = set()
    for label, off, sz in streams:
        if sz == 0:
            continue
        for rec in walk_bind_stream(data, slice_off + off, sz):
            lib = ord_to_name.get(rec['ordinal'])
            if lib is None:
                continue
            if (lib, rec['symbol']) not in missing_pairs:
                continue
            if rec['ord_op_offset'] is not None:
                # Only record if it's a 2-level-namespace ordinal (positive)
                # — special ordinals like flat-lookup are already what we want.
                if rec['ord_op_kind'] in ('imm', 'uleb'):
                    ord_ops_to_flip[rec['ord_op_offset']] = rec['ord_op_kind']
            flag_byte_offsets.add(rec['op_byte_offset'])

    # 3) Apply rewrites
    for off, kind in ord_ops_to_flip.items():
        flip_ord_op(data, off, kind)
    log.append("flipped %d ordinal ops to flat lookup" % len(ord_ops_to_flip))

    for off in flag_byte_offsets:
        data[off] |= BIND_SYMBOL_FLAGS_WEAK_IMPORT
    log.append("weakened %d bind entries" % len(flag_byte_offsets))


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    binary = sys.argv[1]
    manifest_path = sys.argv[2]
    out_path = None
    # Each entry: (path, prepend_flag). Multiple --inject-dylib / --prepend-dylib
    # supported; order of arguments preserved.
    injects = []
    argv = sys.argv[3:]
    while argv:
        a = argv.pop(0)
        if a == '--out':
            out_path = argv.pop(0)
        elif a == '--inject-dylib':
            injects.append((argv.pop(0), False))
        elif a == '--prepend-dylib':
            injects.append((argv.pop(0), True))
        else:
            print("unknown arg:", a, file=sys.stderr); sys.exit(2)
    if out_path is None:
        out_path = binary + '.patched'

    with open(binary, 'rb') as f:
        data = bytearray(f.read())
    with open(manifest_path) as f:
        manifest = json.load(f)

    missing_libs = set(manifest['missing_libraries'])
    missing_pairs = set((s['lib'], s['symbol']) for s in manifest['missing_symbols'])

    log = []
    for slice_off, endian, hsize in iter_slices(data):
        log.append("--- slice @ 0x%x ---" % slice_off)
        patch_slice(data, slice_off, endian, hsize, missing_libs, missing_pairs, log)
        for path, prepend in injects:
            add_load_dylib(data, slice_off, endian, hsize, path, log, prepend=prepend)

    with open(out_path, 'wb') as f:
        f.write(bytes(data))
    os.chmod(out_path, 0o755)
    for line in log:
        print(line)
    print("wrote %s" % out_path)


if __name__ == '__main__':
    main()
