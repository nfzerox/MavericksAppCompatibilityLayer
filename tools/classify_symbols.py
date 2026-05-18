#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
classify_symbols.py <manifest.json>

For each missing symbol, decide:
  * function vs data
  * if data, what C type (so gen_stubs.py can emit a properly-typed stub)

Sources of truth, in order:
  1. Preprocessed SDK umbrella (clang -E across Foundation/AppKit/CoreFoundation/
     CoreGraphics/CoreText/CoreVideo/AVFoundation/Security/LocalAuthentication/
     CloudKit/IOSurface/MetalKit/...).  Macros are expanded, typedefs are visible
     in the same buffer, and the declaration always lives on a single line --
     this catches every `<FW>_EXTERN`, `API_AVAILABLE`, `_Nonnull`, etc.
  2. On-disk Mach-O binaries under KPF_ROOTFS (when present) -- `nm -m` tells us
     text vs data when the SDK lookup is inconclusive.
  3. Name-based heuristics (NSFontWeight*, *Key, *Domain, ...).

Emits an augmented manifest on stdout:
  {"missing_symbols":[{...original..., "kind":"NSString_const"|...,
                       "decl":"<header line>"}], ...}

Kinds recognised (gen_stubs.py consumes them):
  function         -- text symbol; needs a hand-written C implementation
  NSString_const   -- typed NSString * (incl. typedef'd swift_wrapper aliases)
  CFString_const   -- typed CFStringRef
  c_string_const   -- `const char * const X`
  CGFloat          -- typedef'd or bare CGFloat
  NSEdgeInsets     -- NSEdgeInsets / UIEdgeInsets-shaped struct
  objc_class       -- _OBJC_CLASS_$_X / _OBJC_METACLASS_$_X
  data_unknown     -- known to be data, but type couldn't be parsed
  unknown          -- couldn't find it; void* fallback

Env vars:
  KPF_SDK     -- path to MacOSX*.sdk (mandatory for preprocessor pass)
  KPF_ROOTFS  -- path to a RootFS root (.../System) for nm cross-check (optional)
  KPF_PP_CACHE -- where to put the preprocessed umbrella; defaults to
                  $PWD/build/kpf9_autostubs/sdk.pp.m
"""
import json, subprocess, re, os, sys

DEVNULL = open(os.devnull, 'wb')

# Defaults match the 6.6.2 setup_iwork.sh flow (Yosemite SDK + dylibs).
SDK = os.environ.get(
    "KPF_SDK",
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.10.sdk")
ROOTFS = os.environ.get("KPF_ROOTFS", "/Volumes/Yosemite")
PP_CACHE = os.environ.get(
    "KPF_PP_CACHE",
    os.path.join(os.getcwd(), "build", "kpf9_autostubs", "sdk.pp.m"))

UMBRELLA_HEADERS = [
    "#import <Foundation/Foundation.h>",
    "#import <AppKit/AppKit.h>",
    "#import <CoreFoundation/CoreFoundation.h>",
    "#import <CoreGraphics/CoreGraphics.h>",
    "#import <CoreText/CoreText.h>",
    "#import <CoreVideo/CoreVideo.h>",
    "#import <AVFoundation/AVFoundation.h>",
    "#import <Security/Security.h>",
    "#import <LocalAuthentication/LocalAuthentication.h>",
    "#import <CloudKit/CloudKit.h>",
    "#import <IOSurface/IOSurface.h>",
    "#import <MetalKit/MetalKit.h>",
    "#include <compression.h>",
    "#include <os/log.h>",
    "#include <os/lock.h>",
    "#include <dispatch/dispatch.h>",
]


def find_clang():
    # Prefer the bundled clang from the SDK's Xcode tree (matches the SDK).
    candidate = SDK.split("/Contents/Developer/")[0]
    if "Xcode.app" in candidate:
        bundled = os.path.join(
            candidate, "Contents", "Developer", "Toolchains",
            "XcodeDefault.xctoolchain", "usr", "bin", "clang")
        if os.path.exists(bundled):
            return bundled
    try:
        return subprocess.check_output(["xcrun", "-find", "clang"],
                                       stderr=DEVNULL).decode().strip()
    except Exception:
        return "clang"


def build_preprocessed():
    """Run clang -E on the umbrella header set, cache result, return path."""
    if os.path.exists(PP_CACHE) and os.path.getsize(PP_CACHE) > 1_000_000:
        return PP_CACHE
    cache_dir = os.path.dirname(PP_CACHE)
    if cache_dir and not os.path.exists(cache_dir):
        os.makedirs(cache_dir)
    src = PP_CACHE + ".in.m"
    with open(src, "w") as f:
        f.write("\n".join(UMBRELLA_HEADERS) + "\n")
    cc = find_clang()
    cmd = [cc, "-E", "-isysroot", SDK, "-x", "objective-c", src, "-o", PP_CACHE]
    sys.stderr.write("classify_symbols: preprocessing SDK umbrella with %s ...\n" % cc)
    rc = subprocess.call(cmd, stderr=DEVNULL)
    if rc != 0 or not os.path.exists(PP_CACHE):
        sys.stderr.write("classify_symbols: clang -E failed (rc=%d); falling back to per-header grep\n" % rc)
        return None
    return PP_CACHE


# ----- typedef alias resolution -----

# kind values matching gen_stubs.py emitters
_NSSTR = 'NSString_const'
_CFSTR = 'CFString_const'
_CGFLOAT = 'CGFloat'

# Aliases that are documented to be (struct/object/CGFloat) but not visible as
# a typedef in our preprocessed buffer (e.g. they come from another framework
# we didn't include, or live behind macros).  Hardcode the well-known ones.
SEED_ALIASES = {
    'CGFloat': _CGFLOAT,
    'NSFontWeight': _CGFLOAT,
    'ATSFontSize': _CGFLOAT,
    'NSString': _NSSTR,
    'CFStringRef': _CFSTR,
}


def collect_typedef_aliases(pp_path):
    """Parse `typedef X Y` lines from the preprocessed buffer and return a
    map of Alias -> kind ('NSString_const' / 'CGFloat' / 'CFString_const')."""
    aliases = dict(SEED_ALIASES)
    if not pp_path:
        return aliases
    rx_ns = re.compile(r'^\s*typedef\s+NSString\s*\*\s*([A-Za-z_][A-Za-z_0-9]*)\b')
    rx_cf = re.compile(r'^\s*typedef\s+CFStringRef\s+([A-Za-z_][A-Za-z_0-9]*)\b')
    rx_cgf = re.compile(r'^\s*typedef\s+CGFloat\s+([A-Za-z_][A-Za-z_0-9]*)\b')
    rx_alias_chain = re.compile(
        r'^\s*typedef\s+([A-Za-z_][A-Za-z_0-9]*)\s+([A-Za-z_][A-Za-z_0-9]*)\s*[;_]')
    with open(pp_path) as f:
        for line in f:
            if 'typedef' not in line:
                continue
            m = rx_ns.match(line)
            if m:
                aliases[m.group(1)] = _NSSTR
                continue
            m = rx_cf.match(line)
            if m:
                aliases[m.group(1)] = _CFSTR
                continue
            m = rx_cgf.match(line)
            if m:
                aliases[m.group(1)] = _CGFLOAT
                continue
            m = rx_alias_chain.match(line)
            if m and m.group(1) in aliases:
                aliases[m.group(2)] = aliases[m.group(1)]
    return aliases


# ----- declaration lookup -----

def grep_pp(pp_path, symbol):
    """Return up to 3 lines from preprocessed buffer that mention `symbol`."""
    if not pp_path:
        return []
    try:
        out = subprocess.check_output(
            ["grep", "-m", "8", "-E", r'\b' + re.escape(symbol) + r'\b', pp_path],
            stderr=DEVNULL).decode('utf-8', 'ignore')
    except subprocess.CalledProcessError:
        return []
    return [l.strip() for l in out.split('\n') if l.strip()]


def grep_sdk_headers_fallback(lib, symbol):
    """Last-resort grep against SDK headers if the PP buffer didn't include
    the relevant framework (e.g. private/SPI symbols)."""
    if not lib.startswith("/System/Library/Frameworks/"):
        return []
    fw = lib.split("/System/Library/Frameworks/", 1)[1].split("/", 1)[0]
    root = os.path.join(SDK, "System", "Library", "Frameworks",
                        fw + ".framework", "Headers")
    if not os.path.exists(root):
        return []
    try:
        out = subprocess.check_output(
            ["grep", "-rh", "-E", r'\b' + re.escape(symbol) + r'\b', root],
            stderr=DEVNULL).decode('utf-8', 'ignore')
    except subprocess.CalledProcessError:
        return []
    return [l.strip() for l in out.split('\n')[:3] if l.strip()]


# ----- type matching on a single decl line -----

def _strip_decorators(line):
    """Remove attributes / nullability annotations so the type tokens are clean."""
    # Drop trailing __attribute__((..)) recursively.
    while True:
        new = re.sub(r'__attribute__\s*\(\(\s*[^()]*(?:\([^()]*\)[^()]*)*\)\)', '', line)
        if new == line:
            break
        line = new
    line = re.sub(r'\b_(?:Nonnull|Nullable|Null_unspecified)\b', '', line)
    line = re.sub(r'\bCV_NONNULL\b|\bCG_NONNULL\b', '', line)
    line = re.sub(r'\bAPI_AVAILABLE\s*\([^)]*\)', '', line)
    line = re.sub(r'\bNS_(?:AVAILABLE|DEPRECATED|SWIFT_NAME|REFINED_FOR_SWIFT|EXTENSIBLE_STRING_ENUM)\b\w*\s*\([^)]*\)', '', line)
    line = re.sub(r'\bNS_AVAILABLE_MAC\s*\([^)]*\)', '', line)
    line = re.sub(r'\bextern\s+', '', line)
    line = re.sub(r'\bstatic\s+', '', line)
    # `const` -> token so we can tell it apart, but also pad '*' so '*const'
    # and '* const' tokenize the same way.
    line = line.replace('*', ' * ')
    line = re.sub(r'\bconst\b', '__CONST__', line)
    line = re.sub(r'\s+', ' ', line).strip()
    return line


def _type_from_clean(clean, bare):
    """Given a decoratorless decl, decide kind.  Returns kind or None."""
    # function?  symbol followed by '('
    if re.search(r'(?<!\w)' + re.escape(bare) + r'\s*\(', clean):
        return 'function'
    m = re.search(r'(?<!\w)' + re.escape(bare) + r'(?!\w)', clean)
    if not m:
        return None
    pre = clean[:m.start()].strip()
    # Tokenize and drop our placeholders.
    raw_toks = [t for t in re.split(r'\s+', pre) if t]
    toks = [t for t in raw_toks if t not in ('__CONST__', '*')]
    has_star = '*' in raw_toks
    if not toks:
        return None
    last = toks[-1]
    if last == 'NSString' and has_star:
        return _NSSTR
    if last == 'CFStringRef':
        return _CFSTR
    if last == 'CGFloat':
        return _CGFLOAT
    if last == 'NSEdgeInsets' or last == 'UIEdgeInsets':
        return 'NSEdgeInsets'
    if last == 'char' and has_star:
        return 'c_string_const'
    return ('alias', last)


def kind_from_decl(decl, bare, aliases):
    clean = _strip_decorators(decl)
    res = _type_from_clean(clean, bare)
    if res is None:
        return None
    if isinstance(res, tuple) and res[0] == 'alias':
        alias = res[1]
        return aliases.get(alias)
    return res


# ----- nm cross-check (only when we have the dylib on disk) -----

def rootfs_dylib_for(declared_lib):
    if not declared_lib.startswith("/System/Library/Frameworks/"):
        return None
    # ROOTFS may include or omit the "/System" prefix.
    cands = [
        os.path.join(ROOTFS, declared_lib.lstrip("/")),
        ROOTFS + declared_lib,
    ]
    for c in cands:
        if os.path.exists(c):
            return c
    return None


def nm_section(dylib, symbol):
    if not dylib or not os.path.exists(dylib):
        return None
    try:
        out = subprocess.check_output(["nm", "-m", dylib],
                                       stderr=DEVNULL).decode('utf-8', 'ignore')
    except Exception:
        return None
    needle = ' ' + symbol
    for line in out.split('\n'):
        if not line.endswith(needle):
            continue
        if '(__TEXT,__text' in line or '(__TEXT,__stub' in line:
            return 'function'
        return 'data'
    return None


# ----- top-level kind decision -----

def _strip_one_underscore(sym):
    # Mach-O symbols carry one extra leading underscore vs the C identifier.
    return sym[1:] if sym.startswith('_') else sym


def kind_of(sym, section, decls, aliases):
    if sym.startswith('_OBJC_CLASS_$_') or sym.startswith('_OBJC_METACLASS_$_'):
        return 'objc_class'
    bare = _strip_one_underscore(sym)
    # 1. Decl-based detection on every candidate line.
    for d in decls:
        k = kind_from_decl(d, bare, aliases)
        if k:
            return k
    # 2. Name conventions for symbols we couldn't find in headers / PP.
    if section == 'function':
        return 'function'
    if bare.startswith('NSFontWeight'):
        return _CGFLOAT
    # If the symbol name starts with a known NSString-typedef alias, the
    # constant is overwhelmingly of that alias type (Apple's swift_wrapper
    # convention).  Match against the longest known alias first.
    for alias in sorted(aliases, key=len, reverse=True):
        if len(alias) < 4:
            continue
        if bare.startswith(alias) and aliases[alias] in (_NSSTR, _CFSTR, _CGFLOAT):
            return aliases[alias]
    if re.search(r'(Key|Domain|Identifier|Name|Notification|Scope|Type|Mode|Attribute|Subtype|Style|UserInfoKey)$', bare):
        return _NSSTR
    if bare.startswith('k') and len(bare) > 1 and bare[1:2].isupper():
        # k<Foo> is overwhelmingly CFStringRef const (CoreFoundation idiom).
        return _CFSTR
    if section == 'data':
        return 'data_unknown'
    return 'unknown'


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(1)
    manifest = json.load(open(sys.argv[1]))

    pp = build_preprocessed()
    aliases = collect_typedef_aliases(pp)
    sys.stderr.write("classify_symbols: %d typedef aliases resolved\n" % len(aliases))

    for s in manifest['missing_symbols']:
        sym = s['symbol']
        dylib = rootfs_dylib_for(s['lib'])
        section = (nm_section(dylib, sym)
                   if not sym.startswith('_OBJC_') else 'data')
        bare = _strip_one_underscore(sym)
        decls = grep_pp(pp, bare)
        if not decls:
            decls = grep_sdk_headers_fallback(s['lib'], bare)
        s['section'] = section
        s['decl'] = decls[0] if decls else None
        s['kind'] = kind_of(sym, section, decls, aliases)
    json.dump(manifest, sys.stdout, indent=2)


if __name__ == '__main__':
    main()
