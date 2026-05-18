---
name: kpf9-1010-state
description: "Keynote 9 on macOS 10.10 Yosemite: gets past dyld + TS framework static init, but crashes during Keynote main's protobuf-descriptor static init with `incorrect checksum for freed object`. Confirmed real heap corruption (not a false canary) via abort()-patch PoC. dlcheck tightening was a red herring."
metadata:
  node_type: memory
  type: project
---

State as of 2026-05-17. The 10.10 backport tier is set up (scripts + stubs parallel to 10.11) and runs through:

- dyld surgical-patched load of Keynote main + 13 TS frameworks + 4 XPC services
- per-framework kpf_stubs LC_LOAD_DYLIB injection (every TS framework, not just main -- needed because iWork reads `__NSArray0__` / `__NSDictionary0__` from TSCoreSOS's `__mod_init_funcs` before any other +load could run)
- KPFOSLog singleton init (slabless, runtime retain/release no-op IMPs)
- KPFEmptyCollectionsLoader +load (immortal NSMutableArray / NSMutableDictionary instances via runtime IMP swap on retain/release of the concrete class, gated to only no-op when receiver is our singleton)
- CKContainer entitlement bypass via method_setImplementation
- LAErrorDomain / objc_unsafeClaimAutoreleasedReturnValue / __NSArray0__ / __NSDictionary0__ all visible in flat lookup

Then aborts inside Keynote main's `__mod_init_funcs`:

```
*** error for object 0x...: incorrect checksum for freed object
0  __pthread_kill
2  abort
3  szone_error
4  tiny_malloc_from_free_list
7  malloc
8  operator new(unsigned long)
9  com.apple.iWork.Keynote  +0x9b7641  (Keynote main __mod_init)
10 dyld doModInitFunctions
```

Sometimes the crash lands deeper in protobuf's `FileDescriptorProto::MergePartialFromCodedStream` instead -- same heap canary failure, just a different malloc downstream of the same corrupted state.

**Same crash signature as the abandoned 10.9 backport** ([[kpf9-heap-corruption-wip]]), but root cause is different:

- 10.9 attempt: caused by `char _slab[256]` ivar on `KPFOSLog` (ARC ivar-layout misencoding -- [[arc-ivar-layout-slab-pitfall]]). Fixed by removing slab.
- 10.10 attempt: NO slab; `KPFOSLog` is plain `@interface KPFOSLog : NSObject @end`. `KPF_NO_OS_LOG=1` (returning NULL from os_log_create instead of a singleton) does NOT eliminate the crash. So whatever the source is, it's not the os_log singleton.

**Did not crash on 10.11** with the equivalent shim set. 10.10's older runtime / clang 6.0 might be more sensitive to something in our setup, or to the larger set of stubbed classes (10.10 needs ~80 class stubs vs 10.11's ~40 since 10.10 lacks all the CN/CI/MTL/Vision/ClassKit families natively).

**Red-herring chase from this session:** I initially saw `dyld: Symbol not found _LAErrorDomain` (since 10.10's LocalAuthentication.framework has it only in a private subframework, not its main dylib's export table) and tightened `dlcheck.c` (RTLD_FIRST + drop RTLD_DEFAULT + framework warmup) so it would be classified as MISSING. That broadened the missing-symbol set substantially and *appeared* to be the corruption source. Empirically the corruption reproduces with the tighter OR original dlcheck, so the dlcheck tightening was not the cause. Reverted to the original dlcheck and added a targeted `--force-missing` mechanism (see `stubs/force_missing_1010.txt`) for the genuinely-flat-but-recorded-ordinal-can't-find case -- the right tradeoff for the broader port too, not just 10.10.

**Confirmed real corruption (2026-05-17, PoC):** Cross-referenced libmalloc-53.30.1 (10.10.5 open source) and built a bypass that overwrites the first byte of `abort()` with `0xC3` (`ret`) at `__attribute__((constructor(101)))` time. szone_error then falls through `_simple_sfree(b)` and returns normally to `tiny_malloc_from_free_list`. Result: the crash signature changes -- no more SIGABRT, but `tiny_malloc_from_free_list` immediately SIGSEGVs one frame deeper jumping to a bogus address (e.g. `0xfffffff0`) because it follows the very free-list pointer whose checksum was bad. **The corruption is genuine; the canary is not a false alarm.** Bypass kept in `stubs/kpf_stubs_1010.m` as an opt-in research toggle, gated by env `KPF_BYPASS_MALLOC_ABORT=1` (default off). Notes for future digs:
- Production 10.10.5 szone_t layout differs from open-source 53.30.1: `cpu_id_key` at +4096 was observed as `0xff..ff` not zero, and the admin region is only one 4K page wide; naive offset-based `debug_flags` clear (offset 4104) blew up into adjacent r-x __TEXT pages. Per-zone disarm via known offsets is not viable on the production layout without more layout discovery.
- `_malloc_debug_flags` IS exported by libsystem_malloc.dylib; clearing it via dlsym only affects future zones, not existing ones.
- The crash site is consistently in Keynote main's __mod_init (offset `+0x9b7641` in 9.1/6369), via `strdup` (or `operator new`) → `malloc` → `tiny_malloc_from_free_list`. Whatever scribbles the free-list bookkeeping must happen during one of the earlier inits we run (kpf_stubs +load, TS framework __mod_init, KPFOSLog, NSArray0/NSDictionary0 IMP swap, CKContainer swizzle, auto_stubs). Bisect via env-gating each shim is the next reasonable step.

