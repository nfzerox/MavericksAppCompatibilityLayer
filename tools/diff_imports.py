#!/usr/bin/env python
"""
diff_imports.py <binary> [--dlcheck <path>] [-- <ssh-command...>]

For every symbol the Mach-O <binary> imports, ask dlcheck whether dlsym()
resolves it against the recorded source dylib. Emit JSON to stdout listing
the imports we cannot resolve.

Two modes:
  --dlcheck <path>: run dlcheck locally (e.g. on the Mavericks guest with
                    the toolchain pushed there). No SSH round-trip.
  -- <ssh-cmd...>:  the legacy host->guest mode used by setup_iwork.sh;
                    appends "~/kpf_build/dlcheck" to the ssh command and
                    pipes the symbol list through it.

Requires `dlcheck` already built at the given path (see tools/dlcheck.c).

Examples:
  # local (run on guest):
  diff_imports.py /tmp/Keynote.orig --dlcheck ~/kpf_build/dlcheck > manifest.json
  # remote-via-ssh (run on host):
  diff_imports.py /tmp/Keynote.orig -- scripts/ssh_wrap.sh <user>@<mav-host> > manifest.json
"""
from __future__ import print_function
import sys, json, subprocess, os
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from macho_binds import (iter_slices, collect_dylibs, get_dyld_info,
                         walk_bind_stream)


def gather_imports(binary):
    """Return (ordered list of (lib, symbol, stream), set of (lib) referenced)."""
    with open(binary, 'rb') as f:
        data = bytearray(f.read())
    imports = []
    seen_pair = set()
    libs = set()
    for slice_off, endian, hsize in iter_slices(data):
        dylibs = collect_dylibs(data, slice_off, endian, hsize)
        ord_to_name = {o: n for o, _, _, n in dylibs}
        info = get_dyld_info(data, slice_off, endian, hsize)
        if info is None:
            continue
        _, _, bind_off, bind_sz, weak_off, weak_sz, lazy_off, lazy_sz, _, _ = info
        for stream, off, sz in (("bind", bind_off, bind_sz),
                                ("weak_bind", weak_off, weak_sz),
                                ("lazy_bind", lazy_off, lazy_sz)):
            for rec in walk_bind_stream(data, slice_off + off, sz):
                ord_n = rec['ordinal']
                if ord_n <= 0:
                    continue
                lib = ord_to_name.get(ord_n)
                if not lib:
                    continue
                k = (lib, rec['symbol'])
                if k in seen_pair:
                    continue
                seen_pair.add(k)
                libs.add(lib)
                imports.append((lib, rec['symbol'], stream, ord_n))
    return imports, libs


def load_force_missing(path):
    """Returns a set of (lib, symbol) pairs to be treated as missing
    regardless of dlcheck output. Used for symbols dyld at lazy bind
    cannot resolve via the recorded LC_LOAD_DYLIB ordinal even though
    dlcheck's probe-process namespace happens to expose them (e.g.
    `_LAErrorDomain` on 10.10 lives in a private LocalAuthentication
    subframework, not its main dylib)."""
    pairs = set()
    if not path or not os.path.exists(path):
        return pairs
    for line in open(path):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        parts = s.split()
        if len(parts) != 2:
            sys.stderr.write("force-missing line ignored (need `<lib> <symbol>`): %r\n" % (s,))
            continue
        pairs.add((parts[0], parts[1]))
    return pairs


