// kpf_stubs_keynote9_10_10.m -- the 10.13 -> 10.10 hand-stub surface for
// Keynote 9. This file is the 10.10-specific complement of
// stubs/kpf_stubs_iwork2015_10_9.m (which targets 10.9 Mavericks).
//
// Everything else iWork imports from 10.13 (NSString constants, ObjC
// class symbols, CFStringRef constants, ...) is handled by the
// auto-generated stubs/kpf_auto_stubs.m via tools/gen_stubs.py.
//
// Hand-stubs needed for 10.12:
//   _os_log_error_impl  10.13+ variant of os_log_impl. 10.12 has the
//                       base _os_log_impl but not the error/fault
//                       variants. No-op (matches what we did for 10.9).
//   _os_log_fault_impl  Same story.
//
// Everything else (__NSArray0__/__NSDictionary0__, os_unfair_lock,
// kSec*, os_log_create, os_log_default, MPSSupportsMTLDevice, dispatch
// additions, NSAppearance shims, NSVisualEffectView etc.) is native
// on 10.12 and does NOT need a shim.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// Malloc corruption-abort bypass (proof-of-concept research toggle).
//
// 10.10's szone_error (libsystem_malloc) aborts when it sees a bad free-list
// checksum, and on 64-bit the abort flag is force-set at zone creation and
// the `MallocCorruptionAbort=0` env var path is compiled out (see Apple's
// libmalloc-53.30.1 src/malloc.c:604).  Keynote 9's main __mod_init triggers
// `incorrect checksum for freed object` somewhere in its protobuf descriptor
// registration.  This bypass overwrites abort()'s first byte with `ret` so
// szone_error falls through and tiny_malloc_from_free_list keeps going.
//
// Outcome (2026-05-17): the corruption is REAL, not a spurious canary --
// after the bypass, tiny_malloc continues with NULL/garbage from the bad
// free-list checksum chain and SIGSEGVs one frame deeper (jumping to a
// bogus address inside the malloc internals).  Kept as opt-in research
// toggle for future runs where we want to see "where would it die next".
//
// Enable via env: KPF_BYPASS_MALLOC_ABORT=1  (default: off).
#define KPF_SMALLOC_ABORT_ON_ERROR     (1u << 4)    // 0x10
#define KPF_SMALLOC_ABORT_ON_CORRUPT   (1u << 6)    // 0x40

// Earlier attempt: walk all zones and clear `debug_flags` at offset 4104
// (per libmalloc-53.30.1 src/magazine_malloc.c:638).  Production 10.10.5
// szone_t layout differs from the open-source release (cpu_id_key at +4096
// is observed as 0xffffffffffffffff, not zero), and the admin region is
// only 4K, so a broader scan walks off into adjacent r-x __TEXT pages and
// SEGVs.  Easier and more reliable to patch abort() directly (below).

// Big hammer: replace the first byte of abort() with `ret` (0xC3) so that
// any caller (including szone_error inside libsystem_malloc) survives the
// call instead of dying.  This is intentionally broad -- it's a research
// PoC to see how far Keynote 9 can get if we stop trusting the libmalloc
// heap canary.  Side effects: every other abort() call in the process
// (assertion failures, __chk_fail, etc.) now silently returns; the
// program may then take SIGILL on `ud2` instructions clang emits after
// noreturn calls.  If that happens we'll iterate.
static void kpf_patch_abort_to_ret(void) {
    void *p = dlsym(RTLD_DEFAULT, "abort");
    if (!p) { fprintf(stderr, "[kpf] abort symbol not found\n"); return; }
    uintptr_t page = (uintptr_t)p & ~(uintptr_t)4095;
    if (mprotect((void *)page, 4096, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        fprintf(stderr, "[kpf] mprotect(abort page) RW failed\n");
        return;
    }
    uint8_t before = *(uint8_t *)p;
    *(volatile uint8_t *)p = 0xC3;       // ret
    if (mprotect((void *)page, 4096, PROT_READ | PROT_EXEC) != 0) {
        fprintf(stderr, "[kpf] mprotect(abort page) RX failed (cont.)\n");
    }
    fprintf(stderr, "[kpf] patched abort @ %p (0x%02x -> 0xC3)\n", p, before);
}

__attribute__((constructor(101)))
static void kpf_malloc_abort_bypass(void) {
    if (!getenv("KPF_BYPASS_MALLOC_ABORT")) return;
    fprintf(stderr, "[kpf] KPF_BYPASS_MALLOC_ABORT=1: disarming malloc heap canaries\n");

    // 1) Clear the global so any zone created *after* this point doesn't
    //    inherit the abort bit.
    unsigned *gflags = (unsigned *)dlsym(RTLD_DEFAULT, "malloc_debug_flags");
    if (gflags) {
        unsigned before = *gflags;
        *gflags &= ~(KPF_SMALLOC_ABORT_ON_CORRUPT | KPF_SMALLOC_ABORT_ON_ERROR);
        fprintf(stderr, "[kpf] malloc_debug_flags 0x%x -> 0x%x\n", before, *gflags);
    } else {
        fprintf(stderr, "[kpf] malloc_debug_flags symbol not found\n");
    }

    // 2) Turn abort() into a no-op so the free-list-checksum path (and any
    //    other abort call) survives.
    kpf_patch_abort_to_ret();
}


// +[NSColor colorNamed:] / colorNamed:bundle: (10.13+ named color
// assets). 10.12 AppKit has no named-color asset lookup; the documented
// 10.13 behavior is "returns nil if no asset matches", which iWork's
// NIB-decode path tolerates.
@interface NSColor (KPF1012)
+ (NSColor *)colorNamed:(NSString *)name;
+ (NSColor *)colorNamed:(NSString *)name bundle:(NSBundle *)bundle;
@end
// NSWindow tab APIs. 10.12 introduced tabbingMode/tabbingIdentifier/
// +allowsAutomaticWindowTabbing; 10.13 added tab/tabGroup/tabbedWindows.
// 10.11 has none of them. Stub the whole family.
@interface NSWindow (KPF1011)
- (id)tabGroup;
- (id)tab;
- (NSArray *)tabbedWindows;
- (void)setTabbingMode:(NSInteger)mode;
- (NSInteger)tabbingMode;
- (void)setTabbingIdentifier:(NSString *)ident;
- (NSString *)tabbingIdentifier;
- (void)addTabbedWindow:(NSWindow *)win ordered:(NSInteger)place;
- (void)moveTabToNewWindow:(id)sender;
- (void)mergeAllWindows:(id)sender;
- (void)toggleTabBar:(id)sender;
@end
@implementation NSWindow (KPF1011)
- (id)tabGroup       { return nil; }
- (id)tab            { return nil; }
- (NSArray *)tabbedWindows { return nil; }
- (void)setTabbingMode:(NSInteger)mode { (void)mode; }
- (NSInteger)tabbingMode { return 2; /* NSWindowTabbingModeDisallowed */ }
- (void)setTabbingIdentifier:(NSString *)ident { (void)ident; }
- (NSString *)tabbingIdentifier { return @""; }
- (void)addTabbedWindow:(NSWindow *)win ordered:(NSInteger)place {
    (void)win; (void)place;
}
- (void)moveTabToNewWindow:(id)sender { (void)sender; }
- (void)mergeAllWindows:(id)sender    { (void)sender; }
- (void)toggleTabBar:(id)sender       { (void)sender; }
@end

// 10.12 NSWindow class-level tabbing prefs.
@interface NSWindow (KPF1011Class)
@end
@implementation NSWindow (KPF1011Class)
+ (BOOL)allowsAutomaticWindowTabbing       { return NO; }
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)b { (void)b; }
+ (NSInteger)userTabbingPreference         { return 0; /* manual */ }
@end

