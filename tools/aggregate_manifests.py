#!/usr/bin/env python3
"""
aggregate_manifests.py <manifest1.json> <manifest2.json> ... [--out <path>]

Merges N diff_imports.py manifests (one per Mach-O binary) into a single
deduped manifest that classify_symbols.py / gen_stubs.py can consume.

Dedup keys:
  missing_libraries: by install path
  missing_symbols:   by (lib, symbol)

The "stream" / "ordinal" / "lib_missing" fields are kept from the first
appearance of each symbol; they're informational for the classifier.
"""
import sys, json


def main():
    args = sys.argv[1:]
    out_path = None
    paths = []
    while args:
        a = args.pop(0)
        if a == "--out":
            out_path = args.pop(0)
        else:
            paths.append(a)
    if not paths:
        print(__doc__, file=sys.stderr); sys.exit(1)

    libs = set()
    seen = set()
    syms = []
    total_imports = 0
    for p in paths:
        m = json.load(open(p))
        total_imports += m.get("total_imports", 0)
        libs.update(m.get("missing_libraries", []))
        for s in m.get("missing_symbols", []):
            k = (s["lib"], s["symbol"])
            if k in seen:
                continue
            seen.add(k)
            syms.append(s)

    out = {
        "binaries_aggregated": [p for p in paths],
        "total_imports_summed": total_imports,
        "missing_libraries": sorted(libs),
        "missing_symbols": syms,
    }
    if out_path:
        json.dump(out, open(out_path, "w"), indent=2)
    else:
        json.dump(out, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
