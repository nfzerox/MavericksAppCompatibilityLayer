#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_framework_stub.py <name> <source_macho> <output_dir>
                     [--sdk <path>] [--install-name <override>]
                     [--no-build] [--reexport <real_dylib_path>]

Generates a stub .framework bundle that satisfies the symbol surface of
<source_macho> (typically the 10.13 SDK / RootFS framework binary) so the
patched Keynote 9 binary can link & load on Mavericks where the real
framework is absent.

Two modes:
  - default: emit a stub.m with empty ObjC classes + no-op C functions +
    zero-initialised data symbols for every external symbol exported by
    <source_macho>, then compile into a dylib at
    <output_dir>/<name>.framework/Versions/A/<name>.

  - --reexport: skip stub generation; build a stub.dylib that LC_REEXPORTs
    <real_dylib_path>. Use this when the symbol is present on Mavericks
    but at a different install path (e.g. CoreImage moved out of
    QuartzCore).

The framework's install_name is set to
  /System/Library/Frameworks/<name>.framework/Versions/A/<name>
unless overridden with --install-name. dyld's
DYLD_FALLBACK_FRAMEWORK_PATH (or an rpath on the patched binary) will
resolve the absolute path back to our stub bundle.
"""
import sys, os, subprocess, re, argparse


def list_exports_macho(macho):
    """Return list of (kind, name) for each global externally-visible
    defined symbol on the x86_64 slice of `macho`. `kind` is nm's type
    letter -- 'T' for text (function), 'D'/'S'/'B'/'C' for data, etc."""
    out = subprocess.check_output(['nm', '-arch', 'x86_64', '-gU', macho]).decode()
    by_name = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith('/') or line.endswith(':'):
            continue
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        if len(parts) == 2:
            kind, name = parts
        else:
            kind, name = parts[1], parts[2]
        by_name[name] = kind
    return sorted([(k, n) for n, k in by_name.items()], key=lambda x: x[1])


def list_exports_tbd(tbd_path):
    """Parse a .tbd (TAPI text-based dylib stub) and return (kind, name) tuples
    for the x86_64 slice. tbd v3/v4 are line-oriented YAML; a minimal
    parser handles the keys we care about:

      symbols:        -> C symbols, emitted as 'T' (we can't tell function
                         from data here; default to text and override via
                         hand-rolled stubs in kpf_stubs.m as needed).
      objc-classes:   -> _OBJC_CLASS_$_X / _OBJC_METACLASS_$_X
      objc-eh-types:  -> _OBJC_EHTYPE_$_X
      objc-ivars:     -> _OBJC_IVAR_$_X
      weak-defs:      -> same as symbols
    """
    text = open(tbd_path).read()

    syms = []
    in_x86 = False
    current_key = None
    pending = ''
    for raw in text.splitlines():
        line = raw.rstrip()
        # Section starts at "  - archs: [...]" -- determine if x86_64 is in
        # the arch list.
        m = re.match(r'^\s*-\s*archs:\s*\[\s*([^\]]+)\]', line)
        if m:
            archs = [a.strip() for a in m.group(1).split(',')]
            in_x86 = 'x86_64' in archs
            current_key = None
            pending = ''
            continue
        # Inside an arch block, look for the key lines we care about. They
        # start with two more spaces than the "- archs" entry. A value can
        # span multiple lines until a line starting with the same indent
        # ends with `]`.
        m = re.match(r'^\s*(symbols|objc-classes|objc-eh-types|objc-ivars|weak-defs):\s*(.*)$', line)
        if m and in_x86:
            current_key = m.group(1)
            pending = m.group(2)
            if pending.rstrip().endswith(']'):
                _emit_tbd_list(syms, current_key, pending)
                current_key = None
                pending = ''
            continue
        if current_key and in_x86:
            pending += ' ' + line.strip()
            if pending.rstrip().endswith(']'):
                _emit_tbd_list(syms, current_key, pending)
                current_key = None
                pending = ''

    by_name = {}
    for kind, name in syms:
        by_name[name] = kind
    return sorted([(k, n) for n, k in by_name.items()], key=lambda x: x[1])


def _emit_tbd_list(out, key, value_text):
    # value_text is e.g. "[ _MTLCreateSystemDefaultDevice, _MTLAddDevice, ... ]"
    inside = value_text.strip()
    if inside.startswith('['):
        inside = inside[1:]
    if inside.endswith(']'):
        inside = inside[:-1]
    items = [tok.strip().strip("'").strip('"') for tok in inside.split(',')]
    items = [it for it in items if it]
    if key in ('symbols', 'weak-defs'):
        # Default to text (function). Mismatches get hand-tuned later.
        for it in items:
            out.append(('T', it))
    elif key == 'objc-classes':
        for it in items:
            # Some entries have leading underscore, some don't. Strip and
            # re-emit in the mangled form classify() expects.
            cls = it.lstrip('_')
            out.append(('S', '_OBJC_CLASS_$_' + cls))
            out.append(('S', '_OBJC_METACLASS_$_' + cls))
    elif key == 'objc-eh-types':
        for it in items:
            out.append(('S', '_OBJC_EHTYPE_$_' + it.lstrip('_')))
    elif key == 'objc-ivars':
        for it in items:
            # ivars come as Class._ivar -- emit mangled symbol.
            mangled = it.replace('.', '.')  # already in Class._ivar form
            out.append(('S', '_OBJC_IVAR_$_' + mangled))


def list_exports(path):
    """Dispatch on path extension: .tbd -> text-based parser, else nm."""
    if path.endswith('.tbd'):
        return list_exports_tbd(path)
    return list_exports_macho(path)


# Match `_OBJC_CLASS_$_Foo` / `_OBJC_METACLASS_$_Foo` (mangled ObjC class refs)
OBJC_CLASS_RE = re.compile(r'^_OBJC_(META)?CLASS_\$_(.+)$')
OBJC_EHTYPE_RE = re.compile(r'^_OBJC_EHTYPE_\$_(.+)$')
OBJC_IVAR_RE = re.compile(r'^_OBJC_IVAR_\$_(.+)$')


def classify(symbols):
    """Group (kind, name) pairs into (classes, ehtypes, ivars, funcs, data).
    - classes: ObjC class names (collapsing CLASS/METACLASS pairs).
    - ehtypes / ivars: special ObjC symbols, listed for diagnostics.
    - funcs: C symbols whose nm kind says text (T/t).
    - data: C symbols whose nm kind says data (D/d/S/s/B/b/C).
    """
    classes = set()
    ehtypes = set()
    ivars = set()
    funcs = []
    data = []
    for kind, s in symbols:
        m = OBJC_CLASS_RE.match(s)
        if m:
            classes.add(m.group(2)); continue
        m = OBJC_EHTYPE_RE.match(s)
        if m:
            ehtypes.add(m.group(1)); continue
        m = OBJC_IVAR_RE.match(s)
        if m:
            ivars.add(m.group(1)); continue
        # Strip leading underscore so we re-emit as C declarations.
        name = s[1:] if s.startswith('_') else s
        if kind in ('T', 't'):
            funcs.append(name)
        elif kind in ('D', 'd', 'S', 's', 'B', 'b', 'C', 'G', 'g'):
            data.append(name)
        else:
            # Unknown / indirect (I), absolute (A), etc. -- safest default
            # is data so we don't get function-prologue addresses where a
            # pointer is expected.
            data.append(name)
    return classes, ehtypes, ivars, funcs, data


STUB_HEADER = """\
// Auto-generated framework stub for %(name)s -- DO NOT EDIT.
// Satisfies the symbol surface exported by the 10.13 %(name)s binary so
// dyld on Mavericks can load Keynote 9 without that framework being
// present. All ObjC classes are empty (NSObject subclasses). All C
// functions are no-op returning zero. All data symbols are 8-byte zero
// slots. iWork code that needs real behaviour from %(name)s must either
// (a) check for nil/0 returns and use a fallback (e.g. Metal device ->
// OpenGL), or (b) be shimmed in kpf_stubs.m instead.