// MTLDevice -isRemovable (10.13+ eGPU detection). 10.11 Metal devices
// are all integrated/discrete (never removable). Add the selector via
// a NSObject category so any concrete (private) MTLDevice subclass
// answers NO. This is broad but safe -- no other class names a method
// `isRemovable` with this signature.
@interface NSObject (KPF1011_MTLDevice)
- (BOOL)isRemovable;
@end
@implementation NSObject (KPF1011_MTLDevice)
- (BOOL)isRemovable { return NO; }
@end

// NSTextField convenience constructors (10.12+). iWork's view-controller
// nibs call +labelWithString: to build inspector labels; 10.11 doesn't
// have these factories. Return a real configured NSTextField so the
// caller's subsequent setTranslatesAutoresizingMaskIntoConstraints: /
// addConstraint: / attribute-set calls all land on a valid object.
@interface NSTextField (KPF1011)
+ (instancetype)labelWithString:(NSString *)stringValue;
+ (instancetype)wrappingLabelWithString:(NSString *)stringValue;
+ (instancetype)labelWithAttributedString:(NSAttributedString *)attr;
+ (instancetype)textFieldWithString:(NSString *)stringValue;
@end
@implementation NSTextField (KPF1011)
+ (instancetype)labelWithString:(NSString *)stringValue {
    NSTextField *f = [[self alloc] init];
    // Match Apple's 10.12 behavior: convenience constructors return
    // Auto Layout-ready views (translatesAutoresizingMaskIntoConstraints
    // = NO). Without this flag, iWork's Auto Layout setup downstream
    // raises NSAssertionHandler "Setting autoresizing constraints when
    // autoresizing is off".
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.stringValue = stringValue ?: @"";
    f.editable = NO;
    f.bordered = NO;
    f.drawsBackground = NO;
    f.selectable = YES;
    [f.cell setLineBreakMode:NSLineBreakByTruncatingTail];
    return f;
}
+ (instancetype)wrappingLabelWithString:(NSString *)stringValue {
    NSTextField *f = [self labelWithString:stringValue];
    [f.cell setLineBreakMode:NSLineBreakByWordWrapping];
    f.selectable = YES;
    return f;
}
+ (instancetype)labelWithAttributedString:(NSAttributedString *)attr {
    NSTextField *f = [self labelWithString:@""];
    f.attributedStringValue = attr ?: [[NSAttributedString alloc] initWithString:@""];
    return f;
}
+ (instancetype)textFieldWithString:(NSString *)stringValue {
    NSTextField *f = [[self alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.stringValue = stringValue ?: @"";
    return f;
}
@end

// NSSpellChecker text-substitution class properties: present on 10.10
// natively (the 10.10 SDK declares +isAutomatic{Capitalization,Dash,Period,
// Quote,SpellingCorrection,TextReplacement}Enabled and the IsAutomatic*
// runtime accessors). The 10.11 tier stubbed them for missing-on-10.11
// names; on 10.10 we let the real Apple impl answer.

// 10.11 AppKit raises an NSAssertionHandler exception "Setting
// autoresizing constraints when autoresizing is off" inside
// -[NSView _setAutoresizingConstraints:] for a state combo that 10.12+
// silently tolerates. iWork's nib/view-controller load path hits the
// bad combo and the uncaught exception kills the app.
//
// We can't no-op the private method (autoresizing-mask constraints ARE
// needed for some views -- skipping them entirely breaks the whole-app
// layout). Instead, wrap setTranslatesAutoresizingMaskIntoConstraints:
// with a try/catch that calls the original but swallows the specific
// assertion exception, leaving everything else intact.
static void (*kpf_orig_setTranslatesAuto)(id, SEL, BOOL) = NULL;
static void kpf_setTranslatesAuto(id self, SEL _cmd, BOOL value) {
    @try {
        kpf_orig_setTranslatesAuto(self, _cmd, value);
    } @catch (NSException *exc) {
        if (![exc.reason containsString:@"autoresizing"]) {
            @throw;
        }
        // Swallow: the autoresizing-mask-derived constraints just don't
        // get installed for this state combo; AppKit's Auto Layout
        // engine handles the view's layout downstream.
    }
}

@interface KPFAutoresizingAssertionFix : NSObject @end
@implementation KPFAutoresizingAssertionFix
+ (void)load {
    SEL sel = @selector(setTranslatesAutoresizingMaskIntoConstraints:);
    Method m = class_getInstanceMethod([NSView class], sel);
    if (!m) return;
    kpf_orig_setTranslatesAuto =
        (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, (IMP)kpf_setTranslatesAuto);
}
@end

// NSResponder Touch Bar (10.12.2+). 10.11 has no Touch Bar runtime; iWork
// sets a touch bar on its slide view controllers. Add to NSResponder so
// every NSView/NSViewController/NSApplication subclass gets it.
@interface NSResponder (KPF1011_TouchBar)
- (void)setTouchBar:(id)tb;
- (id)touchBar;
- (id)makeTouchBar;
@end
@implementation NSResponder (KPF1011_TouchBar)
- (void)setTouchBar:(id)tb { (void)tb; }
- (id)touchBar             { return nil; }
- (id)makeTouchBar         { return nil; }
@end

// NSDocument -isBrowsingVersions / -browseVersions: / -stopBrowsingVersions:
// (10.12+ Versions Browser API). 10.11 has no versions-browser hooks on
// NSDocument; iWork's KNMacDocument calls -isBrowsingVersions on itself
// to gate edit-mode UI.
@interface NSDocument (KPF1011)
- (BOOL)isBrowsingVersions;
- (void)browseVersions:(id)sender;
- (void)stopBrowsingVersionsWithCompletionHandler:(void (^)(void))handler;
@end
@implementation NSDocument (KPF1011)
- (BOOL)isBrowsingVersions { return NO; }
- (void)browseVersions:(id)sender { (void)sender; }
- (void)stopBrowsingVersionsWithCompletionHandler:(void (^)(void))handler {
    if (handler) handler();
}
@end

// NSSegmentedControl setSegmentDistribution: / segmentDistribution (10.13+).
// iWork's toolbar items call the setter on a segmented control. 10.12
// has no such property -> doesNotRecognizeSelector. No-op the setter and
// have the getter return 0 (= NSSegmentDistributionFit, the default).
@interface NSSegmentedControl (KPF1012)
- (void)setSegmentDistribution:(NSInteger)dist;
- (NSInteger)segmentDistribution;
@end
@implementation NSSegmentedControl (KPF1012)
- (void)setSegmentDistribution:(NSInteger)dist { (void)dist; }
- (NSInteger)segmentDistribution { return 0; }
@end

// Maps iWork / system color-asset names to a sensible 10.12 NSColor.
// Built from runtime tracing -- iWork calls +[NSColor colorNamed:] for
// asset names in its toolbar/inspector/canvas paths. Anything not in
// this map falls back to controlTextColor (so the dict insert path
// doesn't see nil) and logs the name so we can extend the table.
static NSColor *kpf_resolveNamedColor(NSString *name) {
    if (!name) return [NSColor controlTextColor];
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Filled in iteratively from KPF/COLOR-NAMED stderr captures.
        // Click through new UI to surface more `tma_*` / `sf_*` names,
        // then extend this map.
        map = @{
            @"tma_content_window_background_color":      [NSColor windowBackgroundColor],
            @"tma_toolbar_item_content_dimmed":          [NSColor tertiaryLabelColor],
            @"tma_document_split_view_divider_color":    [NSColor gridColor],
            @"sf_mac_tb_collaboration_content_color":    [NSColor keyboardFocusIndicatorColor],
        };
    });
    NSColor *hit = map[name];
    if (hit) return hit;
    // Always log unmapped names so the user can see what to add to the
    // map. De-dup so each name only logs once per process to avoid
    // spamming the log when iWork re-asks for the same color hundreds
    // of times during layout.
    static NSMutableSet *logged;
    static dispatch_once_t once_logged;
    dispatch_once(&once_logged, ^{ logged = [[NSMutableSet alloc] init]; });
    @synchronized (logged) {
        if (![logged containsObject:name]) {
            [logged addObject:name];
            NSLog(@"KPF/COLOR-NAMED unmapped name=%@", name);
        }
    }
    return [NSColor controlTextColor];
}

