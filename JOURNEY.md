# How I ported iWork 2015 to Mavericks in 11 hours

A narrative read of the project from first commit to the
"Mavericks tier is done" checkpoint, every iteration, what
problem it solved, and how the human-plus-agent loop got there.
Total wall-clock from cold start to all three iWork 2015 apps
running on Mavericks: about eleven hours.

This is meant as orientation for someone (human or agent) about
to do similar work: a back-port of a Yosemite/El-Capitan-era
binary to an older OS. The exact symptoms here are
iWork-specific, but the *shape* of each step recurs.

If you only have ten minutes, read the phase headlines and
skim the "What that taught us" boxes. If you're picking the
project up, read the whole thing. Every dead-end below was
real and saved by some specific decision worth knowing about.

The notes below cover the work from "nothing" to the
**Mavericks-done checkpoint**, the point at which iWork 2015
runs cleanly on 10.9. They are then followed by a second
narrative covering the **Keynote 9.1 push** up to "mostly
functional on El Capitan."

### A note on the cadence

The wall-clock time from the very first commit ("get past
dyld") to the **Mavericks-done checkpoint** (iWork 2015 fully
running on 10.9) was **about eleven hours of elapsed time.**
The follow-on Keynote-9.1 → El Capitan push added another
~five and a half hours on top.
Each phase below is annotated with a *(+Δm since previous;
total +H h M m)* line so you can see how the tempo felt from
the inside.

