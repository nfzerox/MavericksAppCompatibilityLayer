/*
 * kpf_osatomic.c -- external OSAtomic Increment/Decrement entry points.
 *
 * 10.9's <libkern/OSAtomic.h> defines OSAtomicIncrement32/Barrier and
 * friends as `__inline static` -- their bodies live in every translation
 * unit that includes the header, but no external symbol is exported.
 * Keynote was compiled against the 10.10 SDK where these are external
 * symbols, so dyld fails to bind them at launch.
 *
 * This file intentionally avoids including OSAtomic.h, so we can emit
 * real external definitions without redefinition errors. We pin the
 * Mach-O symbol names via `asm()` renames so the compiler still sees
 * unique C identifiers (kpf_OSAtomic_*) while the linker emits
 * the canonical `_OSAtomic*` symbols.
 *
 * The implementation uses GCC __sync intrinsics, which on x86_64 lower
 * to LOCK XADD with a full memory barrier -- matching what Apple's
 * dylib does on 10.10+.
 */

#include <stdint.h>

int32_t kpf_OSAtomicIncrement32(volatile int32_t *v)        asm("_OSAtomicIncrement32");
int32_t kpf_OSAtomicIncrement32Barrier(volatile int32_t *v) asm("_OSAtomicIncrement32Barrier");
int32_t kpf_OSAtomicDecrement32(volatile int32_t *v)        asm("_OSAtomicDecrement32");
int32_t kpf_OSAtomicDecrement32Barrier(volatile int32_t *v) asm("_OSAtomicDecrement32Barrier");
int64_t kpf_OSAtomicIncrement64(volatile int64_t *v)        asm("_OSAtomicIncrement64");
int64_t kpf_OSAtomicIncrement64Barrier(volatile int64_t *v) asm("_OSAtomicIncrement64Barrier");
int64_t kpf_OSAtomicDecrement64(volatile int64_t *v)        asm("_OSAtomicDecrement64");

int32_t kpf_OSAtomicIncrement32(volatile int32_t *v)        { return __sync_add_and_fetch(v, 1); }
int32_t kpf_OSAtomicIncrement32Barrier(volatile int32_t *v) { return __sync_add_and_fetch(v, 1); }
int32_t kpf_OSAtomicDecrement32(volatile int32_t *v)        { return __sync_sub_and_fetch(v, 1); }
int32_t kpf_OSAtomicDecrement32Barrier(volatile int32_t *v) { return __sync_sub_and_fetch(v, 1); }
int64_t kpf_OSAtomicIncrement64(volatile int64_t *v)        { return __sync_add_and_fetch(v, 1); }
int64_t kpf_OSAtomicIncrement64Barrier(volatile int64_t *v) { return __sync_add_and_fetch(v, 1); }
int64_t kpf_OSAtomicDecrement64(volatile int64_t *v)        { return __sync_sub_and_fetch(v, 1); }