@implementation NSColor (KPF1012)
// 10.13+ named-color-asset API. 10.12 has no asset lookup. Returning
// nil matches the documented 10.13 behavior for unknown names, but
// iWork drops the result directly into a font-attribute NSDictionary
// that doesn't tolerate nil values (+dictionaryWithObjects:forKeys:count:
// throws). Map known names; fall back to controlTextColor.
+ (NSColor *)colorNamed:(NSString *)name {
    return kpf_resolveNamedColor(name);
}
+ (NSColor *)colorNamed:(NSString *)name bundle:(NSBundle *)bundle {
    (void)bundle;
    return kpf_resolveNamedColor(name);
}
// -[NSColor type] (10.13+) returns an NSColorType enum (0=componentBased,
// 1=pattern, 2=catalog). 10.12 has no such property; iWork uses it to
// pick code paths. Return componentBased (0), which matches the most
// common NSColor concrete type.
- (NSInteger)type { return 0; /* NSColorTypeComponentBased */ }
@end

// NSKeyedArchiver / NSKeyedUnarchiver 10.13+ secure-coding convenience
// methods (the older API is still present on 10.12; we forward to it).
@interface NSKeyedArchiver (KPF1012)
+ (NSData *)archivedDataWithRootObject:(id)object
                 requiringSecureCoding:(BOOL)requires
                                 error:(NSError **)error;
@end
@implementation NSKeyedArchiver (KPF1012)
+ (NSData *)archivedDataWithRootObject:(id)object
                 requiringSecureCoding:(BOOL)requires
                                 error:(NSError **)error {
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *arch =
        [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    arch.requiresSecureCoding = requires;
    @try {
        [arch encodeObject:object forKey:NSKeyedArchiveRootObjectKey];
        [arch finishEncoding];
    } @catch (NSException *exc) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:4864 /* NSCoderReadCorruptError -- enum is 10.11+ */
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                exc.reason ?: @""}];
        }
        return nil;
    }
    return data;
}
@end

@interface NSKeyedUnarchiver (KPF1012)
+ (id)unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data
                        error:(NSError **)error;
+ (id)unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data
                          error:(NSError **)error;
@end
@implementation NSKeyedUnarchiver (KPF1012)
+ (id)unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data
                        error:(NSError **)error {
    return [self unarchivedObjectOfClasses:[NSSet setWithObject:cls]
                                  fromData:data error:error];
}
+ (id)unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data
                          error:(NSError **)error {
    @try {
        NSKeyedUnarchiver *un =
            [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        un.requiresSecureCoding = YES;
        id obj = [un decodeObjectOfClasses:classes
                                    forKey:NSKeyedArchiveRootObjectKey];
        [un finishDecoding];
        return obj;
    } @catch (NSException *exc) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:4864 /* NSCoderReadCorruptError -- enum is 10.11+ */
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                exc.reason ?: @""}];
        }
        return nil;
    }
}
@end

// -[NSFileManager getFileProviderServicesForItemAtURL:completionHandler:]
// was added in 10.13 (file-provider extension API). iWork calls it from
// TSApplication's TSADocumentInfo.accessQueue. On 10.12 the selector
// doesn't exist on NSFileManager -> doesNotRecognizeSelector -> SIGILL.
// Provide a no-op category that invokes the completion handler with an
// empty services dict, mimicking "no file provider extensions present".
@interface NSFileManager (KPF1012)
- (void)getFileProviderServicesForItemAtURL:(NSURL *)url
                          completionHandler:(void (^)(NSDictionary *services,
                                                       NSError *error))handler;
