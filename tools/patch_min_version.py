#!/usr/bin/env python
"""
patch_min_version.py <macho> [--min 10.9] [--out <path>]

Rewrites every LC_VERSION_MIN_MACOSX / LC_BUILD_VERSION load command in the
given Mach-O so its minimum-OS field reports `--min` (default 10.9). The
command stays the same size; only the encoded version word changes.

Mavericks 10.9.5 dyld refuses to load binaries that claim a higher
LSMinimumSystemVersion than the kernel. For Keynote 9 (and its bundled
TS/EquationKit frameworks), the value is 10.13 -- everything else about
the load commands is already in the old 16-byte format Mavericks parses.

Encoding (both LCs): minos is a 32-bit nibble-encoded value 0xXXXXYYZZ
where X.Y.Z is e.g. 10.9.0 -> 0x000A0900.

Use `--out` to write to a different file; default is in-place rewrite.
For a directory of binaries, run via a shell loop or the wrapper in
scripts/setup_keynote9_10_9.sh.
"""
import sys, struct, os
sys.path.insert(0, os.path.dirname(__file__))
from macho_binds import (iter_slices, load_commands,
                         LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION)


def encode_version(triple):
    parts = triple.split('.')
    while len(parts) < 3:
        parts.append('0')
    x, y, z = (int(p) for p in parts[:3])
    return (x << 16) | (y << 8) | z


def decode_version(v):
    return "%d.%d.%d" % ((v >> 16) & 0xFFFF, (v >> 8) & 0xFF, v & 0xFF)


def patch_file(path, target_min, out_path=None):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    target = encode_version(target_min)
    changed = []

    for (slice_off, endian, hsize) in iter_slices(data):
        for lc_off, cmd, cmdsize in load_commands(data, slice_off, endian, hsize):
            if cmd == LC_VERSION_MIN_MACOSX:
                # cmd, cmdsize, version, sdk (4 x u32)
                cur = struct.unpack_from(endian + 'I', data, lc_off + 8)[0]
                if cur != target:
                    struct.pack_into(endian + 'I', data, lc_off + 8, target)
                    changed.append("slice@%#x LC_VERSION_MIN_MACOSX %s -> %s"
                                   % (slice_off, decode_version(cur),
                                      decode_version(target)))
            elif cmd == LC_BUILD_VERSION:
                # cmd, cmdsize, platform, minos, sdk, ntools (4 x u32, then tools)
                cur = struct.unpack_from(endian + 'I', data, lc_off + 12)[0]
                if cur != target:
                    struct.pack_into(endian + 'I', data, lc_off + 12, target)
                    changed.append("slice@%#x LC_BUILD_VERSION minos %s -> %s"
                                   % (slice_off, decode_version(cur),
                                      decode_version(target)))

    if not changed:
        return False, []

    out = out_path or path
    with open(out, 'wb') as f:
        f.write(data)
    os.chmod(out, os.stat(path).st_mode)
    return True, changed


def main():
    args = list(sys.argv[1:])
    target_min = '10.9'
    out_path = None
    positional = []
    while args:
        a = args.pop(0)
        if a == '--min':
            target_min = args.pop(0)
        elif a == '--out':
            out_path = args.pop(0)
        elif a == '-h' or a == '--help':
            print(__doc__)
            return 0
        else:
            positional.append(a)
    if len(positional) != 1:
        print(__doc__, file=sys.stderr)
        return 2

    macho = positional[0]
    changed, log = patch_file(macho, target_min, out_path)
    if changed:
        for line in log:
            print(line)
        print("patched: %s" % (out_path or macho))
    else:
        print("no-op: %s (already %s or no min-version LCs)" % (macho, target_min))
    return 0


if __name__ == '__main__':
    sys.exit(main())
