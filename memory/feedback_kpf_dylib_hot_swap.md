---
name: kpf-dylib-hot-swap
description: "For MavericksAppCompatibilityLayer iteration, just swap kpf_stubs.dylib in the .app without resigning -- skip the full setup_iwork.sh re-patch"
metadata: 
  node_type: memory
  type: feedback
---

When iterating on `kpf_stubs.m` on the [[reference-kpf-ssh]] Mavericks guest,
once an .app is set up once (via `scripts/setup_iwork.sh <App>`), subsequent
dylib changes only need:

  1. `cp ~/kpf_build/kpf_stubs.dylib ~/<App>.app/Contents/Frameworks/kpf_stubs.dylib`
  2. relaunch (`open ~/<App>.app` or kill + open)

No need to re-resign the bundle, re-run `setup_iwork.sh`, or re-copy from
`/Volumes/Yosemite/Applications/<App>.app`. Mavericks ad-hoc signatures
aren't strictly enforced for nested dylibs in non-MAS apps -- dyld just
loads whatever file is at the LSEnvironment-supplied path.

**Why:** the user surfaced this after we sat through the full
copy + diff_imports + classify + patch_surgical + resign cycle for every
hook tweak. Cycle time drops from ~45s to a few seconds.

**How to apply:** keep `setup_iwork.sh` for the *first* install (or after
patcher / Info.plist changes). For any pure dylib-code change, just rebuild
the dylib on the guest (`make`) and skip the rest -- the embedded copy is
the one dyld actually loads.

**Caveat:** Xcode's view debugger / lldb attach checks the bundle's code
signature against actual file mtimes. A hot-swapped dylib has a fresher
mtime than what the cs_mtime in the signature recorded, and the kernel
sends the host process (Xcode) SIGKILL with
"CODE SIGNING: rejecting invalid page". Before debug-attaching to a
hot-swapped iWork app, run `codesign --force --deep --sign -
~/<App>.app` to refresh the signature against the current files.
Regular `open`/launchd launches don't trip this check on Mavericks.