@end
@implementation NSFileManager (KPF1012)
- (void)getFileProviderServicesForItemAtURL:(NSURL *)url
                          completionHandler:(void (^)(NSDictionary *services,
                                                       NSError *error))handler {
    (void)url;
    if (handler) handler(@{}, nil);
}
@end

// NSProgress 10.13+ file-progress additions. iWork's TSPersistence
// document-open path reads/writes these and the entire family is 10.13
// (introduced together with NSFileProvider). 10.12 NSProgress lacks them
// all -> doesNotRecognizeSelector. Provide no-op setters and nil/0
// getters via a category.
@interface NSProgress (KPF1012)
- (void)setFileOperationKind:(NSString *)kind;
- (NSString *)fileOperationKind;
- (void)setFileTotalCount:(NSNumber *)count;
- (NSNumber *)fileTotalCount;
- (void)setFileCompletedCount:(NSNumber *)count;
- (NSNumber *)fileCompletedCount;
- (void)setFileURL:(NSURL *)url;
- (NSURL *)fileURL;
@end
@implementation NSProgress (KPF1012)
- (void)setFileOperationKind:(NSString *)kind  { (void)kind; }
- (NSString *)fileOperationKind                { return nil; }
- (void)setFileTotalCount:(NSNumber *)count    { (void)count; }
- (NSNumber *)fileTotalCount                   { return nil; }
- (void)setFileCompletedCount:(NSNumber *)count{ (void)count; }
- (NSNumber *)fileCompletedCount               { return nil; }
- (void)setFileURL:(NSURL *)url                { (void)url; }
- (NSURL *)fileURL                             { return nil; }
@end

// CloudKit entitlement bypass.
// iWork's TSKit calls +[CKContainer containerWithIdentifier:@"com.apple.Keynote"]
// at first window load. On 10.13 with Apple-signed Keynote that works because
// the bundle is signed with com.apple.developer.icloud-services etc. After
// ad-hoc resigning we lose those entitlements (and we can't restore them --
// Apple's amfid rejects an ad-hoc signature carrying private Apple-team
// entitlements). The CKContainer init path throws an uncaught NSException
// somewhere inside the _checkSelfContainerIdentifier chain.
//
// First attempted to swizzle -[CKContainer _checkSelfContainerIdentifier],
// but that didn't stick (CKContainer is a class cluster on 10.12: the
// public class is a factory and instances are a private subclass that
// overrides _checkSelfContainerIdentifier, so swizzling the superclass
// doesn't intercept). Instead, swizzle the +containerWithIdentifier:
// factory itself to return nil; iWork's TSKit handles nil gracefully
// (its CK paths check the return value).
@interface KPFCloudKitBypass : NSObject @end
@implementation KPFCloudKitBypass
+ (void)load {
    Class CKContainer = NSClassFromString(@"CKContainer");
    if (!CKContainer) return;
    // +containerWithIdentifier: is a class method; we need the metaclass.
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:");
    Method m = class_getClassMethod(CKContainer, sel);
    if (!m) return;
    IMP nil_imp = imp_implementationWithBlock(^id(id self, NSString *ident){
        (void)self; (void)ident; return nil;
    });
    method_setImplementation(m, nil_imp);
    NSLog(@"KPF: stubbed +[CKContainer containerWithIdentifier:] -> nil");
}
@end

// KPF_TRACE_NIL_DICT diagnostic. When set, swizzles
// +[NSDictionary dictionaryWithObjects:forKeys:count:] to log any nil
// object/key before the call -- iWork's TSApplication / NSToolbar code
// builds an attribute dictionary with a nil objects[i], and we need to
// know which key has the nil value so we can stub the missing API.
typedef id (*NSDictWithObjsForKeysIMP)(Class, SEL,
    const id *, const id *, NSUInteger);
static NSDictWithObjsForKeysIMP kpf_orig_dictWithObjsForKeys = NULL;

static id kpf_dictWithObjsForKeys(Class self_, SEL _cmd,
                                   const id *objects,
                                   const id *keys,
                                   NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (objects[i] == nil || keys[i] == nil) {
            NSLog(@"KPF/NIL-DICT idx=%lu/%lu key=%@ obj=%p",
                  (unsigned long)i, (unsigned long)count,
                  keys[i] ?: @"(nil)",
                  (__bridge void *)objects[i]);
        }
    }
    return kpf_orig_dictWithObjsForKeys(self_, _cmd, objects, keys, count);
}

@interface KPFDictNilTraceLoader : NSObject @end
@implementation KPFDictNilTraceLoader
+ (void)load {
    if (!getenv("KPF_TRACE_NIL_DICT")) return;
    Method m = class_getClassMethod([NSDictionary class],
                                    @selector(dictionaryWithObjects:forKeys:count:));
    if (!m) return;
    kpf_orig_dictWithObjsForKeys = (NSDictWithObjsForKeysIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)kpf_dictWithObjsForKeys);
    NSLog(@"KPF: NSDictionary nil-tracer installed");
}
@end

// Parallel tracer for +[NSArray arrayWithObjects:count:]: logs the first
// nil object index and a small backtrace so we can identify which iWork
// call site is passing nil. Enabled via KPF_TRACE_NIL_ARRAY=1.
typedef id (*NSArrayWithObjsCountIMP)(Class, SEL, const id *, NSUInteger);
static NSArrayWithObjsCountIMP kpf_orig_arrayWithObjsCount = NULL;
static id kpf_arrayWithObjsCount(Class self_, SEL _cmd,
                                  const id *objs, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (objs[i] == nil) {
            NSArray *trace = [NSThread callStackSymbols];
            NSUInteger n = MIN((NSUInteger)8, trace.count);
            NSLog(@"KPF/NIL-ARRAY idx=%lu/%lu trace=\n%@",
                  (unsigned long)i, (unsigned long)count,
                  [[trace subarrayWithRange:NSMakeRange(0, n)]
                   componentsJoinedByString:@"\n"]);
            break;
        }
    }
    return kpf_orig_arrayWithObjsCount(self_, _cmd, objs, count);
}

@interface KPFArrayNilTraceLoader : NSObject @end
@implementation KPFArrayNilTraceLoader
+ (void)load {
    if (!getenv("KPF_TRACE_NIL_ARRAY")) return;
    Method m = class_getClassMethod([NSArray class],
                                    @selector(arrayWithObjects:count:));
    if (!m) return;
    kpf_orig_arrayWithObjsCount =
        (NSArrayWithObjsCountIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)kpf_arrayWithObjsCount);
    NSLog(@"KPF: NSArray nil-tracer installed");
}
@end

