# AGENTS.md

Orientation for AI coding agents working in this repo. This is
the universal entry point. Tool-specific files (`CLAUDE.md`,
`.cursor/rules`, `.windsurfrules`, etc.) defer to this one.

## TL;DR

You're in a Mach-O patching project that back-ports modern macOS
apps to older releases.

- The **headline workflow** patches the 2015 era of Apple's
  iWork suite (Keynote 6.6.2, Pages 5.6.2, Numbers 3.6.2) so
  they run on **OS X 10.9 Mavericks**. This is the user-facing
  path, beta quality.
- The repo also contains **parked feasibility studies**
  porting **Keynote 9.1 (2019)** down to 10.10 / 10.11 / 10.12,
  at varying levels of completeness. Research, not for users.

Don't conflate the two. When the user says "the Mavericks
workflow" or "iWork 2015," they mean the first. When they say
"Keynote 9" or "kpf9," they mean the second.

## If the user has come in asking to port a new app

The README's *"Want to run a *different* app on Mavericks?"*
section invites readers to clone this repo and ask you to
extend it to a new app. If that's why this conversation is
happening — i.e. the user has dropped you into a fork and said
"please make `<App.app>` run on Mavericks" — here is the
shortest path to being useful:

1. **Read [JOURNEY.md](JOURNEY.md) end-to-end first.** Phases
   0 through 10 of the iWork 2015 → Mavericks build are the
   template. Almost every wall you'll hit on the new port has
   a closely-analogous wall in there with a documented fix.
