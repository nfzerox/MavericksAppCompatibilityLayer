// kpf_stubs_keynote9_10_12.m -- the entire 10.13 -> 10.12 hand-stub surface for
// Keynote 9. This file is the 10.12-specific complement of
// stubs/kpf_stubs.m (which targets 10.9).
//
// Everything else iWork imports from 10.13 (NSString constants, ObjC
// class symbols, CFStringRef constants, ...) is handled by the
// auto-generated stubs/kpf_auto_stubs_1012.m via tools/gen_stubs.py.
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

// +[NSColor colorNamed:] / colorNamed:bundle: (10.13+ named color
// assets). 10.12 AppKit has no named-color asset lookup; the documented
// 10.13 behavior is "returns nil if no asset matches", which iWork's
// NIB-decode path tolerates.
@interface NSColor (KPF1012)
+ (NSColor *)colorNamed:(NSString *)name;
+ (NSColor *)colorNamed:(NSString *)name bundle:(NSBundle *)bundle;
@end
// NSWindow tab APIs (10.13+). 10.12 has the tabbingMode/tabbingIdentifier
// + +allowsAutomaticWindowTabbing pieces but not -tab/-tabGroup/-tabbedWindows.
// Return nil from each; iWork uses them for tab-related menu items that
// gracefully no-op when no tab group exists.
@interface NSWindow (KPF1012)
- (id)tabGroup;
- (id)tab;
- (NSArray *)tabbedWindows;
@end
@implementation NSWindow (KPF1012)
- (id)tabGroup       { return nil; }
- (id)tab            { return nil; }
- (NSArray *)tabbedWindows { return nil; }
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
        // Filled in iteratively from KPF_LOG_COLOR_NAMED stderr captures.
        // Re-run with KPF_LOG_COLOR_NAMED=1 and click through new UI to
        // surface more `tma_*` / `sf_*` names, then extend this map.
        map = @{
            @"tma_content_window_background_color":      [NSColor windowBackgroundColor],
            @"tma_toolbar_item_content_dimmed":          [NSColor tertiaryLabelColor],
            @"tma_document_split_view_divider_color":    [NSColor gridColor],
            @"sf_mac_tb_collaboration_content_color":    [NSColor keyboardFocusIndicatorColor],
        };
    });
    NSColor *hit = map[name];
    if (hit) return hit;
    if (getenv("KPF_LOG_COLOR_NAMED")) {
        NSLog(@"KPF/COLOR-NAMED unmapped name=%@", name);
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
                                         code:NSCoderInvalidValueError
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
                                         code:NSCoderReadCorruptError
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

// 10.13+ os_log error/fault path. Signature:
//   void _os_log_error_impl(void *dso, os_log_t log, os_log_type_t type,
//                           const char *format, uint8_t *buf, uint32_t size);
void _os_log_error_impl(void *dso, void *log, uint8_t type,
                         const char *fmt, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)fmt; (void)buf; (void)size;
}
void _os_log_fault_impl(void *dso, void *log, uint8_t type,
                         const char *fmt, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)fmt; (void)buf; (void)size;
}
