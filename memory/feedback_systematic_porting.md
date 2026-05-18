---
name: feedback-systematic-porting
description: "When porting Yosemite-era apps to Mavericks, identify missing symbols statically; don't sledgehammer-weaken everything and chase NULL-deref crashes."
metadata: 
  node_type: memory
  type: feedback
---

When making a Yosemite-only Mach-O binary load on Mavericks (or any analogous OS-back-port), **do not weaken every binding indiscriminately**. That defers all signal to runtime: dyld stops reporting "Symbol not found: X" and instead binds X to NULL, so you find each missing symbol via segfault → PC → GOT-slot lookup → `dyldinfo -bind`. Tedious, error-prone, and useless as the basis of a general-purpose tool.

The better path is **static differencing**. For each binding in the target binary:
1. Find the recorded source dylib path (from the bind opcode stream).
2. Resolve that path on the 10.9 host. If absent → whole framework missing.
3. If present → enumerate its exports (`nm -gjU` or `dyldinfo -export`) and check whether the binding's symbol is in the export set.
4. The set of bindings whose symbol is not in the resolved dylib's exports is **exactly** the list of things you need to weaken + stub.

This produces a complete, accurate "missing symbol manifest" without launching the binary even once. The manifest then drives:
- A surgical patcher that flips only those specific bind opcodes weak.
- A stub generator that emits ObjC declarations for the missing classes / data symbols. Classes → `@implementation Foo : NSObject @end`. Untyped data → `void *Foo = NULL;` (NULL reads as zero for `movsd` / `movq` so it tolerates most non-function uses).

**Why:** The user (working on the autonomous-agent generalisation of this tool) flagged that blanket-weakening hides which symbols are actually missing, forces post-crash diagnosis, and doesn't scale to a loop where an AI agent is doing this for arbitrary apps.

**How to apply:** Before reaching for the load-time hook (XPF-style) or the "weaken everything" sledgehammer, build the static diff. Reserve runtime crash inspection (lldb / dyldinfo+PC lookup) for cases the static diff doesn't catch — runtime `NSClassFromString` lookups, method dispatch on Yosemite selectors, opaque blocks etc. Those are the genuine fallback cases, not the default approach.