**Bisect candidates worth probing next time:**

- Try removing individual auto-stubbed classes (one at a time, or in groups by framework prefix). The class metadata for some 10.11-or-newer class might be triggering 10.10 runtime issues at class-realization time.
- Try compiling `kpf_auto_stubs.m` with `-fno-objc-arc` (only the auto-stubs, not kpf_stubs.m). Auto-generated empty classes don't need ARC, and ARC's class-metadata insertions on clang 6.0 / 10.10 runtime might be the issue.
- Try shrinking the bundled libswift*.dylib patches: the 10.10 orchestrator inherits the libswift inclusion from 10.11; perhaps a libswift bind to a missing 10.12 symbol is being NULL-resolved and the NULL gets called somewhere later.
- Apply `MallocStackLoggingNoCompact=1` + lldb breakpoint on `malloc_error_break`, then `malloc_history <addr>` for the corrupt object's allocation trace. Procedure laid out in [[kpf9-heap-corruption-wip]].
- Bisect kpf_stubs_1010.m by env-gating each shim section. Add `KPF_NO_NSARRAY0=1`, `KPF_NO_DLPATCH=1`, etc. to isolate which shim's side effects produce the bad heap state.

**Tooling delta from 10.11 (committed):**

- `scripts/_kpf9_1010_guest_orchestrator.sh` always-injects kpf_stubs into every framework (10.11 did this only for main).
- `tools/diff_imports.py` accepts `--force-missing <path>`: symbols listed in the file are forced into `missing_symbols` regardless of dlcheck output. patch_surgical then flat-redirects their bind ordinals. (`tools/dlcheck.c` itself is back to its original behavior; we'd need a targeted file like `stubs/force_missing_1010.txt` per tier.)
- `tools/aggregate_manifests.py`, `tools/gen_stubs.py`: unchanged.
- `stubs/kpf_stubs_1010.m`:
  - Generics-free NSMutableArray * for NSGridView properties (clang 6.0 doesn't parse them).
  - Pre-anchor NSLayoutConstraint forms + `-addView:inGravity:` (replaces 10.11+ NSLayoutAnchor and NSStackView `-addArrangedSubview:`).
  - Numeric NSCoderReadCorruptError code (4864).
  - Drop NSSpellChecker stubs (10.10 has them).
  - __NSArray0__ / __NSDictionary0__: IMP-swapped immortal NSMutableArray/NSMutableDictionary singletons; the IMPs guard on `self == kpf_array0_singleton` so only our specific instance is treated as immortal, other instances retain normal behavior. IMP signatures use `void *` not `id` to dodge ARC auto-retain on the retain IMP (otherwise infinite recursion -- same pitfall as KPFOSLog on the 10.9 attempt).
  - objc_unsafeClaimAutoreleasedReturnValue fallback to objc_retainAutoreleasedReturnValue.
- `stubs/manual_symbols_1010.txt`: add ___NSArray0__, ___NSDictionary0__, _objc_unsafeClaimAutoreleasedReturnValue.
- `stubs/force_missing_1010.txt`: starts with just `_LAErrorDomain`.

**Iteration cheatsheet:**

- `scripts/setup_keynote9_1010.sh` -- full pipeline against `<user>@<mav-host>` (the user provisions a 10.10.5 Yosemite box at the same IP between tiers).
- `scripts/hotswap_kpf9_1010.sh` -- dylib-only fast iteration (~5s).
- `KPF_NO_OS_LOG=1` -- bypass the os_log singleton entirely (returns NULL).
- `KPF_TRACE_NIL_DICT=1` / `KPF_TRACE_NIL_ARRAY=1` -- log every nil insertion in `+dictionaryWithObjects:forKeys:count:` / `+arrayWithObjects:count:`.
- `KPF_BYPASS_MALLOC_ABORT=1` -- overwrite abort() with `ret` (PoC; confirms corruption is real, doesn't help reach main).

See related: [[kpf9-tiered-os-strategy]] (broader plan), [[kpf9-1011-state]] (mostly-functional 10.11 result), [[kpf9-heap-corruption-wip]] (the abandoned 10.9 attempt's same-signature crash), [[arc-ivar-layout-slab-pitfall]] (10.9 root cause; not applicable here but useful pattern).