def main():
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__); sys.exit(0 if args else 1)
    binary = args.pop(0)
    dlcheck_path = None
    force_missing_path = None
    ssh_cmd = []
    while args:
        a = args.pop(0)
        if a == '--dlcheck':
            dlcheck_path = args.pop(0)
        elif a == '--force-missing':
            force_missing_path = args.pop(0)
        elif a == '--':
            ssh_cmd = args
            break
        else:
            print("unknown arg:", a, file=sys.stderr)
            print(__doc__); sys.exit(1)
    if not dlcheck_path and not ssh_cmd:
        print(__doc__); sys.exit(1)
    force_missing = load_force_missing(force_missing_path)

    imports, libs = gather_imports(binary)
    sys.stderr.write("  binary imports %d distinct symbols across %d dylibs\n"
                     % (len(imports), len(libs)))

    # Sort by lib so dlcheck's dlopen cache stays warm.
    imports_sorted = sorted(imports, key=lambda r: (r[0], r[1]))

    # @rpath/X is resolved relative to the loading binary's LC_RPATH at
    # dyld time. dlcheck has no such context, so every @rpath lib comes
    # back LIBMISSING -- a false positive (the bundled framework is
    # present in the .app). Skip them from the dlcheck round-trip and
    # treat their imports as resolved.
    rpath_libs = set(lib for lib, _, _, _ in imports if lib.startswith('@rpath/'))
    if rpath_libs:
        sys.stderr.write("  skipping %d @rpath libs (bundled, resolved at load time)\n"
                         % (len(rpath_libs),))

    check_imports = [r for r in imports_sorted if not r[0].startswith('@rpath/')]

    # Also probe every LC_LOAD_DYLIB target with no symbol -- otherwise we
    # miss frameworks that the binary links (LC_LOAD_DYLIB only) without
    # importing any symbols. dlcheck treats `lib _bogus` as "library load
    # attempt + bogus symbol lookup"; if the library fails to dlopen we
    # learn it via LIBMISSING in the result.
    with open(binary, 'rb') as f:
        data = bytearray(f.read())
    lc_libs = set()
    for slice_off, endian, hsize in iter_slices(data):
        for _, _, _, name in collect_dylibs(data, slice_off, endian, hsize):
            if name and not name.startswith('@rpath/'):
                lc_libs.add(name)
    probe_libs = sorted(lc_libs - set(r[0] for r in check_imports))
    if probe_libs:
        sys.stderr.write("  probing %d extra libs with no bind entries\n"
                         % (len(probe_libs),))
    probe_payload = "\n".join("%s __kpf_unused_probe" % lib for lib in probe_libs)
    payload = "\n".join("%s %s" % (lib, sym) for lib, sym, _, _ in check_imports) + "\n"
    if probe_payload:
        payload += probe_payload + "\n"

    if dlcheck_path:
        cmd = [os.path.expanduser(dlcheck_path)]
        sys.stderr.write("  running local dlcheck %s ...\n" % (cmd[0],))
    else:
        cmd = ssh_cmd + ["~/kpf_build/dlcheck"]
        sys.stderr.write("  asking remote dlcheck ...\n")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout_data, stderr_data = proc.communicate(input=payload.encode('utf-8'))
    if proc.returncode != 0:
        sys.stderr.write("  dlcheck failed: %s\n" % (stderr_data.decode('utf-8', 'replace'),))
        sys.exit(2)
    stdout_text = stdout_data.decode('utf-8', 'replace')

    results = {}
    lib_open_failed = set()
    for line in stdout_text.splitlines():
        parts = line.split(' ', 2)
        if len(parts) != 3:
            continue
        status, a, b = parts
        # dlcheck emits two kinds of lines:
        #   LIBSTATUS <opened|failed> <lib>     -- per-unique-lib dlopen result
        #   OK|MISSING|LIBMISSING <lib> <sym>   -- per-symbol resolution result
        # We use LIBSTATUS as the authoritative answer for which LC_LOAD_DYLIBs
        # need to be flipped to weak; symbol-level "OK via RTLD_DEFAULT" can be
        # a false positive in dlcheck because dlopen'ing one lib transitively
        # loads others into the process namespace, but dyld at actual launch
        # still requires the named LC_LOAD_DYLIB path to open (or be weak).
        if status == "LIBSTATUS":
            if a == "failed":
                lib_open_failed.add(b)
            continue
        results[(a, b)] = status

    # Anything where the lib failed to open is in missing_libraries.
    missing_libs = sorted(lib_open_failed)
    missing_symbols = []
    libs_with_missing = set()
    for lib, sym, stream, ord_n in imports:
        if lib in rpath_libs:
            continue  # bundled @rpath libs resolve at load time; not "missing"
        status = results.get((lib, sym), "UNKNOWN")
        # A symbol needs weakening (and possibly stubbing) iff:
        #   - the recorded lib didn't open (we'll weaken the LC_LOAD_DYLIB,
        #     so we must also weaken bind entries against that lib's ordinal
        #     or dyld will fail the bind), OR
        #   - the lib opened but the symbol isn't in it (a non-lib-related
        #     missing symbol).
        lib_failed = lib in lib_open_failed
        forced = (lib, sym) in force_missing
        if lib_failed or status == "MISSING" or forced:
            missing_symbols.append({
                "lib": lib,
                "ordinal": ord_n,
                "symbol": sym,
                "stream": stream,
                "lib_missing": lib_failed,
                "flat_ok": (status == "OK"),
                "forced": forced,
            })
            libs_with_missing.add(lib)

    out = {
        "binary": binary,
        "total_imports": len(imports),
        "missing_libraries": missing_libs,
        "libraries_with_missing_symbols": sorted(libs_with_missing),
        "missing_symbols": missing_symbols,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == '__main__':
    main()