// ===== 10.12 additions absent on 10.11 =====================================
// Everything below this line is a 10.12-introduced API that we needed at
// runtime when iWork's static initializers / nib-load paths ran. Each was
// surfaced by the classifier's "function symbols still need implementations"
// list or by a runtime crash and added back as a minimum-correct shim.

// _os_log_impl is the base 10.12 logging entry point. iWork's TSCoreSOS /
// TSUtility emit calls to it from static init -- a NULL function pointer
// would SEGV. No-op (the actual log output is uninteresting for our use).
//   void _os_log_impl(void *dso, os_log_t log, os_log_type_t type,
//                     const char *format, uint8_t *buf, uint32_t size);
void _os_log_impl(void *dso, void *log, uint8_t type,
                  const char *fmt, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)fmt; (void)buf; (void)size;
}
// _os_log_error_impl / _os_log_fault_impl: 10.13+ variants (also needed
// for 10.11). Same no-op pattern.
void _os_log_error_impl(void *dso, void *log, uint8_t type,
                         const char *fmt, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)fmt; (void)buf; (void)size;
}
void _os_log_fault_impl(void *dso, void *log, uint8_t type,
                         const char *fmt, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)fmt; (void)buf; (void)size;
}
// os_log_type_enabled: 10.12 BOOL gating function. Always NO so the
// caller skips emitting (cheaper than calling our no-op _os_log_impl).
BOOL os_log_type_enabled(void *log, uint8_t type) {
    (void)log; (void)type;
    return NO;
}
// os_log_create: 10.12 factory returning an os_log_t handle bridged to
// ObjC under ARC. iWork stores results in many strong slots; we use a
// shared singleton with retain/release replaced at runtime so any
// number of releases keep refcount above zero (we found out the hard
// way on the 10.9 backport that a plain NSObject singleton dies fast
// under iWork's retain/release flow).
@interface KPFOSLog : NSObject @end
@implementation KPFOSLog @end
// IMPs declared with `void *` parameters and return so ARC doesn't try
// to objc_retain the `self` param or autorelease the return value (which
// it would do for an `id` typed return -- producing infinite recursion
// when these ARE the retain/release IMPs).
static void *kpf_oslog_retain_imp(void *self, SEL _cmd) {
    (void)_cmd; return self;
}
static void kpf_oslog_release_imp(void *self, SEL _cmd) {
    (void)self; (void)_cmd;
}
static NSUInteger kpf_oslog_rc_imp(void *self, SEL _cmd) {
    (void)self; (void)_cmd; return NSUIntegerMax;
}
__attribute__((constructor)) static void kpf_oslog_install_immortal(void) {
    Class cls = [KPFOSLog class];
    class_replaceMethod(cls, sel_registerName("retain"),
                        (IMP)kpf_oslog_retain_imp,  "@@:");
    class_replaceMethod(cls, sel_registerName("release"),
                        (IMP)kpf_oslog_release_imp, "v@:");
    class_replaceMethod(cls, sel_registerName("autorelease"),
                        (IMP)kpf_oslog_retain_imp,  "@@:");
    class_replaceMethod(cls, sel_registerName("retainCount"),
                        (IMP)kpf_oslog_rc_imp,      "Q@:");
}
static KPFOSLog *kpf_os_log_singleton = nil;
void *os_log_create(const char *subsystem, const char *category) {
    (void)subsystem; (void)category;
    // Diagnostic: KPF_NO_OS_LOG=1 makes us return NULL instead of a
    // singleton. On the 10.9 backport this isolated heap-corruption
    // sources (the singleton path turned out to be sensitive to ARC
    // retain/release imbalance even with no-op IMPs).
    if (getenv("KPF_NO_OS_LOG")) return NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kpf_os_log_singleton = [[KPFOSLog alloc] init];
    });
    return (__bridge void *)kpf_os_log_singleton;
}
// _os_log_default is a `struct os_log_s` global on 10.12+. iWork takes
// its address and passes it to _os_log_impl. The struct contents don't
// matter for us; just give the symbol a 64-byte writable storage slot.
__attribute__((visibility("default")))
char _os_log_default[64] = {0};

// ----- 10.12 os_unfair_lock --------------------------------------------------
// Binary-compatible with the OSSpinLock single-int32 slot. iWork uses
// these for lightweight critical sections; backing with OSSpinLock works
// because both initialise to 0 = unlocked.
#include <libkern/OSAtomic.h>
void os_unfair_lock_lock(int32_t *lock)             { OSSpinLockLock(lock); }
void os_unfair_lock_unlock(int32_t *lock)           { OSSpinLockUnlock(lock); }
BOOL os_unfair_lock_trylock(int32_t *lock)          { return OSSpinLockTry(lock); }
void os_unfair_lock_assert_owner(int32_t *lock)     { (void)lock; }
void os_unfair_lock_assert_not_owner(int32_t *lock) { (void)lock; }

// ----- 10.12 dispatch additions ---------------------------------------------
// Autorelease-frequency hint -- ignore the frequency, return the input
// attr unchanged so the dispatch_queue_create() call still gets a valid
// (or NULL) attr.
typedef int kpf_dispatch_autorelease_frequency_t;
void *dispatch_queue_attr_make_with_autorelease_frequency(
    void *attr, kpf_dispatch_autorelease_frequency_t freq) {
    (void)freq;
    return attr;
}
// dispatch_assert_queue / _not / _barrier (all 10.12). No-op assertions.
void dispatch_assert_queue_barrier(void *queue) { (void)queue; }
void dispatch_assert_queue_V2(void *queue)      { (void)queue; }
__asm__(".globl _dispatch_assert_queue$V2");
__asm__(".set _dispatch_assert_queue$V2, _dispatch_assert_queue_V2");
void dispatch_assert_queue_not_V2(void *queue)  { (void)queue; }
__asm__(".globl _dispatch_assert_queue_not$V2");
__asm__(".set _dispatch_assert_queue_not$V2, _dispatch_assert_queue_not_V2");

// _os_activity_label_useraction(const char *) -- 10.12+ telemetry hook,
// no-op so callers from static init proceed.
void _os_activity_label_useraction(const char *label) { (void)label; }

// ===== 10.13 additions absent on 10.11 (in addition to the 10.12 ones above)
// MetalPerformanceShaders availability probe -- iWork has non-MPS code
// paths on every MPS-using surface, so return NO.
BOOL MPSSupportsMTLDevice(id device) { (void)device; return NO; }