#import <Foundation/Foundation.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-root-class"
#pragma clang diagnostic ignored "-Wreturn-type"
#pragma clang diagnostic ignored "-Wmissing-prototypes"

"""

STUB_FOOTER = "\n#pragma clang diagnostic pop\n"


def emit_stub(name, classes, ehtypes, ivars, funcs, data):
    lines = [STUB_HEADER % {'name': name}]

    # ObjC classes -- empty NSObject subclasses.
    for cls in sorted(classes):
        lines.append('@interface %s : NSObject @end' % cls)
        lines.append('@implementation %s @end' % cls)

    # ObjC exception types -- a real EHTYPE record is emitted automatically
    # for any @interface declared. If a class is exported as both class and
    # EHTYPE, the class declaration covers both. List EHTYPE-only symbols
    # for diagnostics.
    if ehtypes:
        lines.append('')
        lines.append('// EHTYPE records (declared via @interface above if class also exported):')
        for e in sorted(ehtypes):
            if e in classes:
                continue
            lines.append('// MISSING-EHTYPE: %s' % e)

    # ObjC ivar symbols are emitted by the runtime when @synthesize'd; we
    # don't recreate them here. List them for diagnostics.
    if ivars:
        lines.append('')
        for v in sorted(ivars):
            lines.append('// IVAR-ONLY: %s' % v)

    # C functions -- no-op `void X(void) {}`. Wrong return type is fine
    # for symbols Keynote never reaches; if it does reach one and reads a
    # return value, we hand-roll a typed override in kpf_stubs.m.
    if funcs:
        lines.append('')
        lines.append('// Text (function) symbols.')
        for sym in sorted(set(funcs)):
            lines.append('__attribute__((visibility("default"))) void %s(void) {}' % sym)

    # Data symbols -- 64-byte zero-aligned slot. Big enough for any
    # constant Keynote is likely to read (pointer, double, NSEdgeInsets,
    # short CFString refs etc.). If a real type is needed later we shim
    # in kpf_stubs.m.
    if data:
        lines.append('')
        lines.append('// Data symbols (constants, notification names, etc.) -- zero blob.')
        for sym in sorted(set(data)):
            lines.append('__attribute__((visibility("default"), aligned(16))) '
                         'const unsigned char %s[64] = {0};' % sym)

    lines.append(STUB_FOOTER)
    return '\n'.join(lines)


REEXPORT_STUB = """\
// Auto-generated re-export shim for %(name)s -- DO NOT EDIT.
// dyld looks for /System/Library/Frameworks/%(name)s.framework/Versions/A/%(name)s
// but on Mavericks the symbols actually live at <real_dylib_path>.
// This stub's only job is to LC_REEXPORT the real path, so dyld
// transparently resolves %(name)s symbols to their Mavericks home.
// Build it with -Wl,-reexport_library,<real>.

