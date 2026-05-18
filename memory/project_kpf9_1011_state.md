---
name: kpf9-1011-state
description: "Keynote 9 on macOS 10.11 El Capitan is mostly functional via the tiered KPF9 port. Launches, main window/canvas/inspector work, you can interact with the UI. Three known remaining issues parked for future iteration."
metadata:
  node_type: memory
  type: project
---

State as of 2026-05-18: Keynote 9.1 launches and is broadly usable on 10.11.6 El Capitan via `scripts/setup_keynote9_1011.sh <user>@<mav-host>` + iteration via `scripts/hotswap_kpf9_1011.sh`. User confirmed "mostly functional".

**Shim surface (stubs/kpf_stubs_1011.m + auto-stubs):**

10.12 libsystem (10.11 has none of these): `_os_log_impl`, `_os_log_error_impl`, `_os_log_fault_impl`, `os_log_type_enabled`, `os_log_create` (immortal `KPFOSLog` singleton with retain/release replaced via `class_replaceMethod` -- IMPs declared with `void *` to dodge ARC auto-retain on the retain IMP itself), `_os_log_default` (64-byte writable slab), `os_unfair_lock_*` (backed by OSSpinLock), `dispatch_queue_attr_make_with_autorelease_frequency`, `dispatch_assert_queue_barrier`, `dispatch_assert_queue$V2`, `dispatch_assert_queue_not$V2`, `_os_activity_label_useraction`.

10.12 AppKit:
- `+containerWithIdentifier:` swizzled to return nil (CloudKit entitlement bypass; ad-hoc resign can't carry private com.apple.* entitlements).
- `NSFileManager -getFileProviderServicesForItemAtURL:completionHandler:` (calls handler with `@{}, nil`).
- `NSProgress -setFileOperationKind:/-fileOperationKind/-setFileTotalCount:/-fileTotalCount/-setFileCompletedCount:/-fileCompletedCount/-setFileURL:/-fileURL`.
- `NSKeyedArchiver +archivedDataWithRootObject:requiringSecureCoding:error:` (forwarded to legacy NSKeyedArchiver) + the `NSKeyedUnarchiver +unarchivedObjectOf{Class,Classes}:fromData:error:` family.
- `+[NSColor colorNamed:]/colorNamed:bundle:` resolves through `kpf_resolveNamedColor` which is a dict mapping iWork's `tma_*` / `sf_*` asset-catalog color names to 10.11 system colors (4 mappings so far) and falls back to `controlTextColor` (NOT nil, because iWork's callers put the result into NSDictionary literal arrays that reject nil). Unmapped names get logged-once via `NSLog` so the central map can be extended without an env var.
- `-[NSColor type]` returns `NSColorTypeComponentBased`.
- `NSWindow tab APIs`: `-tabGroup/-tab/-tabbedWindows/-setTabbingMode:/-tabbingMode/-setTabbingIdentifier:/-tabbingIdentifier/-addTabbedWindow:ordered:/-moveTabToNewWindow:/-mergeAllWindows:/-toggleTabBar:` + class methods `+allowsAutomaticWindowTabbing/+setAllowsAutomaticWindowTabbing:/+userTabbingPreference`.
- `NSDocument -isBrowsingVersions/-browseVersions:/-stopBrowsingVersionsWithCompletionHandler:`.
- `NSResponder -setTouchBar:/-touchBar/-makeTouchBar` (10.12.2+).
- `NSSpellChecker` 10.12 class properties (all return NO).
- `+[NSTextField labelWithString:/wrappingLabelWithString:/labelWithAttributedString:/textFieldWithString:]` -- set `translatesAutoresizingMaskIntoConstraints = NO` to match Apple's 10.12 default; iWork's Auto Layout setup downstream relies on this.
- `NSSegmentedControl -setSegmentDistribution:/-segmentDistribution`.
- `-[NSObject isRemovable]` returns NO (10.13 MTLDevice eGPU probe; broad NSObject category since concrete MTLDevice subclasses are private).

10.12 Touch Bar / Scrubber classes (all 14): subclasses of `KPFInertObject`, a tiny base that decodes from nib (`-initWithCoder:` returns `[super init]`), reports `-respondsToSelector:` YES for everything, and **`-forwardInvocation:` is a true no-op that does NOT call `setReturnValue:`**. Calling `setReturnValue:` against an invocation whose method signature came from our generic `"v@:"` fallback crashed inside NSInvocation's `__NSI0` when the caller had pushed more args than our signature claimed. Leaving the invocation's return slot at its default zero state gives `nil`/`0` returns just like `setReturnValue:` would have, without the ABI mismatch.

10.12 NSGridView / NSGridRow / NSGridColumn / NSGridCell: hand-implemented as real classes. NSGridView is an NSView subclass; `initWithCoder:` decodes rows/columns/cells, wires gridView/row/column backreferences, and builds an NSStackView-of-NSStackViews so the Preferences window's GridView-laid-out content actually appears. Hidden / size / placement properties use `getter=isHidden` so KVC works.