// CG additions iWork imports but rarely calls from static init. NULL
// returns make the caller fall back to legacy paths. CGColorConversionInfoRef
// is 10.12+ so we declare a local opaque pointer type for it.
#include <CoreGraphics/CGColorSpace.h>
typedef struct kpf_CGColorConversionInfo *kpf_CGColorConversionInfoRef;
void *CGColorSpaceCopyICCData(CGColorSpaceRef cs)       { (void)cs; return NULL; }
BOOL  CGColorSpaceIsWideGamutRGB(CGColorSpaceRef cs)    { (void)cs; return NO; }
kpf_CGColorConversionInfoRef CGColorConversionInfoCreate(
    CGColorSpaceRef src, CGColorSpaceRef dst)            {
    (void)src; (void)dst; return NULL;
}

// Sec additions used by iWork's keychain code paths. We don't have the
// 10.12+ key APIs on 10.11; return NULL/NO so the caller falls through.
// Use the real Security/CoreFoundation headers for ABI-correct typedefs.
#include <Security/SecKey.h>
CFDataRef SecKeyCreateEncryptedData(SecKeyRef k, CFStringRef alg,
                                    CFDataRef data, CFErrorRef *err) {
    (void)k; (void)alg; (void)data; (void)err; return NULL;
}
CFDataRef SecKeyCreateDecryptedData(SecKeyRef k, CFStringRef alg,
                                    CFDataRef data, CFErrorRef *err) {
    (void)k; (void)alg; (void)data; (void)err; return NULL;
}
CFDataRef SecKeyCreateSignature(SecKeyRef k, CFStringRef alg,
                                CFDataRef data, CFErrorRef *err) {
    (void)k; (void)alg; (void)data; (void)err; return NULL;
}
BOOL SecKeyIsAlgorithmSupported(SecKeyRef k, int operation, CFStringRef alg) {
    (void)k; (void)operation; (void)alg; return NO;
}

// _LAErrorDomain on 10.10 is in a private subframework, not in
// LocalAuthentication's own dylib. With the strict dlcheck (now using
// RTLD_FIRST), this is correctly classified as MISSING and the
// auto-stub generator emits `NSString *const LAErrorDomain = @"LAErrorDomain";`
// in kpf_auto_stubs.m, plus patch_surgical flat-redirects the bind.
// No hand stub needed here.

// __NSArray0__ / __NSDictionary0__ -- the canonical empty-collection
// singletons CFArray / CFDictionary expose. On 10.10 these symbols DO
// exist in CoreFoundation but as *local* (BSS, non-exported) symbols
// not in the export trie -- Keynote 9 (built on a newer SDK where
// they're exported) binds to them via a regular LC_LOAD_DYLIB entry,
// which dyld at 10.10-launch can't resolve. With strict dlcheck they
// surface as MISSING; we provide our own externally-visible storage
// and seed it at +load with over-retained empty mutable collections so
// any retain/release imbalance in iWork's static init can't dealloc
// the singleton (same pattern as the 10.9 backport).
__attribute__((visibility("default"))) id __NSArray0__      = nil;
__attribute__((visibility("default"))) id __NSDictionary0__ = nil;

// objc_unsafeClaimAutoreleasedReturnValue (10.12+): optimised ARC
// return-value transfer. Every ARC-compiled call returning id sits on
// this primitive in the caller. On 10.10/10.11 it doesn't exist; an
// auto-stub of `void *X = 0` becomes a NULL function pointer that
// SIGABRTs at the first ARC return. Fall back to the always-available
// objc_retainAutoreleasedReturnValue -- same observable semantics
// (+1 to caller, pool drops one at scope exit) at the cost of a real
// retain instead of the fast claim path.
extern id objc_retainAutoreleasedReturnValue(id obj);
id objc_unsafeClaimAutoreleasedReturnValue(id obj) {
    return objc_retainAutoreleasedReturnValue(obj);
}

// Make our empty-collection singletons immortal at the runtime level:
// swap retain / release / autorelease / retainCount on NSMutableArray
// and NSMutableDictionary instances when called on our specific
// singleton pointers. We need this because iWork's retain/release
// traffic across many TS framework static inits goes deeply negative,
// and either:
//   - Apple's shared empty singleton (from +array / +dictionary) dies
//     when the retain/release imbalance exceeds the singleton's
//     internal refcount (we see "objc_release + 15" segfaults on
//     dispatch worker threads after first overrelease);
//   - Or a fresh mutable instance with +N CFRetains eventually drops
//     to zero and gets dealloc'd, leading to the heap-corruption
//     "object modified after free" mid-static-init.
// The truly safe route is no-op retain/release on THIS specific object.
// Subclassing NSMutableArray is hairy (class cluster) so we patch the
// METHODS for whatever concrete class CoreFoundation hands us back,
// gated to only no-op when the receiver is our singleton pointer.
__attribute__((visibility("default"))) id kpf_array0_singleton      = nil;
__attribute__((visibility("default"))) id kpf_dict0_singleton       = nil;

// IMP types use `void *` (not `id`) to dodge ARC auto-retain on the
// retain IMP itself (which would otherwise infinite-recurse: ARC sees
// return type `id`, inserts objc_retain on the return value, retain
// dispatches back to us, ad infinitum).
static void *(*kpf_orig_array_retain)(void *, SEL)  = NULL;
static void  (*kpf_orig_array_release)(void *, SEL) = NULL;
static void *(*kpf_orig_dict_retain)(void *, SEL)   = NULL;
static void  (*kpf_orig_dict_release)(void *, SEL)  = NULL;

static void *kpf_array0_retain_imp(void *self, SEL _cmd) {
    if (self == (__bridge void *)kpf_array0_singleton) return self;
    return kpf_orig_array_retain ? kpf_orig_array_retain(self, _cmd) : self;
}
static void kpf_array0_release_imp(void *self, SEL _cmd) {
    if (self == (__bridge void *)kpf_array0_singleton) return;
    if (kpf_orig_array_release) kpf_orig_array_release(self, _cmd);
}
static void *kpf_dict0_retain_imp(void *self, SEL _cmd) {
    if (self == (__bridge void *)kpf_dict0_singleton) return self;
    return kpf_orig_dict_retain ? kpf_orig_dict_retain(self, _cmd) : self;
}
static void kpf_dict0_release_imp(void *self, SEL _cmd) {
    if (self == (__bridge void *)kpf_dict0_singleton) return;
    if (kpf_orig_dict_release) kpf_orig_dict_release(self, _cmd);
}