That speed is the headline of this project. The same work
done solo would have been weeks of Mach-O archaeology and
crash-log triage. The fast clock is a function of the
human-plus-agent loop: the agent does the mechanical typing
(read bind tables, write stubs, rebuild, observe crash) while
the human points at the right shelf in the AppKit history
("this is going to be a `NSVisualEffectView` thing", "compare
against the native build", "use the Yosemite CoreUI as-is").

The deltas are aspirational, not prescriptive. If you're
doing the equivalent port for a different app/OS pair, expect
a comparable shape: most of the elapsed time is spent on a
small number of judgment-call moments; the rest is the
mechanical loop running fast.

---

## Phase 0: Get Keynote past dyld

### Checkpoint 1: Get past dyld + version check

*(t = 0)*

Starting point: Keynote 6.6.2, an x86_64 Mach-O binary built
against the El Capitan SDK with a Yosemite deployment target,
won't even load on Mavericks. Two things kill it at startup:

1. **dyld bind failure** on Yosemite-only symbols (`labelColor`,
   `_NSEdgeInsetsZero`, `OBJC_CLASS_$_NSVisualEffectView`, ...).
   Those symbols exist on 10.10 but not 10.9, so dyld aborts.
2. **HIServices `LSMinimumSystemVersion` check** rejects the
   binary because its Info.plist says 10.10.

The first stab at fixing both was the dumbest thing that could
work: a Python tool (`weaken_dylibs.py`) that walks the
Mach-O bind opcode streams and ORs
`BIND_SYMBOL_FLAGS_WEAK_IMPORT` into every binding from
`/System/Library/Frameworks/*` and `/usr/lib/*`. That converts
"missing symbol = fatal" into "missing symbol = NULL." Plus
`LC_LOAD_DYLIB → LC_LOAD_WEAK_DYLIB` for libraries that don't
exist at all (CloudKit on Mavericks). And lower
`LSMinimumSystemVersion` to 10.9.0 in Info.plist, then
`codesign --force --sign -` because the kernel checks per-page
hashes and we just modified bytes.

> **What that taught us.** The agent's first reflex was to
> reach for the *most* complete patch, weaken everything, set
> flat-namespace globally, accept NULL anywhere. That works
> for "does the binary load at all?" but it's the kind of fix
> that has subtle long-tail problems (which we hit two commits
> later). Worth knowing as a debugging stop, not a destination.

Keynote now reaches the AppleEvent dispatcher and opens its
first NIB. Then segfaults trying to dereference a NULL'd-out
`_NSFontWeightLight` `__got` slot.

### Checkpoint 2: Launch past the NIB crash

*(+8m, total +0h08m)*

The crash is a `movsd (%rax), %xmm1` instruction loading a
`CGFloat` from a `__got` slot that resolved to NULL. Disassemble
at the crash PC, find the symbol name in the rebase/bind table:
`_NSFontWeightLight`. Yosemite-only extern CGFloat constant.

This is when the **stub dylib pattern** is born. Build a
`kpf_stubs.m`, link it as a dylib, inject it via
`DYLD_INSERT_LIBRARIES` + `DYLD_FORCE_FLAT_NAMESPACE=1` so
dyld picks up our exports for symbols originally bound
two-level to AppKit/Foundation. First contents:

- `NSFontWeight{UltraLight..Black}` as CGFloat constants with
  Apple's documented values
- `NSEdgeInsetsZero` (zero struct)
- `NSVisualEffectView` (plain `NSView` subclass)
- `+[NSFont systemFontOfSize:weight:]` mapping weight≥0.3 to
  bold
- `+[NSColor labelColor]` and friends routed to nearest 10.9
  equivalents
- `NSWindow` titlebar APIs (`setTitleVisibility:`,
  `setTitlebarAppearsTransparent:`) as no-ops
- `NSLayoutConstraint +activateConstraints:`/`+deactivateConstraints:`
  fallback to per-view add/remove

Keynote stays alive past the previous crash. Console fills with
"Unsupported pixel format in CSI" warnings from the .car asset
catalogs, that's cosmetic, parked for later.

---

## Phase 1: Sledgehammer → scalpel

### Checkpoint 3: Build the surgical static-diff toolchain

*(+3h03m, total +3h11m, the long pause was designing and writing the toolchain)*

The blanket weakener has a real problem: it weakens **every**
binding, including ones to libSystem functions that *do* exist
on Mavericks (`OSAtomicIncrement32Barrier`, `dispatch_*`).
Combined with `DYLD_FORCE_FLAT_NAMESPACE`, those calls get
flat-resolved against the wrong dylib at runtime and the app
mis-binds in subtle ways. We need to weaken *only the symbols
that don't actually exist* on Mavericks.

That requires actually knowing what's missing. Build the
diff:

- **`tools/dlcheck.c`**, a tiny C helper that runs on the
  Mavericks guest. Reads `<lib_path>\t<symbol>` pairs on stdin,
  `dlopen`s each lib, `dlsym`s the symbol, prints
  `OK` / `MISSING` / `LIBMISSING`. Authoritative because it
  asks the actual loader on the actual target.
- **`tools/diff_imports.py`**, enumerates every `(lib, symbol)`
  the binary imports via `dyldinfo`-style Mach-O parsing, asks
  `dlcheck` about each one, emits a JSON manifest of what's
  missing.
- **`tools/classify_symbols.py`**, runs on the guest with
  the 10.10 SDK accessible. For each missing symbol, uses
  `nm -m` to learn its section (`__TEXT,__text` = function,
  `__DATA,__const` = data) and greps the SDK headers for the
  C declaration. Categorises into `NSString_const`, `CGFloat`,
  `NSEdgeInsets`, `c_string_const`, `function`, `objc_class`,
  `data_unknown`.
- **`tools/patch_surgical.py`**, consumes the manifest and
  rewrites *only those* bind opcodes:
  - `LC_LOAD_DYLIB → LC_LOAD_WEAK_DYLIB` for missing libs.
  - `SET_ORDINAL_*` rewritten to
    `SET_SPECIAL_IMM(BIND_SPECIAL_DYLIB_FLAT_LOOKUP)` so dyld
    flat-searches *for that one symbol*, our stub dylib
    provides it.
  - `BIND_SYMBOL_FLAGS_WEAK_IMPORT` OR'd into the trailing
    flags byte so unresolved symbols NULL out instead of
    aborting.
- **`tools/macho_binds.py`**, shared parser that yields bind
  records with byte offsets so `patch_surgical` can edit in
  place without re-encoding the stream.
- **`tools/gen_stubs.py`**, consumes the classified manifest
  and emits **typed** Obj-C shims per kind. `NSString_const`
  becomes `NSString * const X = @"X"`. `CGFloat` becomes
  `const CGFloat X = 0.0`. Classes get
  `@interface/@implementation` pairs. Functions get flagged for
  hand-coding in `kpf_stubs.m`.

Concrete impact: Keynote 6.6.2 went from "2,989 bindings
weakened" to "63 symbols actually flat-redirected + 6 libs
weak-loaded." Smaller blast radius, fewer libSystem collisions,
and `DYLD_FORCE_FLAT_NAMESPACE` no longer needed (we'll drop it
in the next commit).

> **What that taught us.** *The blanket weakener is a debugging
> stop; the surgical pipeline is the destination.* When the
> early `install_iwork2015.sh` for the release was naively built
> on top of `weaken_dylibs.py` again, it broke Pages at launch
> with the same kind of libSystem-collision bug. The lesson
> went into the repo via the human asking "what did the Mavericks-done checkpoint
> do that worked?" and noticing the regression. See
> [[feedback-human-in-loop]] §1.

### Checkpoint 4: ControlMaster SSH + drop flat-namespace

*(+0m, total +3h11m, landed alongside the toolchain)*

Two unrelated fixes that arrived together because both
unblocked the iteration loop:

- Modern OpenSSH talking to Mavericks 6.2 was getting throttled
  on rapid auth attempts. `ssh_wrap.sh` + `scp_wrap.sh` now
  multiplex over a single TCP connection via `ControlMaster`
  with `ControlPath` under `/tmp` (not `$TMPDIR`, macOS's
  `$TMPDIR` path overflows `sockaddr_un`'s 104-byte limit, an
  obscure gotcha that cost an hour). After this, dozens of
  `scp` + `ssh` calls per minute are fine.
- `launch_keynote.sh` drops `DYLD_FORCE_FLAT_NAMESPACE=1`.
  Per-symbol flat-lookup is now baked into the binary by
  `patch_surgical`, so the process-wide override is no longer
  needed, and was actively harmful: it made libSystem calls
  like `OSAtomicIncrement32Barrier` resolve flat (potentially
  to our shim or to NULL) and miss the real Mavericks impl.

---

## Phase 2: Typed shims and real behavior

### Checkpoint 5: Typed shims + 10.10 category methods

*(+0m, total +3h11m)*

The auto-generated stubs were untyped (`void *X = NULL`) which
satisfies the linker but breaks `-isEqual:` and any consumer
that does pointer-vs-pointer comparison. Regenerate with
typed Obj-C, plus hand-written shims for everything
`classify_symbols` flagged as a function:

- `NSDocument`: `-userActivity`, `-alternateContents`,
  `-isInViewingMode`
- `NSViewController`: `-isViewLoaded` (via KVC peek at `_view`),
  lifecycle no-ops
- `NSWindow`: `-contentLayoutRect`, `-contentViewController`,
  `-occlusionState`
- `NSScrollView`: `-contentInsets`, `-scrollerInsets`
- `NSResponder`: `-userActivity`
- `NSAccessibility{Frame,Point}InView`: real coordinate
  conversion via the view's window
- `ABRecord`: `-displayName` synthesised from first/last/org
- `NSUserActivity`: full class stub with init, eligibility
  flags, become/resign/invalidate
- `LSCopyApplicationURLsForBundleIdentifier`: wraps the 10.9
  `LSFindApplicationForInfo` into a single-element `CFArray`
- `CFBundleCopyLocalizedStringForLocalization`: drops the
  locale arg, forwards to `CFBundleCopyLocalizedString`

Two notable subtleties:

- **`NSAppearanceNameVibrantDark/Light` aliased to the literal
  value of `NSAppearanceNameAqua`** (the string
  `"NSAppearanceNameAqua"`). Doing this means
  `+[NSAppearance appearanceNamed:]` returns a real appearance
  on 10.9, and `-[NSPopover setAppearance:]` stops raising.
- **`NSPopover.setAppearance:` IMP-replaced** because Apple
  silently changed the property's type from
  `NSPopoverAppearance` (int enum) in 10.9 to `NSAppearance *`
  in 10.10. Keynote calls it with a pointer; 10.9 reinterprets
  as an int and corrupts. The shim ignores the arg.
- **`OSAtomicIncrement32Barrier` and friends in a separate
  `.c` TU** because the 10.9 SDK declares them `__inline static`
  in `<libkern/OSAtomic.h>`. We can't define `extern` versions
  in any `.m` that imports that header without colliding. Put
  the externs in `kpf_osatomic.c`, pin the symbol names via
  `asm()` rename so the C identifiers stay unique.

### Checkpoint 6: Real storage for getter/setter pairs

*(+4m, total +3h16m)*

The category getter/setter pairs from the previous commit
returned constants and discarded sets, which means

```objc
foo.preferredContentSize = NSMakeSize(800, 600);
NSSize sz = foo.preferredContentSize;  // expected 800x600, got 0x0
```

silently disagrees with itself. Convert every category property
to **associated-object storage keyed by the getter SEL**. Inline
helpers per primitive type (`id`, `BOOL`, `NSInteger`, `CGFloat`,
`NSSize`, `NSEdgeInsets`). Covers `NSDocument.userActivity`,
`NSWindow.titleVisibility`/`titlebarAppearsTransparent`/
`contentViewController`/`titlebarAccessoryViewControllers`,
`NSScrollView.contentInsets`, `NSOperation.qualityOfService`,
`NSViewController.preferredContentSize`/`childViewControllers`,
and the rest.

`NSUserActivity` becomes a real shim class with `@synthesize`d
storage so Keynote's pre-`setUserActivity:` configuration
survives.

### Checkpoint 7: `fileTypeFromLastRunSavePanel` fallback

*(+17m, total +3h34m)*

Tiny but instructive. iWork's
`writeToURL:ofType:forSaveOperation:` consults
`-fileTypeFromLastRunSavePanel` directly. Apple's default
returns nil when no save panel has yet been shown. Our shim
returned nil unconditionally, so File → Save tripped iWork's
own assertion. Fix: return the document's current `-fileType`
when no save-panel selection has been stashed, and back the
property with associated-object storage so any setter still
sticks across reads.

> **What that taught us.** "Empty stub" isn't the same as
> "honest stub." When you're shimming a property the app
> actually reads, return *something the original implementation
> could plausibly have returned*. The fallback chain here
> (`fileTypeFromLastRunSavePanel ?: fileType`) is the kind of
> behavior reconstruction the empty-stub approach misses.

---

## Phase 3: Event routing and the responder chain

### Checkpoint 8: Splice NSViewController into the responder chain

*(+23m, total +3h57m)*

Symptom: the slide canvas was **click-deaf**. Left-click did
nothing; keyboard didn't reach the canvas. Right-click *did*
show a context menu, which was the clue.

Why right-click worked: right-mouse-down walks `-menuForEvent:`
which traverses the responder chain *as the receiver expects
it on 10.10* (view → its VC → superview), and our `-menuForEvent:`
forwarding was OK by accident.

Why left-click failed: `-mouseDown:` dispatch walks
view → superview → ... straight up the chain. On 10.10
NSViewController *auto-inserts itself between view and
superview*, so the click reaches the VC. Keynote's
`TSDMacCanvasViewController` owns `-mouseDown:`. On 10.9 the
VC isn't in the chain, so the click skips it and goes to
NSClipView, which drops it.

Fix: swizzle three methods to replicate Apple's 10.10 wiring.

- `-[NSViewController setView:]`, on first assignment,
  associate the view with its controller
  (`OBJC_ASSOCIATION_ASSIGN` so we don't retain-cycle).
- `-[NSView nextResponder]`, if the view has an associated
  controller, return the controller; otherwise fall through to
  NSResponder's inherited IMP.
- `-[NSViewController nextResponder]`, return the view's
  superview.

The mechanical trap: **use `class_addMethod`, not
`method_setImplementation`**. Both `NSView` and
`NSViewController` *inherit* `-nextResponder` from `NSResponder`,
so `class_getInstanceMethod` walks up to `NSResponder` and
`method_setImplementation` would replace it **globally**.
First attempt did exactly that, every `NSResponder` in the
process started calling our hook, which then crashed
`-[TSDCanvasView view]: unrecognized selector` from inside the
hook. With `class_addMethod` we add a fresh IMP only to the
target class and capture `NSResponder`'s original IMP for the
fallback path. See [[objc-swizzle-subclass]].

> **What that taught us.** The Yosemite responder chain change
> is silent, there's no API in the SDK that says "VC is now in
> the chain by default." You have to know this. The agent didn't
> know it on its own; the human (with Mac-app experience) pointed
> at it. See [[feedback-human-in-loop]] §6.

### Checkpoint 9: On-demand UI dump (SIGUSR1 / Ctrl-Opt-Cmd-D)

*(+7m, total +4h05m)*

Building any UI debugger you need without Xcode's view debugger
(which can't reach a patched, ad-hoc-resigned process). Write
out the full window + view hierarchy as plain text:

- For every `NSWindow`: class, frame, styleMask, key/visible
  state, toolbar info.
- For every `NSView`: class, frame, bounds (when nonzero-origin),
  hidden/alpha, `intrinsicContentSize`,
  `translatesAutoresizingMaskIntoConstraints`, stringValue/title.
- For every `NSLayoutConstraint`: first/second item class +
  attribute, relation, multiplier, constant, priority.

Triggered two ways: `kill -USR1 <pid>` from the shell, or
`Ctrl-Opt-Cmd-D` from any Keynote window via
`addLocalMonitorForEventsMatchingMask:NSKeyDownMask`. Output at
`/tmp/kpf_view_dump_<App>.txt`, then `scp` back. Beeps once
when done so you know the trigger fired.

Signal handler dispatches the actual dump onto the main queue
view access isn't async-signal-safe.

This is the single most useful diagnostic tool in the project.
A plain-text dump is diff-able across runs in a way a UI tree
isn't.

### Checkpoint 10: Chrome inset fix + faithful 10.10 stubs + tracers

*(+24m, total +4h30m)*

Three things landed together because each unblocked the other.

**Chrome inset (the +73pt gap).** Keynote 6.6.2 was built
expecting `NSFullSizeContentViewWindowMask`, the Yosemite
window mask where `contentView` extends *behind* the titlebar
and toolbar for vibrancy. On Mavericks `contentView` starts
*below* the chrome, so Keynote's hardcoded "leave room for the
toolbar overlay" offsets become a visible 73pt gap above the
slide navigator, the inspector, and any top-anchored sidebar.

Fix:

- Strip `NSFullSizeContentViewWindowMask` (bit 15) from
  `-[NSWindow styleMask]`.
- Force `-titlebarAppearsTransparent` to `NO` and
  `-titleVisibility` to `Visible`.
- Make `-contentLayoutRect` return `[contentView bounds]`
  (the prior implementation returned
  `-contentRectForFrameRect:`, which is in *screen*
  coordinates, callers used it as if it were content-view-
  relative and ended up at the window's screen y-offset).
- Hook `-[NSView addConstraint:]` and the window-show methods
  to **zero any Top-Top, mul=1, Equal constraint whose constant
  magnitude matches the live chrome height** (window frame
  height − contentView bounds height, = 22 + 51 on Mavericks).

`-constant` read inside `@try/@catch` because NIB-loaded
constraints can carry symbolic values (`NSSpace`) that raise
"unable to resolve symbolic constant" on the 10.9 theme.

**Faithful class stubs from `otool -ov`.** Empty
`@interface/@implementation` got us past dyld, but Keynote
*sends real selectors*. Force-Touch trackpads crashed on
`-initWithPressureBehavior:`; haptics crashed on
`+defaultPerformer`. The fix: read the public method list off
the Yosemite AppKit dylib:

```
otool -ov /Volumes/Yosemite/.../AppKit.framework/AppKit \
  | grep -A1 'NSPressureConfiguration$'
```

`NSPressureConfiguration` gets `-initWithPressureBehavior:`,
`-pressureBehavior`, `-set`, NSCoding. Single `int64` ivar at
offset 8, preserved so any consumer reading the ivar directly
still works.

**Diagnostic tracers.** All env-gated so they're off in normal
runs:

- `KPF_TRACE_EVENTS=1`: `NSEvent` local-monitor logs every
  L/R-mouse and keyDown with window/locationInWindow/hitTest
  target/first responder. Used to confirm mouse events were
  reaching `TSDCanvasView`, and the missing piece was
  NSViewController not being in the chain.
- `KPF_TRACE_CONSTRAINTS=lo,hi`: wraps NSLayoutConstraint's
  factory, designated init, initWithCoder, and `setConstant:`
  plus NSView's `addConstraint:`. Logs constraints whose
  constant lands in `[lo, hi]` with a stack trace. This is how
  the +73pt chrome offset was traced back to
  `KNMacContentContainerSplitView`'s `updateConstraints`.
- `kpf_dump_keynote_event_owners`: enumerates every TS/KN/TMA-
  prefixed class with its *own* mouse/key handler. Showed
  `mouseDown` was owned by `TSDMacCanvasViewController`, not
  the view, which led to the responder-chain fix.

> **What that taught us.** Diagnostic tooling pays for itself
> within the same commit it's added. Building these tracers
> didn't slow the project down; they unblocked the next three
> fixes each.

---

## Phase 4: Scroll wheel forwarding

### Checkpoint 11: Conditional auto-install of `setContentViewController:`'s view

*(+6m, total +4h36m)*

`KNMacPlaybackWindow` opens for slide playback as an empty
`contentView` and relies on the 10.10 behaviour where
`-setContentViewController:` *also* installs the controller's
`-view` as the window's `contentView`. With our shim only
storing the controller, playback rendered as a black screen.

Earlier we auto-installed unconditionally, that broke the
main document window because Keynote programmatically wires a
`KNMacDocumentBackgroundView` as the contentView, then later
assigns a view controller. The unconditional auto-install
clobbered the canvas.

10.9-safe middle ground: **only auto-install when the current
contentView is a stock `NSView` with no subviews.** The main
window's pre-set `KNMacDocumentBackgroundView` is a subclass
and trips the guard; the playback window's default `NSView`
matches and gets the swap.

### Checkpoint 12 and Checkpoint 13: Forward scrollWheel: past VCs

*(+28m across two commits, total +5h05m)*

Two-finger pan on the slide canvas didn't move. Then it didn't
work in the inspector, template picker, or media browser
either.

`TSDMacCanvasViewController` overrides `-scrollWheel:` and
consumes the event without ever calling super, on the 10.10
assumption that the actual scroll motion happens by a separate
path. On 10.9 neither alternative path fires and the
enclosing `NSScrollView` never gets the event.

Two complementary forwarders cover all cases:

- **Category on `NSViewController`** providing a `-scrollWheel:`
  that forwards to `view.superview`. Fires for every VC
  subclass that *doesn't* override `-scrollWheel:` itself.
- **`kpf_install_vc_scroll_forward`**: at app launch, walk
  `objc_copyClassList` and IMP-swap `-scrollWheel:` on every
  `NSViewController` subclass that *does own* its own
  override. The wrap calls Keynote's original (so local
  tracking state still updates) and then forwards to
  `view.superview`.

The trap: **don't wrap `NSViewController` itself.** The
category already provides a forwarder there, and wrapping it
would intercept `[super scrollWheel:]` calls from concrete
subclasses and re-enter the wrap. `kpf_lookup_orig` walks the
receiver class chain, finds the subclass's original IMP again,
runs it, infinite recursion, stack overflow during startup.
The first attempt crashed within seconds of launch from
exactly this.

---

## Phase 5: Extend to Pages and Numbers

### Checkpoint 14: Apply the toolchain to all three apps

*(+12m, total +5h18m)*

The toolchain worked **unchanged** for Pages (66 missing
symbols) and Numbers (60 missing symbols). Only one
genuinely-new symbol surfaced
`_NSSplitViewItemUnspecifiedDimension`, and the existing
`data_unknown` slot handled it as a CGFloat = 0.0.

Three behavioral additions were needed:

- `NSLayoutConstraint -setActive:` / `-isActive` (10.10
  instance API). Pages and Numbers flip individual constraints
  on/off via the instance setter rather than the
  `+activateConstraints:` array form Keynote uses.
- `kpf_host_view_for_constraint()`, proper
  lowest-common-ancestor walk for picking the host view when
  installing a cross-view constraint. The previous
  "use `first.superview`" shortcut crashed Pages with "Unable
  to install constraint on view. Does the constraint reference
  something from outside the subtree of the view?" on a
  `NSStackView.left == TMAVibrantContainerView.left` constraint,
  because the two views lived in sibling branches of the tree.
- `NSObject -setContentInsets:` fallback. Numbers crashes with
  `*** -[NSProxy doesNotRecognizeSelector:setContentInsets:]`
  during launch, some `NSProxy` forwards `setContentInsets:`
  to a target whose class isn't `NSScrollView`. A no-op
  default on `NSObject` keeps the forwarding happy.

`launch_iwork.sh` parameterizes the launcher over Keynote /
Pages / Numbers, same dylib, only the binary patch is per-app.

### Checkpoint 15: Reproducible end-to-end install via `LSEnvironment`

*(+13m, total +5h31m)*

Before this, you ran the patcher manually and then launched via
a wrapper script that set `DYLD_INSERT_LIBRARIES`. Replace both
with `setup_iwork.sh <App>` that produces a **double-click-
launchable bundle**:

1. Re-copy pristine bundle from `/Volumes/Yosemite/...`.
2. Pull binary, run `diff_imports` against live Mavericks
   dylibs (via `dlcheck` on the guest).
3. Run `classify_symbols` on the guest (needs 10.10 SDK
   headers + Yosemite dylibs).
4. Surgical-patch the binary locally.
5. On the guest: install patched binary; embed
   `kpf_stubs.dylib` at `Contents/Frameworks/kpf_stubs.dylib`
   (relocatable, `@executable_path` expands in
   `DYLD_INSERT_LIBRARIES` on 10.9); set
   `LSMinimumSystemVersion = 10.9.0` and add the
   `LSEnvironment` dict so launchd applies the injection
   automatically; ad-hoc sign with `--deep`; `lsregister -f`.

After this, the app launches directly from Finder / Dock / `open`
with no wrapper. The launch script is still useful for
debugging (env passthrough for `KPF_TRACE_*`), but day-to-day
is `open Keynote.app`.

### Checkpoint 16: Drop the `-contentInsets` NSObject fallback (stret hazard)

*(+7m, total +5h38m)*

A subtle ABI bug. `-contentInsets` returns `NSEdgeInsets`
a 32-byte struct, so the compiler emits `objc_msgSend_stret`
at the call site **only if the caller's declared return type
matches**. A caller that probes
`respondsToSelector:contentInsets` but treats the result as
`id` will use plain `objc_msgSend`; our stret IMP leaves `%rax`
holding the hidden struct-return buffer pointer; caller stores
that into an `id` slot; later `release` crashes deep in
dispatch.

The Numbers crash was actually on `-setContentInsets:` (void
return, safe). Keeping only that side of the fallback
satisfies `NSProxy doesNotRecognizeSelector:` without
exposing the struct-return ABI hazard. Drop the getter
fallback.

> **What that taught us.** Obj-C category fallbacks on
> `NSObject` are powerful but ABI-sensitive. Any selector that
> returns a struct ≥ 16 bytes is a `_stret` trap; safe only when
> *every caller* uses the typed signature. Avoid unless you can
> prove that, or restrict to the void-return half.

---

## Phase 6: CoreUI substitution

### Checkpoint 17: Bundle Yosemite CoreUI inside each `.app`

*(+16m, total +5h54m)*

The .car asset catalog warnings ("Unsupported pixel format in
CSI") were finally addressed by noticing the simplest fix:
Mavericks's CoreUI is `231.1.0`; Yosemite's is `308.6.0`; the
Yosemite one handles the newer format and `dlopen`s cleanly on
10.9 because it doesn't reference any 10.10-only symbols.
**They share the same install_name**
(`/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI`),
which means a `DYLD_FRAMEWORK_PATH` override pointing at our
embedded copy substitutes it for every consumer (AppKit,
the iWork binary, all of it).

First implementation: `setup_iwork.sh` copies the framework
into `Contents/Frameworks/CoreUI.framework` and sets
`LSEnvironment.DYLD_FRAMEWORK_PATH` to the absolute path of
that directory. Mavericks's dyld walks override paths first.

> **What that taught us.** When a closed-source framework is
> too old to handle newer file formats, **the next OS's
> version of that framework is a good starting point**, drop
> it in, see how far you get, then shim only what it pulls in
> that the older OS doesn't have. This is OCLP's playbook in
> miniature. For the Mavericks ↔ Yosemite gap it worked
> *unmodified* (Yosemite CoreUI has no 10.10-only deps that
> aren't already in 10.9). For larger gaps the drop-in is
> still the right first move, but you'll have shimming to do:
> on El Capitan, dropping Sierra CoreUI works in principle but
> Sierra CoreUI pulls in `TextureIO.framework` + `libate.dylib`
> + a handful of CG additions
> (`_kCGColorSpaceExtendedLinearSRGB`, ...). We deferred that
> as an exercise for the reader since the project's main focus
> is Mavericks; see
> `memory/project_kpf9_sierra_coreui_sideload.md` for what's
> blocking it. The agent's first instinct was to write CSI
> format-converter shims from scratch; the human's was "just
> drop in the Yosemite CoreUI and see what breaks." The
> human's instinct won by ~200 lines of code. See
> [[feedback-human-in-loop]] §12.

### Checkpoint 18: `LC_LOAD_DYLIB` injection so the bundle is movable

*(+6m, total +6h01m)*

`DYLD_FRAMEWORK_PATH` on Mavericks dyld does **not** expand
`@executable_path` (it does in `DYLD_INSERT_LIBRARIES`, but not
here, verified by direct test). So the previous commit's
self-containment was tied to the bundle's exact on-disk path.
Moving `~/Keynote.app` to `/Applications/` broke icon loading.

`LC_LOAD_DYLIB` *does* expand `@executable_path` on 10.9.
Switch to injecting an extra `LC_LOAD_DYLIB` pointing at the
bundled framework. `patch_surgical.py` grew an `--inject-dylib`
flag that appends an `LC_LOAD_DYLIB` into the slack space at
the end of the load-command area and updates
`ncmds`/`sizeofcmds`. Version fields set to compat=0 so dyld
accepts any version.

Drop `DYLD_FRAMEWORK_PATH` from `LSEnvironment`. The bundle is
now truly relocatable.

Side effect: `KNMacEffectChooserAddEffectButton` is no longer
0pt tall, the underlying 10.10 image asset that fed its
background now loads correctly. One bug, closed without
investigating it directly.

---

## Phase 7: Inspector positioning, NSColor fidelity, vibrancy

### Checkpoint 19: Anchor inspector to contentView + consolidate chrome fix

*(+56m, total +6h57m)*

Pages and Numbers inspectors were rendering at the **bottom**
of their containers. Cause: `-[NSWindow contentLayoutGuide]`
returned nil from our shim. Keynote builds constraints like

```
view.topAnchor.constraintEqualToAnchor:window.contentLayoutGuide.topAnchor
```

When `contentLayoutGuide` is nil, the constraint collapses to
"view.Top == 0", in default non-flipped NSView coords that
pins the top edge to y=0, which is the *visual bottom* of the
superview.

Fix: return the window's `contentView` from the shim. On 10.9
the `contentView` already excludes the chrome, so its bounds
rectangle is exactly what `contentLayoutGuide` resolves to on
10.10.

Same commit consolidates the chrome-inset fix. The prior
approach had five overlapping triggers (`-addConstraint:`,
`-viewDidMoveToWindow:`, `-makeKeyAndOrderFront:`,
`-orderFront:`, plus the existing makeKey hook) because each
individually missed cases (constraint added before view in
window, or re-installed during `-updateConstraints` after
window-show, or only materialised when entering Edit Master
Slide mode). Collapse to **one `NSWindowDidUpdateNotification`
observer** that fires after every window-update cycle (so
after AppKit's layout pass has run anything Keynote added)
and walks the contentView subtree zeroing chrome-style
constraints. Five hooks → one notification, code shrinks ~150
lines.

### Checkpoint 20: Faithful NSColor mappings

*(+2m, total +7h00m)*

The earlier `NSColor` shims reached for whatever `+named`
accessor existed on 10.9. Three problems:

- Every secondary/tertiary/quaternary label resolved to
  `-disabledControlTextColor` (a single medium gray). There
  was no hierarchy, a "secondary" label and a "quaternary"
  label looked identical.
- `placeholderTextColor` and `separatorColor` also fell back
  to that same gray.
- `systemRedColor` / etc. mapped to `+redColor` and friends,
  which are saturated CMYK primaries, way brighter than the
  muted UI accents Apple uses for status dots and badges.

Use the values Apple shipped on 10.10:

- Label hierarchy: pure black at descending alpha
  (`0.85 / 0.50 / 0.25 / 0.10`).
- `placeholderTextColor`: black at 0.30; `separatorColor`: 0.10.
- `linkColor`: (0.0, 0.4, 0.8), the Aqua link blue.
- `systemRedColor` etc.: the calibrated values from when Apple
  introduced these accessors (`#FF3B30`, `#4CD964`, `#007AFF`,
  `#FF9500`, `#FFCC00`, `#A2845E`, `#FF2D55`, `#5856D6`,
  `#8E8E93`).

> **What that taught us.** A no-op color shim is *worse* than
> no shim. The Aqua link blue and the muted status reds are
> the visual signature of the era, if they collapse to
> "redColor" the app looks visibly off-brand even when it
> "works." See [[feedback-human-in-loop]] §7.

### Checkpoint 21: `-[NSWindowController contentViewController]` (10.10 addition)

*(+10m, total +7h10m)*

The record-slideshow button's `mouseDown:` → `sendAction:`
landed in a code path that queries the controller's
`contentViewController` on the way to setting up the recording
window. On 10.9 the method doesn't exist on
`NSWindowController`. Category forwards to
`self.window.contentViewController`, which our existing
`NSWindow` category already shims with associated-object
storage.

### Checkpoint 22: Per-material opaque fill for NSVisualEffectView

*(+13m, total +7h23m)*

The empty `NSVisualEffectView` stub left
ruler/comments-bar/sidebar surfaces fully transparent on
Mavericks, so page content bled through. Implement
`-drawRect:` with a material-keyed palette:

- `Sidebar` and default Light: (227, 231, 237), the
  Mavericks Finder sidebar blue-gray.
- Separate shades for Dark, UltraDark, Selection, Menu,
  Popover, MediumLight, Titlebar.

Preserve the *intent* of the original even if you can't
reproduce the blur.

### Checkpoint 23: Clamp `setContentInsets:` to zero

*(+8m, total +7h32m)*

iWork's `-p_updateCanvasScrollViewContentInsets` pushes a top
inset equal to the title+toolbar height to keep the canvas
from disappearing under Yosemite's full-size content view. On
Mavericks the contentView never extends behind the chrome, so
adopting that inset double-counts and leaves a tall empty band
above the document. Drop the value before it goes into the
associated-object backing.

---

## Phase 8: Edge cases and feature crashes

### Checkpoint 24: `resign_iwork.sh` for debugger attaches after hot-swap

*(+38m, total +8h11m)*

Hot-swapping `kpf_stubs.dylib` invalidates the bundle's
`cs_mtime`, so Mavericks's kernel SIGKILLs any process that
attaches to its mapped pages, Xcode's view debugger and `lldb`
both trip this. Re-signing rebuilds the signed manifest from
current mtimes. A one-line script that does
`codesign --force --deep --sign -` on each of the three iWork
bundles in `$HOME`. Only needed when you actually want to
attach a debugger; for normal launches the hot-swap is safe.

### Checkpoint 25: `TSDGLLayer setMaximumDrawableCount:` no-op

*(+19m, total +8h30m)*

Setting a Trace build animation in Keynote crashed with
`unrecognized selector -[TSDGLLayer setMaximumDrawableCount:]`
a `CAMetalLayer` API introduced in 10.11 that doesn't exist
on Mavericks. Install a no-op setter via `class_addMethod`.

### Checkpoint 26: Hide system title bar on iWork custom-titlebar windows

*(+14m, total +8h45m)*

Keynote's Chart Data Editor (`NSPanel` with
`TSCHMacCDEWindowTitleBar` + `TSCHMacCDEWindowStandardButtonsView`)
frames its own title bar at `y = windowHeight - barHeight`,
assuming the Yosemite full-size-content layout. On Mavericks
the contentView sits below the chrome, so the iWork bar was
clipped to ~13pt and the system title bar sat as a blank strip
above it.

Drop `NSTitledWindowMask` on detection so the contentView
fills the window, then snap the iWork bar to its top.
Trade-off: Mavericks borderless windows lose AppKit's drop
shadow; `setHasShadow:YES` doesn't restore it.

### Checkpoint 27: `AHLookupAnchor` interposition

*(+5m, total +8h50m)*

`-[TMAApplicationDelegate showKeyboardShortcuts:]` calls
`AHLookupAnchor(bookName, "keyboardShortcutAPDID")` to verify
the help anchor before opening Help Viewer. The anchor exists
in the Yosemite-format help bundle but the Mavericks Help
system can't resolve it; `AHLookupAnchor` returns non-zero,
Keynote raises `NSException("AHLookupAnchor failed")`, app
dies.

Interpose `AHLookupAnchor` via `__DATA,__interpose` so failures
are silently converted to `noErr`. Help Viewer may still not
navigate to the right anchor, but clicking the menu item no
longer terminates.

### Checkpoint 28: Export-sheet format strip clickable

*(+10m, total +9h01m)*

The Export sheet's PDF/PowerPoint/QuickTime/HTML/Images/
Keynote'09 strip is `TMAExportFormatChooserView`
`NSCollectionView` subclass with `TMAExportFormatChooserItemView`
per cell. Neither declares `-mouseDown:`, so on Mavericks the
click vanished (arrow keys still worked because the chooser
implements its own `-keyDown:`). The shipped binary relied on
10.10 `NSCollectionView` semantics to route item clicks into
`selectionIndexes`; 10.9 NSCollectionView doesn't.

Two patches:

- `NSTextField` label-style hit-test pass-through. The cell's
  only child is a non-editable, non-selectable `NSTextField`
  that fills the cell width; 10.10 returns nil from
  `-hitTest:` for such "labels", letting the parent receive
  the click; 10.9 swallows it. Override `-hitTest:` on
  `NSTextField` so editable==NO && selectable==NO returns nil.
- `-mouseDown:` on `TMAExportFormatChooserItemView` that walks
  up to the parent `NSCollectionView`, computes the clicked
  item's index by sorted x position among same-class siblings,
  and pushes it through `-setSelectionIndexes:`. Same setter
  the chooser's own `-keyDown:` uses, so KVO drives the
  controller's selectedIndex exactly as if you'd pressed
  arrow keys.

Ship `KPF_DUMP_CHOOSER` env-gated method-list dumper so the
class spelunking is reproducible.

### Checkpoint 29: Invoke `-viewDidLoad` on iWork view controllers

*(+8m, total +9h09m)*

`KNMacPlayToolbarMenuItemViewController` populates its three
text fields in `-viewDidLoad`, but the method is a 10.10
NSViewController addition, on 10.9 it's never invoked, so
the Play popup menu items render their nib placeholders
"Upper" / "Middle" / "Lower" instead of "Play Slideshow" /
"Play Recorded Slideshow" / etc.

Backfill a no-op `-viewDidLoad` on `NSViewController` itself
so `[super viewDidLoad]` in subclass overrides resolves
cleanly. In the existing `-setView:` shim, fire `-viewDidLoad`
once (associated-object guarded) if the actual class IMP
differs from the no-op.

---

## Phase 9: HUD windows

### Checkpoint 30: Rounded HUD fill on `KNMacHUDBackgroundView`

*(+10m, total +9h20m)*

The Presenter Display "Customize Options" floating panel uses
`KNMacHUDBackgroundView` (a `NSVisualEffectView` subclass that
overrides `-wantsUpdateLayer = YES` and `-updateLayer`). On
Yosemite the layer is composited against the VFX blur; on
Mavericks our shim's `-drawRect:` is never reached because
AppKit routes drawing through `-updateLayer` when
`wantsUpdateLayer` is YES, the window renders completely
see-through.

Force `-wantsUpdateLayer = NO` on the subclass so AppKit falls
back to `drawRect:`, then add a subclass-local `drawRect:` that
paints a rounded black-w-0.85 fill. Inheriting the VFX shim's
`NSRectFill` would lose the corner rounding. Both patches stay
scoped to the subclass via `class_addMethod`.

### Checkpoint 31: Light HUD text + system text on bordered buttons

*(+22m, total +9h43m)*

Mavericks's `NSColor.labelColor` / `controlTextColor` are
static black; on the dark HUD fill we just painted every label
reads black-on-black. Yosemite's appearance-aware colors return
light here because the window's appearance is `VibrantDark`.

Approximate it without rebuilding `NSAppearance`: walk the HUD
subtree on `NSWindowDidUpdate` (plus 0.2s and 1.0s delayed
retries to catch subviews wired up after the first observer
fire), and force every `NSTextField` under the HUD to light
text, both `-textColor` and the `attributedStringValue`
foreground. `NSMatrix` radio cells aren't subviews, so iterate
them explicitly and rewrite `-attributedTitle` while preserving
the cell's original font and attributes.

Two wrinkles:

- **Bordered `NSButton` ancestors** (Cancel / OK / Use Auto
  Layout) draw a light system bezel; their title text is the
  system color and must not be forced to light, or it becomes
  invisible on its own bezel. `kpf_view_under_HUD` walks up
  and returns NO as soon as it hits a bordered `NSButton`.
- Clicking a checkbox makes iWork re-set `-textColor` on the
  row label, undoing the walk. Globally swizzle
  `-[NSTextField setTextColor:]` to force light when the
  field's ancestry is under the HUD (and not under a bordered
  button).

---

## Phase 10: The final responder-chain refinement

### Checkpoint 32: Only splice subclass-own event-handling VCs

*(+45m, total +10h28m, Mavericks-done checkpoint)*

Symptom: clicks during Keynote *playback* weren't advancing
slides. Editor canvas clicks still worked (Phase 3 fixed
those); playback was broken. The fix from Checkpoint 8, splice
every NSViewController into the responder chain, was *too
broad*. `KNMacAnimatedPlaybackViewController` has no event
handlers of its own, but it's now in the chain between the
hit-test view and the playback window. When the view calls
`[super mouseDown:]`, dispatch lands on the synthetic VC,
its inherited `NSResponder` default consumes it, and the
window's slide-advance handler never gets the click.

**Direct A/B against the Mavericks-native Keynote 6.2.2
confirmed it.** Same gesture, native build: click advances.
Patched build, shim ON: click eaten. Patched build, shim
*forced* off for that VC: click advances.

Fix: **gate the splice.** Only put a VC into the chain if
some class between it and `NSViewController` declares its own
`-mouseDown:` / `-keyDown:` / `-scrollWheel:` / etc.
`KNMacCanvasViewController` owns `-mouseDown:` and stays
spliced. `KNMacAnimatedPlaybackViewController` doesn't and
stays out, so clicks fall through to the window naturally
same as 6.2.2.

The walk has to stop at `NSViewController`, not `NSResponder`,
because our own `NSViewController(KPFScrollForward)` category
adds a synthetic `-scrollWheel:` forwarder that would
otherwise make every VC look like it "owns" a handler.

> **What that taught us.** The single most useful debugging
> technique in this project: **compare against the native
> version of the same app on the target OS.** Native Keynote
> 6.2.2 on Mavericks is the regression oracle. Any time a
> patched-app behavior is suspicious, the human can A/B
> against 6.2.2 and report back in seconds. See
> [[feedback-human-in-loop]] §2.

---

## Wrapping up the Mavericks tier

At the **Mavericks-done checkpoint**:

- All three iWork 2015 apps (Keynote 6.6.2, Pages 5.6.2,
  Numbers 3.6.2) launch on Mavericks 10.9.5 from Finder via
  double-click.
- Editor canvas mouse + keyboard + scroll work in all three.
- Playback works in Keynote (slide advance via click or
  keyboard).
- Export sheet is clickable.
- HUD windows have legible light text on dark fills.
- Inspector / sidebars / rulers are top-anchored correctly.
- Asset-catalog icons render via the bundled Yosemite CoreUI.
- Help → Keyboard Shortcuts doesn't crash.
- The whole flow is reproducible: `setup_iwork.sh <App>`
  takes a pristine bundle and produces a working patched
  copy.

Things still rough at this point and parked:

- Intermittent `objc_msgSend` release crash on the main queue,
  not reliably reproducible.
- Pages save sometimes warns on image-heavy documents.
- Numbers canvas has a small top inset shift in some layouts.
- iCloud sync is dead (ad-hoc resign drops the private
  entitlements; not fixable without an Apple-issued cert).

The Keynote-9 → 10.10/10.11/10.12 experiments that came
*after* this checkpoint are a different story (covered next).

---

## Part II, Pivoting to Keynote 9.1, Sierra and El Capitan

The Mavericks tier was a complete worked example. The
question that comes after "did it work for one OS gap" is
"how far does the approach generalize." The follow-up was a
push to make **Keynote 9.1 (June 2019, built against the
10.14 Mojave SDK with a 10.13 deployment target)** run on
the older releases nobody patches anymore.

The plan was to start from where the toolchain already was
and walk *outwards* in OS-version distance.

### Checkpoint 33: Kpf9 scaffolding

*(+0h27m past the Mavericks-done checkpoint; total +10h55m)*

Two new tools land before any actual patching:

- **`patch_min_version.py`** rewrites every `LC_VERSION_MIN_MACOSX`
  (and `LC_BUILD_VERSION` minos field) in a Mach-O to a target
  minimum (10.9 by default). Fixed-size load command, just a
  value change. Confirmed on
  `Keynote 9.app/Contents/MacOS/Keynote`: 10.13 → 10.9 in
  place.
- **`gen_framework_stub.py`** generates a `.framework` bundle
  whose binary satisfies the symbol surface of a 10.13
  framework. Two modes: full stub (empty ObjC classes + no-op
  functions + zero data blobs) from either a Mach-O binary
  or a `.tbd` text stub, OR `--reexport <real_path>` for
  cases where a framework was relocated between releases
  (CoreImage moved out of QuartzCore between 10.9 and 10.11).

That second tool ended up parked, the existing surgical
patcher already covers missing frameworks without per-framework
stub bundles. It stays in `tools/` for re-export edge cases.

> **What that taught us.** Build the *plumbing* (min-version
> rewriter) before the policy. Min-version rewriting is the
> first thing any back-port needs and is cheap to write once.
> The fancy framework-stub-generator was speculative
> infrastructure that turned out to be unnecessary; the
> simple plumbing was load-bearing.

### Checkpoint 34: Orchestrator + diff_imports fixes for kpf9

*(+0h07m, total +11h02m)*

Mirror `setup_iwork.sh`'s flow for the larger Keynote 9
surface area, main binary plus 13 bundled
TS/EquationKit framework binaries. Walk every Mach-O,
run min-version → diff_imports → patch_surgical on each.

Two `diff_imports.py` fixes surface immediately on this
larger bundle:

1. **Skip `@rpath/...` entries** from the dlcheck round-trip.
   dlcheck has no `@rpath` context, so every bundled framework
   came back `LIBMISSING` (false positive). Filter them; their
   symbols don't enter `missing_symbols`, and `patch_surgical`
   leaves their `LC_LOAD_DYLIB` strong.
2. **Probe every `LC_LOAD_DYLIB` target separately**, not
   just the libs that have bind entries. Frameworks like
   Vision / ClassKit / Contacts / AuthKit are linked from
   Swift code gated by `@available`, the binary has zero
   bind entries against them, so dlcheck never asked about
   them. Probe each LC anyway so the manifest correctly
   reports them missing and `patch_surgical` weakifies the
   load command.

### Checkpoint 35: Keynote 9 launches on Mavericks past static init

*(+0h41m, total +11h43m)*

End-to-end pipeline runs to completion. Keynote 9 reaches
NSApplicationMain on Mavericks. New stub work:

- **10.12+ `os_log` family** as no-ops (`_os_log_impl`,
  `_os_log_error_impl`, `_os_log_debug_impl`,
  `_os_log_fault_impl`, `os_log_type_enabled`,
  `os_log_create` returning a singleton).
- **`__NSArray0__` / `__NSDictionary0__`** (10.10 empty-
  collection sentinels) filled at `+load` time so TSCoreSOS's
  static initializer reads non-nil.
- **`KPF_TRACE_NIL_DICT`** dict-nil tracer: logs which key
  gets a nil value when
  `+[NSDictionary dictionaryWithObjects:forKeys:count:]` is
  fed nil. Hot-path; gated behind the env var.
- `patch_surgical.py` learns to inject `kpf_stubs.dylib` into
  *every* TS framework's `LC_LOAD_DYLIB` list, so dyld's
  dep-graph init order runs kpf_stubs's `+load` **before**
  TSCoreSOS et al. read symbols we provide.

### Checkpoint 36: XPC service patching + hot-swap

*(+0h15m, total +11h58m)*

The Keynote 9 bundle has four XPC services
(ArchiveUpgrader, ExternalResourceAccessor /
ExternalResourceValidator / TCMovieExtractor). Each needs the
same patching as main + TS frameworks. Each also gets its own
copy of `kpf_stubs.dylib` in `Contents/Frameworks` so its
`@executable_path` resolves the LC_LOAD_DYLIB injection
identically.

Also adds 10.11+ Security.framework `CFStringRef` constants
TSUtility imports
(`kSecAttrAccessControl`, `kSecAttrAccessGroupToken`,
`kSecUseAuthenticationContext{,UI,UISkip}`,
`kSecKeyAlgorithm{ECDSA,RSA}*`), iWork's keychain code
dereferences these without nil guards, so flat-lookup-
resolved-to-NULL crashed at first read. Initialised at
`+load` to `CFSTR` sentinels.

`scripts/hotswap_kpf9.sh`: fast iteration on `kpf_stubs.m`.
Push source, rebuild on guest, `cp` the dylib into bundle +
each XPC service's `Frameworks/`. No re-sign (per the
established Mavericks hot-swap pattern). See
[[feedback-kpf-dylib-hot-swap]].

### Checkpoint 37: 10.12 libsystem stubs

*(+0h08m, total +12h06m)*

10.12+ libSystem additions Keynote 9 imports:

- `os_unfair_lock_lock` / `unlock` / `trylock` /
  `assert_owner` / `assert_not_owner`: back the API onto
  `OSSpinLock` (Mavericks-available, identical 32-bit
  single-word semantics).
- `objc_unsafeClaimAutoreleasedReturnValue`: fall back to
  `-retainAutoreleasedReturnValue` (always present, same
  observable semantics minus the fast-path).
- `dispatch_queue_attr_make_with_autorelease_frequency`:
  return the input attr unchanged.
- `dispatch_assert_queue$V2`: no-op.

### Checkpoint 38: Type-correct mass-stub pipeline

*(+0h24m, total +12h30m)*

`classify_symbols.py` is rewritten around a `clang -E` pass
over the 10.13 SDK umbrella headers (Foundation, AppKit,
CoreFoundation, CoreGraphics, CoreText, CoreVideo,
AVFoundation, Security, LocalAuthentication, CloudKit,
IOSurface, MetalKit, compression, os.log, os.lock, dispatch).
Macros are expanded, typedef aliases (`NSAppearanceName`,
`NSPasteboardType`, `IOSurfacePropertyKey`,
`AVVideoCodecType`, `NSFontWeight`, ...) collected into a
195-entry resolution map, and each missing symbol's decl is
matched against the cleaned-up type tokens.

Apple's `swift_wrapper` typedefs
(`typedef NSString * <Alias>`) are now correctly classified as
`NSString_const` instead of `void * = NULL`. Of 302 previously-
missing symbols, classification now yields:

- `NSString_const`: 107 (was 0)
- `CFString_const`: 6
- `CGFloat`: 5
- `NSEdgeInsets`: 1
- `function`: 37
- `objc_class`: 114
- `unknown`: 0 (was 53)

`dlcheck.c` falls back to `RTLD_DEFAULT` when the recorded
library path doesn't exist on Mavericks (CoreImage.framework
moved into QuartzCore on 10.9, etc.) and probes
`objc_getClass()` for `OBJC_CLASS_$_X` symbols. Drops 19 false
positives, CIImage/CIVector/CIColor and the kCI* constants
all resolve via the existing QuartzCore subframework.

> **What that taught us.** When the symbol set jumps from
> tens to hundreds, hand-classification doesn't scale. Build
> the SDK-preprocessor pipeline once and let it carry the
> long tail. The 195-entry typedef resolution map is the kind
> of one-time investment that pays back across every future
> tier.

### Checkpoint 39: Expand os_log_t singleton storage

*(+0h05m, total +12h35m)*

iWork's static initializers store the result of
`os_log_create()` in strong slots and the protobuf descriptor
pool. A plain `[NSObject alloc] init` is 16 bytes, any
out-of-bounds read/write inside Apple's bigger real
`struct os_log_s` walks straight into the next allocation's
malloc metadata. Define a `KPFOSLog` class with a 256-byte
slab ivar.

Precautionary, but **introduces a new bug** described in the
next checkpoint.

### Checkpoint 40: Immortal os_log_t via runtime IMP swap (no slab)

*(+0h09m, total +12h44m)*

The 256-byte `_slab[256]` ivar on `KPFOSLog` was *itself* the
heap-corruption source. Most likely an ARC ivar-layout
mis-encoding for an oversized `char[256]` inside an ObjC
root class, walked by the runtime during retain/release/
dealloc traffic.

Remove the slab. Switch to a plain
`@interface KPFOSLog : NSObject @end` and install no-op
`retain` / `release` / `autorelease` / `retainCount` IMPs at
`__attribute__((constructor))` time via
`class_replaceMethod` + `sel_registerName` (working around
ARC's ban on direct `@implementation` overrides of these
selectors).

iWork's TS frameworks store the `os_log_create()` result in
many strong slots with very imbalanced retain/release
traffic; the **immortal IMPs make the singleton survive
arbitrarily many releases** without needing a custom
storage shape that ARC might mis-handle.

Captured as [[arc-ivar-layout-slab-pitfall]] for future
reference.

> **What that taught us.** Two things. First: when a fix
> introduces a worse bug, *the fix itself is the suspect*.
> The slab was added "just in case" and turned out to be the
> actual cause of the corruption it was meant to prevent.
> Second: the immortal-singleton pattern (no-op
> retain/release/autorelease) is a clean answer to "this
> object can't safely be deallocated because callers have
> imbalanced traffic." Use it for any process-wide singleton
> the patched binary will hand around.

### Checkpoint 41: Keynote 9.1 launches on macOS 10.12 Sierra

*(+0h36m, total +13h20m)*

The strategic pivot. Rather than continue grinding on the
larger Keynote-9 → Mavericks delta (302 missing symbols, deep
heap-corruption issues), **target 10.12 first**, much
smaller delta (26 unique missing symbols across the entire
bundle), and bisect downward only if 10.12 works cleanly.

New per-tier file shape:

- `stubs/kpf_stubs_1012.m` (now `kpf_stubs_keynote9_10_12.m`)
- `stubs/manual_symbols_1012.txt`
- `scripts/setup_keynote9_1012.sh` (host wrapper)
- `scripts/_kpf9_1012_guest_orchestrator.sh` (guest patcher)

Tool changes shared between tiers:

- **`dlcheck.c`** emits a per-unique-lib
  `LIBSTATUS opened|failed` line *before* the per-symbol
  results, so the consumer can identify libs whose recorded
  path doesn't open on the target independent of symbol-level
  resolution.
- **`diff_imports.py`** treats `LIBSTATUS` as authoritative
  for which `LC_LOAD_DYLIB`s need flipping to weak. Fixes a
  false-negative where `dlopen`'ing one lib transitively
  loaded another (e.g. MetalKit pulled in
  MetalPerformanceShaders at probe time), making symbols
  resolve via `RTLD_DEFAULT` and the host lib silently miss
  the weaken list. dyld at launch doesn't have that side
  effect, so the bundle would fail to load.
- **`gen_stubs.py`** emits only Foundation + CoreFoundation +
  CoreGraphics imports (not AppKit umbrella) to avoid
  redeclaration conflicts between our
  `NSString *const X` stubs and the SDK's
  `NSPasteboardName const X` typedef'd form.

Hand-shims for 10.12:

- `_os_log_error_impl` + `_os_log_fault_impl` (10.13+
  variants; 10.12 has only `_os_log_impl`).
- **CloudKit entitlement bypass** via
  `method_setImplementation` on
  `-[CKContainer _checkSelfContainerIdentifier]`, ad-hoc
  resign strips iCloud entitlements; Apple's amfid rejects
  an ad-hoc binary that tries to keep them.

> **What that taught us.** *Tier-based development*. Instead
> of one big "make it work on the oldest target", do one tier
> at a time, with verbatim seed commits between tiers (see
> [[feedback-human-in-loop]] §4). Each tier is a checkpoint
> the next tier can diff against. The 10.12 → 10.11 jump,
> below, is comparatively small because of this discipline.

### Checkpoint 42: Hand-stub the 10.13 → 10.12 deltas

*(+0h22m, total +13h42m)*

Categories on system classes for the 10.13 → 10.12 method
deltas iWork exercises during app/document launch:

- **`CKContainer +containerWithIdentifier:`** → nil at
  runtime via `class_replaceMethod`. (Replaces the earlier
  `_checkSelfContainerIdentifier` swizzle which didn't take
  effect, CKContainer is a class cluster on 10.12 and the
  swizzle on the public class doesn't intercept the private
  subclass's override.) iWork tolerates a nil container.
- **`NSFileManager
  -getFileProviderServicesForItemAtURL:completionHandler:`**:
  invokes the completion handler with `@{}, nil` (no
  providers).
- **`NSProgress`**: `setFileOperationKind:` /
  `fileOperationKind`, `setFileTotalCount:` /
  `fileTotalCount`, `setFileCompletedCount:` /
  `fileCompletedCount`, `setFileURL:` / `fileURL`. No-op
  setters + nil getters.
- **`NSKeyedArchiver` / `NSKeyedUnarchiver`**:
  `+archivedDataWithRootObject:requiringSecureCoding:error:`,
  `+unarchivedObjectOfClass:fromData:error:`,
  `+unarchivedObjectOfClasses:fromData:error:`. Forwarded to
  the legacy 10.12 API.
- **`NSColor +colorNamed:` / `+colorNamed:bundle:`** returns
  `controlTextColor`, *not nil*, because iWork passes the
  result directly into a font-attribute dict that rejects
  nil values via
  `+[NSDictionary dictionaryWithObjects:forKeys:count:]`.
  Diagnosed via the `KPF_TRACE_NIL_DICT` tracer.
- **`NSWindow -tabGroup` / `-tab` / `-tabbedWindows`**:
  return nil.
- **`NSSegmentedControl setSegmentDistribution:` /
  `segmentDistribution`**: no-op setter, 0 getter.

`hotswap_kpf9_1012.sh` for fast iteration.

### Checkpoint 43: Named-color asset map

*(+0h05m, total +13h47m)*

`+[NSColor colorNamed:]` used to return a hardcoded
`controlTextColor` fallback that looked wrong in the toolbar
/ content window / split view. Replace with a static
`name → NSColor` lookup keyed off iWork's real asset names.
First four entries (collected by interactive runtime tracing):

- `tma_content_window_background_color` → `windowBackgroundColor`
- `tma_toolbar_item_content_dimmed` → `tertiaryLabelColor`
- `tma_document_split_view_divider_color` → `gridColor`
- `sf_mac_tb_collaboration_content_color` →
  `keyboardFocusIndicatorColor`

Unmapped names fall back to `controlTextColor` and log to
stderr (gated on `KPF_LOG_COLOR_NAMED=1`) so the map can be
extended by clicking through new UI surfaces. **Good 10.12
checkpoint:** Keynote 9.1 launches, main window + toolbar +
split view render with sane colors. Next stop: 10.11.

### Checkpoint 44: Keynote 9.1 launches on macOS 10.11 El Capitan

*(+1h03m, total +14h50m)*

The 10.11 tier. Starts from the 10.12 work as base (per the
tier-based plan) and adds the 10.12-introduced surface that
10.11 lacks.

Bundled `libswift*.dylib` files are now also processed by
`patch_surgical`, on 10.11 their direct bind to
`_os_log_type_enabled` in libSystem fails because that symbol
is 10.12+. `patch_surgical` flips it to flat lookup which
`kpf_stubs.dylib` answers.

10.12 libsystem hand-stubs:

- `_os_log_impl` no-op, `_os_log_type_enabled` returns NO.
- `_os_log_create` immortal singleton (IMPs via
  `class_replaceMethod`; **void\*-typed** to dodge ARC
  auto-retain on the retain IMP itself, which would otherwise
  infinite-recurse).
- `_os_log_default` 64-byte writable slab.
- `_os_unfair_lock_*` backed by `OSSpinLock`.
- `_dispatch_queue_attr_make_with_autorelease_frequency`,
  `_dispatch_assert_queue_barrier`, `_dispatch_assert_queue$V2`,
  `_dispatch_assert_queue_not$V2`,
  `_os_activity_label_useraction`.

10.12 AppKit additions:

- `NSWindow -setTabbingMode:` / `tabbingMode`,
  `-setTabbingIdentifier:` / `tabbingIdentifier`,
  `+allowsAutomaticWindowTabbing` /
  `+setAllowsAutomaticWindowTabbing:`,
  `+userTabbingPreference`, `-addTabbedWindow:ordered:`,
  `-moveTabToNewWindow:`, `-mergeAllWindows:`,
  `-toggleTabBar:`.
- `NSDocument -isBrowsingVersions` / `-browseVersions:` /
  `-stopBrowsingVersionsWithCompletionHandler:`.
- `NSResponder -setTouchBar:` / `-touchBar` / `-makeTouchBar`
  (10.12.2).
- `NSSpellChecker +isAutomatic{Capitalization,Dash,Period,Quote,
  SpellingCorrection,TextCompletion,TextReplacement}Enabled`.

10.13 additions iWork imports unconditionally:

- `MPSSupportsMTLDevice` → NO.
- `CGColorSpaceCopyICCData` → NULL.
- `CGColorSpaceIsWideGamutRGB` → NO.
- `CGColorConversionInfoCreate` → NULL.
- `SecKeyCreateEncryptedData`, `SecKeyCreateDecryptedData`,
  `SecKeyCreateSignature`, `SecKeyIsAlgorithmSupported` → all
  NULL/NO.
- `-[<MTLDevice> isRemovable]` → NO (eGPU, 10.13+).

### Checkpoint 45: LabelWithString autoresizing + color-named logger

*(+0h06m, total +14h56m)*

Two fixes:

1. `+[NSTextField labelWithString:]` now sets
   `translatesAutoresizingMaskIntoConstraints = NO` before
   returning. Without it iWork's Auto Layout setup
   downstream raises *"Setting autoresizing constraints when
   autoresizing is off"*, Apple's real 10.12 convenience
   constructors all return Auto Layout-ready views.
2. The unmapped-named-color logger is now always on with
   per-name de-dup so each unmapped name only appears once
   per process. Lets us collect a complete list of names by
   clicking through the app and extending the central color
   map in one pass.

### Checkpoint 46: NSGridView/Row/Cell + Touch Bar inert stubs

*(+0h22m, total +15h18m)*

The big shim batch needed at first-window load on 10.11:

- **Touch Bar family** (`NSTouchBar`, `NSTouchBarItem`,
  `NSCustomTouchBarItem`, `NSGroupTouchBarItem`,
  `NSColorPickerTouchBarItem`,
  `NSCandidateListTouchBarItem`,
  `NSPopoverTouchBarItem`) and **NSScrubber family**
  (`NSScrubber`, `NSScrubberItemView`,
  `NSScrubberTextItemView`, `NSScrubberLayout`,
  `NSScrubberLayoutAttributes`, `NSScrubberFlowLayout`,
  `NSScrubberSelectionStyle`) all subclass a new
  **`KPFInertObject` base** that:
  - `-init` / `-initWithCoder:` return `self` so nib decoding
    succeeds.
  - `-forwardInvocation:` zero-fills the return value,
    swallowing every other selector silently. 10.11 has no
    Touch Bar runtime, the resulting objects should do
    nothing.
- **`NSGridView`** (real `NSView` subclass), `NSGridRow` /
  `NSGridColumn` / `NSGridCell` (real `NSObject` subclasses).
  `NSGridView -initWithCoder:` decodes the rows/columns/cells
  from the nib, wires backreferences, and builds an internal
  `NSStackView`-of-`NSStackView`s (vertical rows → horizontal
  cells) so the Preferences window's GridView-laid-out
  content actually appears.

Also adds:

- A `-setTranslatesAutoresizingMaskIntoConstraints:` swizzle
  that wraps the original in `@try/@catch` and swallows the
  10.11-only assertion. Earlier attempt at no-oping the
  private `_setAutoresizingConstraints:` directly broke
  whole-app layout; this try/catch leaves the install path
  intact except for the spurious assertion.
- `NSArray` nil tracer (parallel to the `NSDictionary` one),
  gated by `KPF_TRACE_NIL_ARRAY=1`.

> **What that taught us.** The `KPFInertObject` pattern
> `-init` succeeds, `-forwardInvocation:` zero-fills the
> return, is the right shape for "this whole class family
> doesn't exist on the target OS but the binary will instantiate
> instances and message them." It's much less work than
> shimming each method.

### Checkpoint 47: KPFInertObject -forwardInvocation: fix

*(+0h08m, total +15h26m)*

Subtle ABI bug. `setReturnValue:` against an `NSInvocation`
whose method signature came from our generic `"v@:"` fallback
crashed inside `NSInvocation`'s `__NSI0` when the caller had
pushed more args than our signature claimed. The invocation's
return slot is already zero-initialized by `NSInvocation`, so
the explicit `setReturnValue:` was redundant and harmful.
Leaving the slot at its default zero state gives `nil`-for-id
/ 0-for-primitive returns the same way the explicit call
would have, without the ABI mismatch when iWork sends an
unknown selector to a Touch Bar / Scrubber inert class.

This is the El Capitan "mostly functional" checkpoint.
Keynote 9.1 launches, presents the template chooser, opens
documents, and edits in steady state. Known remaining gaps:
asset-catalog images render rough,
`NSCollectionView` nil-supplementary-view edge case, and a
few sparse `NSGridView` methods iWork doesn't actually call
but might. The 10.10 attempt is a different story, the
static-init heap canary there turned out to be real and parked
the tier; see `memory/project_kpf9_1010_state.md`.

---

## Patterns to internalize

If you take only a handful of patterns out of this:

1. **Sledgehammer first to prove the shape; scalpel second to
   make it production-quality.** `weaken_dylibs.py` got us
   loading; `patch_surgical.py` got us shippable. Don't skip
   the sledgehammer, it's how you find out the scalpel is
   even possible.
2. **The previous OS version of the same app is the regression
   oracle.** Native Keynote 6.2.2 saved hours of speculation in
   the responder-chain bug. Whenever you're unsure if a
   behavior is "weird" or "always was that way," ask the human
   to A/B against the native build.
3. **Read `otool -ov` and `nm -m` on the target OS's framework
   to get the real method signatures.** Empty stubs satisfy
   the linker; real stubs satisfy the running app.
   `NSPressureConfiguration` got its method list from
   `otool -ov` on Yosemite's AppKit; that's how the
   Force-Touch crash went away.
4. **Drop in the newer version of the framework when you can.**
   Yosemite CoreUI substitutes cleanly because the install_name
   matches. This is the OCLP playbook for AppKit/Foundation
   compatibility, and it's almost always less work than
   stubbing the diff.
5. **Add tracers in the same commit that uses them, env-gate
   them so they're off in production, leave them in the tree.**
   `KPF_TRACE_EVENTS` / `KPF_TRACE_CONSTRAINTS` / the
   `Ctrl-Opt-Cmd-D` view dump each paid for themselves
   immediately and are still in the dylib for future use.
6. **`class_addMethod`, not `method_setImplementation`, when
   the target class inherits the method.** Otherwise you
   silently replace the parent class's IMP for every other
   subclass. See [[objc-swizzle-subclass]] for the canonical
   write-up.
7. **`@try`/`@catch` around `-constant` reads on NIB-loaded
   constraints.** Symbolic constants raise on 10.9. Don't let
   your defensive walk crash the app.
8. **Treat ABI in shimmed methods.** Struct returns ≥ 16 bytes
   use `_stret` in callers that declare the right type and
   plain `objc_msgSend` in callers that don't. Inconsistency
   here means `release` crashes much later. Prefer void-return
   shims when you have a choice.
9. **One observer beats five overlapping triggers.** The
   chrome-inset fix consolidating from five hooks to one
   `NSWindowDidUpdate` observer shrank the code by ~150 lines
   and made the path easier to reason about. If you find
   yourself adding a "third place where we also need to fix
   this", step back and find the one event that fires after
   *every* relevant state change.

Read [[feedback-human-in-loop]] next for the patterns abstracted
over the *collaboration*, not just the code.