2. **Treat the iWork 2015 path as the worked example.** Reuse
   `tools/diff_imports.py`, `tools/patch_surgical.py`, and the
   `kpf_stubs_iwork2015_10_9.m` shape. Don't rewrite the
   patcher. New stubs go in a sibling file —
   `stubs/kpf_stubs_<app>_<min-os>.m` — and a new
   `install_<app>.sh` mirrors `install_iwork2015.sh` with the
   target binary swapped out.

   **Most of `kpf_stubs_iwork2015_10_9.m` is *not*
   iWork-specific.** A large share of it is OS-delta plumbing
   that any Yosemite-or-later app running on Mavericks will
   need: the `NSVisualEffectView` shim (per-material opaque
   fill, since the real vibrancy view doesn't exist), the
   `NSViewController`-in-responder-chain splice (Yosemite
   added VCs to the chain; Mavericks's chain stops at the
   window), the chrome-inset zero-er for layouts baked
   against Yosemite's `NSFullSizeContentViewWindowMask`, the
   HUD-window text-color recolorer, the `NSFontWeight*`
   constants Apple added in 10.10, the universal two-finger
   `scrollWheel:` forwarder, the SIGUSR1 / Ctrl-Opt-Cmd-D
   view-dump trigger, and the whole `KPF_TRACE_*` /
   `KPF_DUMP_CHOOSER` instrumentation harness. None of those
   know or care that they're inside Keynote.

   **Read `kpf_stubs_iwork2015_10_9.m` end-to-end and copy
   the generic blocks into the new stub file verbatim before
   you write a single line of your own.** Then `diff_imports`
   the new app, find what's *additionally* missing on top of
   that baseline, and only hand-write stubs for the genuinely
   app-specific deltas. The KN-, TS-, TMA- prefixed Keynote
   shims (`KNMacEffectChooserAddEffectButton`,
   `TMAExportFormatChooser*`, `KNMacPlaybackWindow`, etc.)
   are app-specific and can be deleted from the copy; the
   rest is reusable as-is.
3. **Confirm the user has both OSes installed, each with an
   era-appropriate Xcode.** This is the single most common
   blocker, and it's invisible from the agent side until the
   diff step returns garbage. The pipeline needs:

   - **Mavericks side**: an actual 10.9 install with **Xcode
     6.x** installed at `/Applications/Xcode.app` (the last
     Xcode that runs natively on 10.9). Xcode supplies
     `clang` + the 10.9 SDK so you can build
     `kpf_stubs.dylib` for the right ABI, and so `nm -gU` on
     `/System/Library/Frameworks/*` returns real symbol
     lists (those framework binaries only exist on a real
     10.9 install, *not* on a current Mac).
   - **Target-OS side**: an actual install of whatever OS
     the target app needs (10.10 / 10.11 / 10.12 / ...)
     with the **Xcode whose bundled SDK matches that OS
     version**, installed at `/Applications/Xcode.app`.
     **Pick the Xcode that *shipped during* the target OS,
     not the highest Xcode the target OS can still run.**
     The bundled SDK is what matters: for a 10.N target you
     want the **10.N SDK**, not the 10.N+1 SDK. Example:
     10.10 Yosemite can technically run Xcode 7.x, but
     Xcode 7 ships with the 10.11 SDK, so its headers say
     things about NSCollectionView that don't apply to
     10.10 — pick Xcode 6.4 (10.10 SDK) instead. Have the
     user look up the right version at
     **[xcodereleases.com](https://xcodereleases.com/)**;
     that page lists every Xcode release with its bundled
     SDK and the macOS versions it runs on, which is exactly
     the cross-reference you need. The contemporary SDK
     headers (inside that Xcode bundle) are what
     `tools/classify_symbols.py` reads to decide whether a
     missing symbol is an Obj-C class, a CF constant, or a
     C function. Without that Xcode bundle in place — or
     with one whose SDK is a release too new — the
     classifier reads the wrong types and the stub generator
     emits stubs with the wrong selectors / signatures. For
     a 10.13+ target this same `/Applications/Xcode.app` is
     also what gets copied to the HFS+ mirror (see the APFS
     wrinkle below), so it has to be there before the copy
     step.

   **You (the agent) are NOT running on the Mavericks or
   target-OS Mac.** Claude Code does not run on Intel
   Macs at all, regardless of OS. The setup is **exactly
   two physical machines**:

   - **An Apple Silicon Mac** (M-series, modern macOS)
     running Claude Code. This is where you live. The
     vintage Intel Mac is remote from here and you talk to
     it over SSH.
   - **One vintage Intel Mac** (2013 or earlier) **dual-
     booted** with **Mavericks (10.9)** on one partition and
     the **target OS** (10.10 / 10.11 / 10.12 / ...) on a
     separate partition (or external SSD), each partition
     with the appropriate Xcode at
     `/Applications/Xcode.app`.

   **Require the dual-boot.** Don't accept a workflow where
   Mavericks and the target OS are on two *different*
   Intel Macs. It looks symmetrical on paper but it's
   brittle in practice: doubled SSH plumbing, two separate
   sets of `~/.config/...` files, two `mDNSResponder`
   identities, a `~/.ssh/known_hosts` to keep in sync, and
   a constant question of "which Mac is which framework
   tree on right now." Dual-boot on one Mac is one host,
   one IP per session, and the OS itself encodes which side
   you're on. If the user proposes the two-Mac setup, push
   back and tell them to consolidate onto a dual-boot.

   If the user has the Apple Silicon Mac but not the
   dual-boot Intel Mac, walk them through getting it set
   up before going further:

   - Pick an Intel Mac model old enough to boot Mavericks.
     Mavericks (10.9) officially supports models up through
     about mid-2013, so the user needs a **2013-or-earlier**
     Mac. There is no "new enough to boot the target" axis
     to balance against — pick by Mavericks support, then
     deal with the target side via patchers below.
   - **If that Mac can't officially boot the target OS, use
     a community OS-installer patcher** to install the
     target OS unofficially:
     - **[dosdude1's patchers](http://dosdude1.com/)** for
       10.13 High Sierra / 10.14 Mojave / 10.15 Catalina on
       unsupported Macs.
     - **[OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher)**
       (OCLP) for macOS 11 Big Sur and later on unsupported
       Macs.
     These run on a 2013-or-earlier Mac fine; they just
     stamp the right SMBIOS / kext shims into the install
     image so the unsupported target OS boots. **The APFS
     wrinkle below still applies once you do this**: even
     when 10.13+ is patched onto a 2013 Mac, it still
     installs onto APFS and Mavericks still can't read
     that volume.
   - Partition the internal disk (or use an external SSD)
     and install Mavericks on one partition + the target
     OS on the other (via the dosdude1 / OCLP patcher
     above if needed) from archived installers.
   - Install the right Xcode `.xip` on each partition. Old
     Xcodes live behind login at
     [developer.apple.com/download/all](https://developer.apple.com/download/all/).
     Tell the user exactly which Xcode version to grab for
     each side.

   **APFS / 10.13+ target wrinkle.** macOS High Sierra
   (10.13) and later install onto APFS by default, and
   Mavericks's kernel cannot mount APFS volumes. If the
   target OS is 10.13 or later, the user *cannot* just
   point the Mavericks-side `nm` / `clang` at the target
   partition: Mavericks will refuse to mount it. The
   workaround is to install the target OS on its own APFS
   volume as usual, then, while booted into that target OS,
   **copy `/System/Library/Frameworks/*`,
   `/System/Library/PrivateFrameworks/*`, and the whole
   `/Applications/Xcode.app` of that 10.13+ OS onto a
   *separate HFS+ volume*** that Mavericks *can* mount.
   (Copying the whole `Xcode.app` is simpler than picking
   out SDK paths, and it gives the pipeline the SDK
   headers, `usr/lib/clang`, and any matching toolchain
   bits in one go.) From that HFS+ mirror, `nm` and
   `classify_symbols.py` work normally. (For 10.10 / 10.11
   / 10.12 targets this is a non-issue: those install on
   HFS+ and Mavericks can mount them directly.)

   Don't skip this step. A user without the target-OS
   install (or with an APFS-only target Mavericks can't
   read) is flying blind on which symbols actually exist
   where, and you will waste hours stubbing symbols that
   turn out to be present, or missing symbols that are
   silently absent from the diff.

4. **Ask the user for SSH access to the dual-boot Intel
   Mac.** Once both partitions are installed, you still need
   to run `dlcheck`, `nm`, and the patcher remotely. The
   README walks the user through enabling Remote Login and
   writing the password to
   `~/.config/mavericks-app-compat/pass`. Since it's the
   same physical Mac on both sides, one host entry is enough;
   the user reboots between Mavericks and the target OS to
   switch sides, and plan your iteration around those reboot
   points (do all your target-OS reads in one session, then
   reboot to Mavericks and do all the patching / building in
   the next session — minimize round-trips).

   For anything beyond plain command-line work, tell the user
   to enable **macOS's built-in Screen Sharing** on the
   Intel Mac (System Preferences → Sharing → Screen Sharing
   on 10.9-10.14, System Settings → General → Sharing →
   Screen Sharing on newer macOS). With Screen Sharing the
   user can open that Mac's desktop on their Apple Silicon
   Mac, then select and copy text out of crash dialogs /
   Xcode View Debugger / Console.app and paste it directly
   into the chat with you. They can also drag files across
   the Screen Sharing window in both directions. SSH alone
   can't do
   either of those, and asking the user to retype a stack
   trace by hand is a waste of everyone's time.
5. **Ask the user to be your eyes.** They cannot help with
   Mach-O parsing, but they are the only one who can launch
   the patched app, open the View Debugger, and tell you what
   class name is misbehaving. Set that loop up explicitly
   (see *Working with the user* below).
6. **When it works, help the user open a PR back to the
   upstream repo.** Commit the new stubs, new install script,
   and any new memory notes. Push to the user's fork (do not
   push to upstream directly). Use `gh pr create` against
   `nfzerox/MavericksAppCompatibilityLayer` with a summary of
   what was stubbed, what's still rough, and a link to the
   user's working bundle if they want to share it.
7. **Even if it doesn't fully work, help them open a draft
   PR or an issue.** Partial-progress reports are explicitly
   what the *Contributing* section of the README asks for. A
   short "here's the symbol diff, here's the first three
   crashes I got past, here's the fourth I can't" is a valid
   artifact.

## Before changing anything, read these in order

1. [README.md](README.md) — short user-facing description so
   you know what the project ships.
2. **[JOURNEY.md](JOURNEY.md)** — *the most comprehensive
   single document in the repo.* A checkpoint-by-checkpoint
   walkthrough of the entire build (47 numbered checkpoints,
   from "won't load" to "Keynote 9.1 on El Capitan"). Every
   non-obvious decision is here, with the symptom, the fix,
   and a "What that taught us" callout abstracting the
   pattern. If you only read one file before touching code,
   this is it.
3. [memory/MEMORY.md](memory/MEMORY.md) — index of finer-
   grained context notes from prior sessions.
4. [memory/feedback_human_in_loop.md](memory/feedback_human_in_loop.md)
   — twelve patterns of human judgment that unstuck the agent
   during this build. The shortest path to "ask, don't grind."
   Read before your first non-trivial change.
5. The relevant `stubs/kpf_stubs_*.m` for the OS / app you're
   touching.
6. `tools/macho_binds.py` if you're going to edit the patcher.

## The mechanism, in one paragraph

A target app's Mach-O binary references symbols and frameworks
that don't exist on the older OS. We:

1. Flip `LC_LOAD_DYLIB → LC_LOAD_WEAK_DYLIB` for missing
   frameworks (`tools/weaken_dylibs.py`, or surgically with
   `tools/patch_surgical.py`).
2. OR `BIND_SYMBOL_FLAGS_WEAK_IMPORT` into bind opcodes for
   missing symbols, so dyld resolves them to NULL instead of
   aborting.
3. Provide an injected stub dylib (`stubs/kpf_stubs_*.m`) with
   minimal Obj-C / C implementations of the missing classes
   and constants the app *actually* uses at runtime.
4. Lower `LSMinimumSystemVersion` in `Info.plist`.
5. Ad-hoc re-sign so the kernel's page-hash check passes.

The non-obvious step is (3). For iWork 2015 / Mavericks it's a
few hundred lines of hand-written Obj-C. For Keynote 9 (much
larger delta) we built a code generator: enumerate every
missing symbol via `dlsym` against the live system, classify
each as ObjC class / CF constant / function via SDK headers,
and auto-emit empty implementations. See `tools/gen_stubs.py`,
`tools/classify_symbols.py`.

## Where things live

- `install_iwork2015.sh` — Mavericks-side single-shot
  installer. This is the user entry point. Run on Mavericks.
- `dist/` — prebuilt artifacts shipped with the repo: the
  Mavericks stub dylib, a Yosemite CoreUI for .car decoding,
  and the `dlcheck` helper binary. **Treat as outputs**;
  rebuild via `stubs/Makefile` and the Mavericks-side build of
  `tools/dlcheck.c`.
- `stubs/` — source of the stub dylib. Naming convention:
  `kpf_stubs_<target>_<min-os>.m` where `<target>` is
  `iwork2015` (the Mavericks/iWork path) or `keynote9` (the
  research path). `<min-os>` is `10_9`, `10_10`, etc.
- `tools/` — the Mach-O patcher. All Python, all
  Python-2.7-compatible so it runs on Mavericks itself.
- `scripts/` — dev workflows (cross-machine via SSH to a
  Mavericks/older-OS guest). `_resolve_host.sh` is the shared
  host-config helper.
- `memory/` — running notebook from prior sessions. Read
  `memory/MEMORY.md` first; it indexes the rest. The
  human-in-the-loop retrospective is the single highest-
  leverage read — it catalogs the kinds of judgment calls the
  agent should ask for explicitly rather than grind on alone.

## What you can rely on

- **Python 2.7 is the floor.** The patcher (`tools/*.py`) runs
  on Mavericks's stock interpreter. Don't introduce f-strings,
  `dataclasses`, or anything else 3.x-only into `tools/`.
- **The iteration loop is tight.** Stub-only changes get
  hot-swapped onto a remote Mavericks Mac in ~5 seconds via
  `scripts/hotswap_*.sh`. Don't propose changes that require
  a full re-patch unless you actually need it.
- **Memory persists across sessions.** `memory/` is the
  running notebook. When you discover something non-obvious —
  a Mach-O quirk, a stub that needed an unusual signature, a
  debugging approach — write a memory file using the schema
  in `memory/MEMORY.md`. When you cite a memory in your
  reasoning, link `[[its-slug]]` so the graph stays connected.

## Working norms

- **SSH to the legacy Mac.** When iterating on a stub or a
  patch, use `scripts/ssh_wrap.sh` / `scripts/scp_wrap.sh`.
  They reconfigure modern OpenSSH to speak Mavericks-era
  key-exchange. Host comes from `$MAV_HOST` or
  `~/.config/mavericks-app-compat/host`; password from
  `$MAV_PASS` or `~/.config/mavericks-app-compat/pass`.
- **Hot-swap loop.** After the first full install, just
  rebuild the dylib and `cp` it into
  `~/<App>.app/Contents/Frameworks/` on the guest. No re-sign
  or re-patch needed for stub-only changes. See
  [feedback_kpf_dylib_hot_swap.md](memory/feedback_kpf_dylib_hot_swap.md).
- **Commit cadence.** On long iterative loops (each iter ~30s
  to several minutes), commit at every visible-progress
  checkpoint without asking. See
  [feedback_commit_cadence.md](memory/feedback_commit_cadence.md).
- **You can't see the UI; the user can.** For UI bugs, the
  user is your visual oracle. Ask them to open Xcode's View
  Debugger against the running patched app and read off the
  class name of the broken view — that's usually enough to
  point you at the right stub. For non-UI bugs, add an
  `NSLog` or `fprintf(stderr, ...)` trace (gated behind a
  `KPF_TRACE_*` env var so it can be toggled), ask the user
  to reproduce, then read the trace. The hot-swap loop makes
  this a fast cycle. Don't speculate about UI behavior in the
  dark when you can ask a one-line question and get a
  definitive answer.
- **When in doubt, read the bind tables.**
  `tools/diff_imports.py /path/to/binary` lists missing
  symbols; the patcher and gen_stubs both consume the same
  manifest format.

## What you should NOT do

- **Don't refactor for refactoring's sake.** Stub files are
  scaffolding around an existing closed-source binary;
  "cleanup" often breaks invariants you can't see without
  re-running the app.
- **Don't widen the bypass.** Each weakened symbol, swizzled
  method, or environment flag is a deliberate scalpel cut.
  If you find yourself reaching for `DYLD_FORCE_FLAT_NAMESPACE`,
  asking to disable SIP, or proposing to strip the entire
  code signature rather than re-signing — stop and ask first.
- **Don't paper over real bugs.** Heap canaries, assertion
  failures, and `objc_msgSend` crashes in this project have
  so far always been genuine — they indicate a stub returning
  the wrong type or an ARC ivar layout mismatch, not noise.
  The 10.10 Keynote-9 abort-bypass PoC is in the repo as a
  *negative* result, proving the canary was real, not as
  something to re-use.
- **Don't rename files in `stubs/` or `dist/`** without
  updating `install_iwork2015.sh`, `setup_iwork.sh`, the
  Makefile, and the matching `manual_symbols_*.txt`. The
  naming is load-bearing.
- **Don't commit `build/`, `originals/`, or `*.dylib` outside
  `dist/`.** `.gitignore` enforces this.
- **Don't strip the `<App>.orig` backup.** Reverting a patch
  is a user feature.

## When to ask the user

- Before doing anything destructive on the Mavericks guest
  (reformatting, reinstalling, wiping `originals/`).
- Before adding a new prebuilt artifact to `dist/`. Prebuilt
  binaries should be reproducible from sources in this repo;
  if you're adding one that isn't, surface it.
- Before adding a runtime dependency on something not shipped
  with Mavericks. The user-facing installer's value is that
  it Just Works on a clean Mavericks Mac.

## Working with the user

- Lead with the technical claim, not the framing. "The bind
  rewrite at offset N is wrong because P" beats "Great
  question — let's look at this together!"
- When you're unsure, say so plainly and propose how to find
  out. Don't fabricate Mach-O internals.
- Long iteration cycles are normal here. If you hit a dead
  end, surface it; don't keep grinding silently.

### Use the user as your eyes and hands

You can't see the patched app run. The user can. Set up a
clean collaboration loop:

- **UI bugs:** ask the user to open Xcode's View Debugger
  while the patched app is attached, then read off the class
  name of the broken view from the hierarchy. With the class
  name in hand, you can usually go straight to the right
  stub. Don't guess at what an unfamiliar UI looks like —
  ask.
- **Behavioral bugs:** add a trace (`NSLog` or
  `fprintf(stderr, ...)`), preferably gated by a
  `KPF_TRACE_*` env var so the user can toggle it cheaply.
  Ask them to do the specific gesture that breaks (e.g.
  "click the Export button while a slide is selected"), grab
  the trace output, feed it back to you.
- **Crashes:** the latest crash log in
  `~/Library/Logs/DiagnosticReports/<App>_*.crash` has a full
  backtrace plus the Dyld Error Message line when it's a
  missing-symbol problem. Always read the latest one before
  asking the user to repro again.

The hot-swap loop (rebuild dylib, `cp` into bundle, no resign)
makes the inner loop fast — exploit it, don't speculate. A
five-second cycle of "add trace, ask user, read result"
almost always beats a five-minute reasoning detour.

## Generalizing this approach

This is a worked example, not a fixed product. The mechanism
generalizes to any pair of macOS releases close enough that
the ABI hasn't moved fundamentally:

- A symbol diff (`tools/diff_imports.py`) lists everything
  the app needs that the host doesn't have.
- A classifier (`tools/classify_symbols.py`) reads SDK
  headers to decide what each symbol is.
- A generator (`tools/gen_stubs.py`) emits empty Obj-C stubs
  for whatever can be expressed as classes / constants.
- Hand-written stubs fill in the rest (functions, anything
  type-sensitive, anything where Apple's no-op default isn't
  acceptable).
- The Mach-O surgical patcher (`tools/patch_surgical.py`)
  wires it all into the binary.

The difficulty spikes whenever the release pair you're
crossing contains a real platform redesign — places where
Apple significantly reshuffled framework internals, ABI, or
runtime expectations rather than just adding new symbols.
The two canonical examples on Mac:

- **10.9 → 10.10 (Yosemite redesign):** the visual / Auto
  Layout / vibrancy / `NSFullSizeContentViewWindowMask` /
  `NSVisualEffectView` / NSViewController-in-responder-chain
  reshuffle. Most of this repo is about absorbing that
  redesign.
- **10.15 → 11.0 (Big Sur redesign):** SwiftUI as a
  first-class citizen, SF Symbols, new control metrics,
  broad AppKit cosmetic and behavioral changes.

In a non-redesign pair (10.10 → 10.11, 10.12 → 10.13, …) the
work is mostly just "add the missing symbols" — a few hundred
lines of empty `@interface/@implementation` plus a handful of
real shims. In a redesign pair the gap is structural and
needs more hand-work. The Keynote-9 → 10.10 work in this repo
hit a genuine memory-layout mismatch (libmalloc szone_t
header differs between the open-source and shipping versions
on Yosemite) and parked. That kind of obstacle is what you
should expect when pushing the approach further.

### Big Sur (11.0) and later: framework extraction

Important operational difference if you're applying this
toolchain to **macOS 11 or newer**: Apple stopped shipping
loose system framework dylibs on disk in Big Sur. The on-disk
files under `/System/Library/Frameworks/*` and
`/System/Library/PrivateFrameworks/*` are stubs; the real
binaries live only inside `/System/Library/dyld/dyld_shared_cache_*`.
That breaks the `nm -gU
/System/Library/Frameworks/<F>.framework/Versions/A/<F>` step
that `classify_symbols.py` relies on for section / type info.

You need to extract the cache before you can run our pipeline
on 11+:

- **[blacktop/ipsw](https://github.com/blacktop/ipsw)** —
  `ipsw dyld extract <cache_path>` splits the shared cache
  into per-framework loose dylibs. Use these for *static*
  analysis (running `nm`, `otool`, `clang -E` against the
  framework, building the classify-symbols typedef map).
  Pretty much a drop-in replacement for the
  `/System/Library/Frameworks/...` directory we use on
  Mavericks.
- **[moraea/dsce](https://github.com/moraea/dsce)** — what
  `ipsw` produces isn't `dlopen()`-able: cross-image
  references inside the cache aren't fixed up by a plain
  extract. For live probing via `dlcheck` (which depends on
  `dlopen` + `dlsym` working) you need `dsce`'s re-linked
  output.

Practical recipe: run `ipsw dyld extract` once on your dev
machine, point `KPF_ROOTFS` at the extracted tree, and the
existing toolchain works. For `dlcheck` on the target
machine, ship `dsce` output instead of the stock cache
extracts.