@interface KPFEmptyCollectionsLoader : NSObject @end
@implementation KPFEmptyCollectionsLoader
+ (void)load {
    NSMutableArray *arr       = [[NSMutableArray alloc] initWithCapacity:0];
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:0];
    kpf_array0_singleton = arr;
    kpf_dict0_singleton  = dict;
    __NSArray0__      = arr;
    __NSDictionary0__ = dict;

    // Patch retain/release on the concrete classes -- guard inside the
    // IMP so only OUR singleton is treated as immortal, other instances
    // get their normal behavior.
    Class arrCls = [arr class];
    SEL ret = sel_registerName("retain");
    SEL rel = sel_registerName("release");
    Method m;
    m = class_getInstanceMethod(arrCls, ret);
    if (m) {
        kpf_orig_array_retain = (id (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)kpf_array0_retain_imp);
    }
    m = class_getInstanceMethod(arrCls, rel);
    if (m) {
        kpf_orig_array_release = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)kpf_array0_release_imp);
    }
    Class dictCls = [dict class];
    m = class_getInstanceMethod(dictCls, ret);
    if (m) {
        kpf_orig_dict_retain = (id (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)kpf_dict0_retain_imp);
    }
    m = class_getInstanceMethod(dictCls, rel);
    if (m) {
        kpf_orig_dict_release = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)kpf_dict0_release_imp);
    }
    NSLog(@"KPF: __NSArray0__=%p __NSDictionary0__=%p (immortalized via IMP swap)",
          __NSArray0__, __NSDictionary0__);
}
@end

// ============================================================================
// Touch Bar class stubs (10.12.2+ APIs absent on 10.11). All classes inherit
// from a tiny inert base that:
//   - implements -init / -initWithCoder: returning self (so nib decoding
//     succeeds and ObjC alloc/init from iWork code returns a valid object);
//   - swallows every other selector via -forwardInvocation:, zeroing the
//     return value so primitive returns are 0 and id returns are nil.
//
// Net effect: iWork's Touch Bar setup paths can build out the entire Touch
// Bar item hierarchy without ever crashing, and the resulting objects do
// nothing observable (correct: 10.11 has no Touch Bar hardware/runtime).
// ============================================================================
@interface KPFInertObject : NSObject @end
@implementation KPFInertObject
- (instancetype)init { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    (void)coder;
    return [super init];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    // True no-op. We do NOT call [inv setReturnValue:] -- the invocation's
    // return slot is already zero-initialized by NSInvocation. Setting it
    // explicitly crashed when our generic "v@:" signature didn't match the
    // caller's actual call (NSInvocation's internal __NSI0 tripped a bounds
    // check inside setArgument:atIndex:-1). Letting the slot stay at its
    // default zero gives us nil-for-id / 0-for-primitive returns the same
    // way the explicit setReturnValue would have, without the alignment
    // hazard for caller-pushed args.
    (void)inv;
}
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}
+ (void)forwardInvocation:(NSInvocation *)inv {
    (void)inv;
}
- (BOOL)respondsToSelector:(SEL)sel { (void)sel; return YES; }
+ (BOOL)respondsToSelector:(SEL)sel { (void)sel; return YES; }
@end

#define KPF_INERT_CLASS(Name)         \
@interface Name : KPFInertObject @end \
@implementation Name @end

KPF_INERT_CLASS(NSTouchBar)
KPF_INERT_CLASS(NSTouchBarItem)
KPF_INERT_CLASS(NSCustomTouchBarItem)
KPF_INERT_CLASS(NSGroupTouchBarItem)
KPF_INERT_CLASS(NSColorPickerTouchBarItem)
KPF_INERT_CLASS(NSCandidateListTouchBarItem)
KPF_INERT_CLASS(NSPopoverTouchBarItem)
KPF_INERT_CLASS(NSScrubber)
KPF_INERT_CLASS(NSScrubberItemView)
KPF_INERT_CLASS(NSScrubberTextItemView)
KPF_INERT_CLASS(NSScrubberLayout)
KPF_INERT_CLASS(NSScrubberLayoutAttributes)
KPF_INERT_CLASS(NSScrubberFlowLayout)
KPF_INERT_CLASS(NSScrubberSelectionStyle)

// ============================================================================
// NSGridView / NSGridRow / NSGridColumn / NSGridCell (10.12).
//
// Required for real -- the Keynote Preferences window uses NSGridView in
// its nibs and we need the views to lay out so the prefs UI is usable.
//
// Strategy: NSGridView is a real NSView subclass that builds an internal
// NSStackView-of-NSStackViews (vertical stack of horizontal row stacks)
// from whatever cells/rows/columns get decoded from the nib. The
// supporting NSGridRow / NSGridColumn / NSGridCell are NSObject
// subclasses that hold their decoded list and answer the minimal API
// surface iWork queries (numberOfCells, cellAtIndex:, contentView, ...).
// ============================================================================
@class NSGridView, NSGridRow, NSGridColumn;
@interface NSGridCell : NSObject
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, weak)   NSGridRow *row;
@property (nonatomic, weak)   NSGridColumn *column;
@property (nonatomic, assign) NSInteger rowAlignment;
@property (nonatomic, assign) NSInteger xPlacement;
@property (nonatomic, assign) NSInteger yPlacement;
@property (nonatomic, strong) NSArray *customPlacementConstraints;
@end
@implementation NSGridCell
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (!self) return nil;
    @try {
        for (NSString *k in @[ @"NSGrid_contentView", @"contentView" ]) {
            if ([coder containsValueForKey:k]) {
                _contentView = [coder decodeObjectForKey:k];
                if (_contentView) break;
            }
        }
    } @catch (NSException *e) { (void)e; }
    return self;
}
@end

@interface NSGridRow : NSObject
@property (nonatomic, strong) NSMutableArray *cells;
@property (nonatomic, weak)   NSGridView *gridView;
@property (nonatomic, assign) CGFloat height;
@property (nonatomic, assign) CGFloat topPadding;
@property (nonatomic, assign) CGFloat bottomPadding;
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@property (nonatomic, assign) NSInteger rowAlignment;
@property (nonatomic, assign) NSInteger yPlacement;
@end
@implementation NSGridRow
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (!self) return nil;
    _cells = [NSMutableArray array];
    @try {
        for (NSString *k in @[ @"NSGrid_cells", @"cells", @"NSGrid_row_cells" ]) {
            if ([coder containsValueForKey:k]) {
                NSArray *encoded = [coder decodeObjectForKey:k];
                if ([encoded isKindOfClass:[NSArray class]]) {
                    [_cells addObjectsFromArray:encoded];
                    break;
                }
            }
        }
        _height = -1;
    } @catch (NSException *e) { (void)e; }
    return self;
}
- (NSInteger)numberOfCells { return (NSInteger)_cells.count; }
- (NSGridCell *)cellAtIndex:(NSInteger)i {
    return (i >= 0 && (NSUInteger)i < _cells.count) ? _cells[i] : nil;
}
@end