10.13 additions also needed on 10.11: `MPSSupportsMTLDevice` -> NO, `CGColorSpaceCopyICCData/CGColorSpaceIsWideGamutRGB/CGColorConversionInfoCreate` -> NULL/NO/NULL, `SecKeyCreate{Encrypted,Decrypted,}Data/SecKeyCreateSignature/SecKeyIsAlgorithmSupported` -> NULL/NO.

Two assertion-suppression swizzles:
- `-setTranslatesAutoresizingMaskIntoConstraints:` wrapped in `@try/@catch` so the 10.11-only "Setting autoresizing constraints when autoresizing is off" assertion (silently tolerated on 10.12+) is swallowed.
- The earlier attempt at no-oping the private `_setAutoresizingConstraints:` directly broke whole-app layout; the try/catch path is correct.

**Tooling extensions specific to 10.11:**

- `scripts/_kpf9_1011_guest_orchestrator.sh` enumerates `Contents/Frameworks/libswift*.dylib` in addition to the iWork frameworks/XPCs, because bundled libswift dylibs directly bind to 10.12 libSystem symbols (`_os_log_type_enabled` etc.) that need flat-lookup redirect to our kpf_stubs.dylib.
- `KPF_TRACE_NIL_ARRAY=1` parallels `KPF_TRACE_NIL_DICT=1` in `kpf_stubs_1011.m` -- swizzles `+[NSArray arrayWithObjects:count:]` to log call sites that pass nil at index 0. Was how we found that `+[NSColor colorNamed:]` returning nil landed in a font-attribute dictionary.

**Known remaining issues (parked):**

1. **Asset-catalog images may fail.** 10.11's CoreUI is v366.1.0 and may not understand the 10.12-era asset-catalog format Apple compiled iWork's resources with. Side-loading Sierra's CoreUI via `DYLD_FRAMEWORK_PATH` was investigated -- the framework path mechanism works fine, but Sierra CoreUI's transitive deps (TextureIO -> libate.dylib -> ~20 libSystem `$UNIX2003` aliases + several 10.12 CG constants) total roughly 60 new shims. Parked until we identify which specific assets render wrong. See [[kpf9-sierra-coreui-sideload]].

2. **NSCollectionView nil-supplementary-view crash.** Reproduced at 2026-05-18 00:52 when interacting with a collection view (probably effects chooser or template strip). The data source returns nil from `-collectionView:viewForSupplementaryElementOfKind:atIndexPath:`, and `-[_NSCollectionViewCore _createPreparedSupplementaryViewForElementOfKind:...]` calls `-[NSView addSubview:positioned:relativeTo:]` with that nil, triggering `*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil`. Likely root cause: iWork registered a 10.12+ supplementary-view class with the collection view (via `registerClass:forSupplementaryViewOfKind:withIdentifier:`) and that registration isn't actually producing instances on 10.11. Possible fixes: swizzle `-[NSCollectionView dequeueReusableSupplementaryViewOfKind:withIdentifier:forIndexPath:]` to return a default-constructed NSView when our stub class would otherwise return nil, OR fix the underlying 10.12 collection-view-registration shim.

3. **NSGridView "real" implementation is shallow.** Decodes rows/columns/cells from nibs and lays them out via internal NSStackViews, so the Preferences window renders. But the API surface iWork actually queries beyond `cellForView:/numberOfRows/numberOfColumns/rowAtIndex:/columnAtIndex:/cellAtColumnIndex:rowIndex:` may surface more crashes. Each new selector will be a small targeted fix via `scripts/hotswap_kpf9_1011.sh` (~5s round-trip).

**Iteration cheatsheet:**

- `scripts/setup_keynote9_1011.sh` -- full pipeline (host wrapper). Pulls per-binary diff_imports manifests, classifies against 10.13 SDK via `/Volumes/HighSierra`'s Xcode, regenerates auto_stubs, builds dylib, runs guest orchestrator (patches all 18 binaries, drops kpf_stubs into Frameworks + each XPC service, edits Info.plist LSMinimumSystemVersion to 10.11.0, ad-hoc resigns).
- `scripts/hotswap_kpf9_1011.sh` -- pushes `stubs/kpf_stubs_1011.m`, rebuilds the dylib on the guest, copies it into bundle + 4 XPC services. No resign.
- `~/Keynote9.app/Contents/MacOS/Keynote > /tmp/k9.out 2>&1 &` -- direct exec with captured stderr. `KPF_TRACE_NIL_DICT=1` / `KPF_TRACE_NIL_ARRAY=1` are the most useful diagnostics; `KPF_LOG_COLOR_NAMED` is no longer needed (always-on, de-duped).

See related: [[kpf9-tiered-os-strategy]] for the broader plan, [[kpf9-mass-stub-pipeline]] for how the classifier works, [[kpf9-sierra-coreui-sideload]] for the parked asset-catalog investigation, [[kpf9-init-order]] for per-framework kpf_stubs injection (not used on 10.11 but the principle applies), [[arc-ivar-layout-slab-pitfall]] for the ivar-slab footgun we hit on the 10.9 attempt.
