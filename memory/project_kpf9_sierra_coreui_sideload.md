---
name: kpf9-sierra-coreui-sideload
description: "Investigation result for side-loading Sierra's CoreUI on 10.11 to fix Keynote 9 asset-catalog image loading: DYLD_FRAMEWORK_PATH works, but Sierra CoreUI's transitive deps (TextureIO + libate.dylib + ~20 libSystem `$UNIX2003` aliases) make it a ~60-shim project. Parked until we know which specific assets fail."
metadata:
  node_type: memory
  type: project
---

Hypothesis (2026-05-18): some images on the Keynote 9 / 10.11 backport don't render because 10.11's `CoreUI.framework` (v366.1.0) can't decode the 10.12-era asset-catalog format Apple compiled the iWork resources with. Tried side-loading Sierra's CoreUI (v431.3.0) via `DYLD_FRAMEWORK_PATH`.

**The mechanism works.** Setting `DYLD_FRAMEWORK_PATH=~/sierra_fw` made dyld load `~/sierra_fw/CoreUI.framework/Versions/A/CoreUI` even though the recorded install_name is `/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI`. Sierra CoreUI replaces 10.11's in the namespace cleanly. So the framework-search-path override does take precedence over the recorded private path.

**The deps don't.** Sierra CoreUI's `otool -L` shows these blockers on 10.11:

- `TextureIO.framework/Versions/A/TextureIO` (Sierra-only; v2.8.0).
- `/usr/lib/libate.dylib` (Apple Texture Encoder; Sierra-only).
- A short list of 10.12+ libsystem / CG symbols: `_os_log_impl`, `_os_log_create`, `_os_log_type_enabled`, `_os_unfair_lock_lock`, `_os_unfair_lock_unlock`, `_CGColorSpaceCopyICCData` (all of which we already shim in `kpf_stubs_1011.m`).

Sierra `TextureIO.framework` (also stageable from `/Volumes/Sierra/System/Library/PrivateFrameworks/`) needs `libate.dylib` plus a few CG additions: `_kCGColorSpaceExtendedLinearSRGB`, `_kCGColorSpaceLinearSRGB`, `_CGColorSpaceIsWideGamutRGB`.

`libate.dylib` is the wall. Its bind table on Sierra references:

- The `_at_encoder_*` family (Apple Texture Encoder API surface; ~8 functions) -- we'd have to no-op them all and accept "no texture compression". The encoder family is internal-only so the no-op shouldn't break anything visible.
- ~20 `$UNIX2003`-suffixed libSystem aliases (`_chmod$UNIX2003`, `_close$UNIX2003`, `_open$UNIX2003`, `_fopen$UNIX2003`, `_read$UNIX2003`, `_write$UNIX2003`, `_mmap$UNIX2003`, `_pthread_cond_wait$UNIX2003`, ...). These are versioned variants from Sierra's libSystem that 10.11 doesn't export. The unsuffixed versions exist on 10.11; we'd need to provide our own `$UNIX2003` aliases that forward (probably trivial via `__asm__(".set _foo$UNIX2003, _foo");` in kpf_stubs_1011.m, similar to how we handle `_dispatch_assert_queue$V2`).

Total estimated cost: ~60 new shims in `kpf_stubs_1011.m`. None individually hard, but it's a lot of plumbing for a guess.

**What we did during the investigation:**

1. `cp -R /Volumes/Sierra/System/Library/PrivateFrameworks/{CoreUI,TextureIO}.framework ~/sierra_fw/`
2. Confirmed `DYLD_FRAMEWORK_PATH=~/sierra_fw $KEYNOTE_BIN` did load our staged CoreUI.
3. Ran our patcher on the staged frameworks (`patch_min_version --min 10.11`, `diff_imports`, `patch_surgical`). Works the same on Apple's own binaries as on iWork's. After surgical patch, Sierra CoreUI was nominally launchable on 10.11 dyld; symbol resolution still failed because the actual transitive bind targets don't exist.
4. Cleaned up `~/sierra_fw` so future runs start fresh.

**Before reviving this approach, check first:**

Open Keynote 9 on the 10.11 backport, identify *which* images render wrong (template thumbnails? toolbar icons? inspector glyphs?). Often the cheaper fix is to:

- Stub `+[NSImage imageNamed:]` to fall back to a hand-supplied PNG when the assetcatalog lookup returns nil, OR
- Extract specific images from `Assets.car` via `assetutil` and drop them under `Contents/Resources/` with the expected filename, OR
- Override individual `NSImage` accesses iWork makes (e.g. `+[NSImage imageNamed:]` returning a custom NSImage built from the on-disk asset directory).

If the rendering issue turns out to be diffuse (a whole category of catalog assets), Sierra CoreUI may still be the cleanest fix and the ~60 shims become worth writing.

See related: [[kpf9-tiered-os-strategy]] for the broader 10.13->older tiering plan, and [[kpf9-mass-stub-pipeline]] for the classifier we'd use to enumerate `libate`'s missing symbols.