#import <Foundation/Foundation.h>
"""


def write_framework_bundle(name, install_name, sources_dir, output_dir,
                            sdk_path, reexport_path=None, do_build=True):
    fw = os.path.join(output_dir, '%s.framework' % name)
    versions = os.path.join(fw, 'Versions', 'A')
    os.makedirs(versions, exist_ok=True)
    resources = os.path.join(versions, 'Resources')
    os.makedirs(resources, exist_ok=True)

    # Info.plist
    plist_path = os.path.join(resources, 'Info.plist')
    plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>%s</string>
    <key>CFBundleIdentifier</key><string>com.apple.stub.%s</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
</dict>
</plist>
""" % (name, name)
    with open(plist_path, 'w') as f:
        f.write(plist)

    # Top-level symlinks (Versions/Current, Resources, executable)
    for link, target in [
        (os.path.join(fw, 'Versions', 'Current'), 'A'),
        (os.path.join(fw, name), 'Versions/Current/' + name),
        (os.path.join(fw, 'Resources'), 'Versions/Current/Resources'),
    ]:
        if os.path.islink(link) or os.path.exists(link):
            os.remove(link)
        os.symlink(target, link)

    if not do_build:
        return os.path.join(versions, name)

    # Compile.
    bin_path = os.path.join(versions, name)
    cmd = ['clang', '-dynamiclib',
           '-arch', 'x86_64',
           '-mmacosx-version-min=10.9',
           '-isysroot', sdk_path,
           '-install_name', install_name,
           '-fvisibility=hidden',
           '-w',  # silence warnings on auto-generated source
           '-o', bin_path]
    if reexport_path:
        # Compile an empty .m and re-export the real library.
        empty_m = os.path.join(sources_dir, '%s_reexport.m' % name)
        with open(empty_m, 'w') as f:
            f.write(REEXPORT_STUB % {'name': name})
        cmd += [empty_m, '-Wl,-reexport_library,' + reexport_path]
    else:
        stub_m = os.path.join(sources_dir, '%s_stub.m' % name)
        cmd += [stub_m]

    cmd += ['-framework', 'Foundation']
    print(' '.join(cmd))
    subprocess.check_call(cmd)
    return bin_path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('name', help='Framework name, e.g. Metal')
    ap.add_argument('source', help='Path to 10.13 framework binary')
    ap.add_argument('output', help='Output dir for the stub bundle')
    ap.add_argument('--sdk', default=os.environ.get('KPF9_SDK', ''),
                    help='Path to SDK for -isysroot')
    ap.add_argument('--install-name', default=None)
    ap.add_argument('--reexport', default=None,
                    help='Real dylib path to LC_REEXPORT (skip stub gen)')
    ap.add_argument('--no-build', action='store_true',
                    help='Emit source only, skip clang invocation')
    args = ap.parse_args()

    install_name = (args.install_name or
        '/System/Library/Frameworks/%s.framework/Versions/A/%s' %
        (args.name, args.name))

    sdk = args.sdk
    if not sdk and not args.no_build:
        # Try the bundled 10.13 SDK.
        guess = os.path.join(
            os.path.dirname(__file__), '..',
            'originals/SDK/10.13/Xcode.app/Contents/Developer/Platforms/'
            'MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk')
        if os.path.isdir(guess):
            sdk = guess
        else:
            sys.exit('--sdk <path> required (no KPF9_SDK env, no SDK at %s)'
                     % guess)

    os.makedirs(args.output, exist_ok=True)
    sources_dir = os.path.join(args.output, '_sources')
    os.makedirs(sources_dir, exist_ok=True)

    if args.reexport:
        write_framework_bundle(args.name, install_name, sources_dir,
                                args.output, sdk,
                                reexport_path=args.reexport,
                                do_build=not args.no_build)
        print("re-export stub: %s -> %s" % (args.name, args.reexport))
        return 0

    syms = list_exports(args.source)
    classes, ehtypes, ivars, funcs, data = classify(syms)
    print("symbols: %d total, %d classes, %d ehtypes, %d ivars, %d funcs, %d data"
          % (len(syms), len(classes), len(ehtypes), len(ivars), len(funcs), len(data)))

    stub = emit_stub(args.name, classes, ehtypes, ivars, funcs, data)
    stub_m = os.path.join(sources_dir, '%s_stub.m' % args.name)
    with open(stub_m, 'w') as f:
        f.write(stub)
    print("emitted %s" % stub_m)

    write_framework_bundle(args.name, install_name, sources_dir,
                            args.output, sdk,
                            do_build=not args.no_build)
    return 0


if __name__ == '__main__':
    sys.exit(main())