@interface NSGridColumn : NSObject
@property (nonatomic, weak)   NSGridView *gridView;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat leadingPadding;
@property (nonatomic, assign) CGFloat trailingPadding;
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@property (nonatomic, assign) NSInteger xPlacement;
@end
@implementation NSGridColumn
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (!self) return nil;
    _width = -1;
    return self;
}
@end

@interface NSGridView : NSView
// Lightweight generics on Foundation collections are clang 7+ (Xcode 7).
// The 10.10 guest runs clang 6.0 / Xcode 6.2 -- generics don't parse here.
@property (nonatomic, strong) NSMutableArray *kpf_rows;
@property (nonatomic, strong) NSMutableArray *kpf_columns;
@property (nonatomic, assign) CGFloat rowSpacing;
@property (nonatomic, assign) CGFloat columnSpacing;
@end
@implementation NSGridView
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (!self) return nil;
    _kpf_rows = [NSMutableArray array];
    _kpf_columns = [NSMutableArray array];
    _rowSpacing = 6;
    _columnSpacing = 8;
    @try {
        for (NSString *k in @[ @"NSGrid_rows", @"rows", @"NSGrid_gridRows" ]) {
            if ([coder containsValueForKey:k]) {
                NSArray *rows = [coder decodeObjectForKey:k];
                if ([rows isKindOfClass:[NSArray class]]) {
                    [_kpf_rows addObjectsFromArray:rows];
                    break;
                }
            }
        }
        for (NSString *k in @[ @"NSGrid_columns", @"columns", @"NSGrid_gridColumns" ]) {
            if ([coder containsValueForKey:k]) {
                NSArray *cols = [coder decodeObjectForKey:k];
                if ([cols isKindOfClass:[NSArray class]]) {
                    [_kpf_columns addObjectsFromArray:cols];
                    break;
                }
            }
        }
        if ([coder containsValueForKey:@"NSGrid_rowSpacing"]) {
            _rowSpacing = (CGFloat)[coder decodeDoubleForKey:@"NSGrid_rowSpacing"];
        }
        if ([coder containsValueForKey:@"NSGrid_columnSpacing"]) {
            _columnSpacing = (CGFloat)[coder decodeDoubleForKey:@"NSGrid_columnSpacing"];
        }
    } @catch (NSException *e) { (void)e; }

    // Wire up back-references so cells/rows know their grid. iWork
    // queries these for autolayout setup and tab-key cycling.
    for (NSGridRow *row in _kpf_rows) {
        row.gridView = self;
        NSUInteger ci = 0;
        for (NSGridCell *cell in row.cells) {
            cell.row = row;
            if (ci < _kpf_columns.count) cell.column = _kpf_columns[ci];
            ci++;
        }
    }
    for (NSGridColumn *col in _kpf_columns) col.gridView = self;

    // Lay out decoded cells as actual subviews. Each row becomes a
    // horizontal NSStackView; rows stack vertically inside us.
    //
    // 10.10 API differences from the 10.11 sibling: NSLayoutAnchor
    // (topAnchor etc.) is 10.11+, so use the older
    // +[NSLayoutConstraint constraintWithItem:attribute:...]; and
    // -[NSStackView addArrangedSubview:] is also 10.11+, so use the
    // 10.9-era -[NSStackView addView:inGravity:] which appends to
    // the trailing gravity slot.
    NSStackView *vstack = [[NSStackView alloc] init];
    vstack.translatesAutoresizingMaskIntoConstraints = NO;
    vstack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vstack.alignment = NSLayoutAttributeLeading;
    vstack.spacing = _rowSpacing;
    [self addSubview:vstack];
    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:vstack
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self
                                     attribute:NSLayoutAttributeTop
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:vstack
                                     attribute:NSLayoutAttributeLeading
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self
                                     attribute:NSLayoutAttributeLeading
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:vstack
                                     attribute:NSLayoutAttributeTrailing
                                     relatedBy:NSLayoutRelationLessThanOrEqual
                                        toItem:self
                                     attribute:NSLayoutAttributeTrailing
                                    multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:vstack
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationLessThanOrEqual
                                        toItem:self
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1.0 constant:0.0],
    ]];
    for (NSGridRow *row in _kpf_rows) {
        NSStackView *hstack = [[NSStackView alloc] init];
        hstack.translatesAutoresizingMaskIntoConstraints = NO;
        hstack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        hstack.spacing = _columnSpacing;
        hstack.alignment = NSLayoutAttributeCenterY;
        for (NSGridCell *cell in row.cells) {
            NSView *v = cell.contentView;
            if ([v isKindOfClass:[NSView class]]) {
                [hstack addView:v inGravity:NSStackViewGravityTrailing];
            }
        }
        [vstack addView:hstack inGravity:NSStackViewGravityTrailing];
    }
    return self;
}
- (NSInteger)numberOfRows    { return (NSInteger)_kpf_rows.count; }
- (NSInteger)numberOfColumns { return (NSInteger)_kpf_columns.count; }
- (NSGridRow *)rowAtIndex:(NSInteger)i {
    return (i >= 0 && (NSUInteger)i < _kpf_rows.count) ? _kpf_rows[i] : nil;
}
- (NSGridColumn *)columnAtIndex:(NSInteger)i {
    return (i >= 0 && (NSUInteger)i < _kpf_columns.count) ? _kpf_columns[i] : nil;
}
- (NSGridCell *)cellAtColumnIndex:(NSInteger)col rowIndex:(NSInteger)r {
    NSGridRow *row = [self rowAtIndex:r];
    return [row cellAtIndex:col];
}
- (NSGridCell *)cellForView:(NSView *)view {
    for (NSGridRow *row in _kpf_rows) {
        for (NSGridCell *cell in row.cells) {
            if (cell.contentView == view) return cell;
            // Also accept descendants -- iWork sometimes passes an
            // inner view (the actual label/control) rather than the
            // cell's direct contentView.
            NSView *v = view;
            while (v) {
                if (v == cell.contentView) return cell;
                v = v.superview;
            }
        }
    }
    return nil;
}
- (NSInteger)indexOfRow:(NSGridRow *)row    { return [_kpf_rows indexOfObject:row]; }
- (NSInteger)indexOfColumn:(NSGridColumn *)col { return [_kpf_columns indexOfObject:col]; }
@end
