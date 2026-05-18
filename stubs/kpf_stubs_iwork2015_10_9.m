/*
 * MavericksAppCompatibilityLayer Yosemite stubs.
 *
 * Built as a dylib and injected via DYLD_INSERT_LIBRARIES (with
 * DYLD_FORCE_FLAT_NAMESPACE=1) so that Keynote's weakly-bound references
 * to 10.10-only AppKit/Foundation classes and constants resolve to these
 * shims instead of NULL.
 *
 * The shims are deliberately minimal — enough to satisfy linker references
 * and keep code paths from segfaulting on NULL receivers, not to
 * actually provide the Yosemite features.
 */

#import <AppKit/AppKit.h>
#import <AddressBook/AddressBook.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <stdint.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-missing-property-synthesis"

// ----- VC scrollWheel forwarder for non-overriding view controllers --------
// NSResponder's default -scrollWheel: doesn't reliably forward via
// -nextResponder on 10.9 (or at least not in the way 10.10 apps assume).
// Our VC-in-responder-chain shim therefore inserts a "dead end" for scroll
// events through any NSViewController that doesn't override -scrollWheel:.
// Provide a category implementation that always forwards to view.superview
// so the enclosing NSScrollView still gets the event. VCs that have their
// own -scrollWheel: (TSDMacCanvasViewController, NSPageController, ...)
// still take precedence; those are separately wrapped below to also
// forward after running.
@interface NSViewController (KPFScrollForward)
@end
@implementation NSViewController (KPFScrollForward)
- (void)scrollWheel:(NSEvent *)event {
    NSView *v = [self view];
    NSView *sup = [v superview];
    if (sup) [sup scrollWheel:event];
}
@end

// ----- VC scrollWheel auto-forward (10.10 -> 10.9 compat) ------------------
// Keynote's NSViewController subclasses (TSDMacCanvasViewController etc.)
// override -scrollWheel: and *consume* the event without calling super.
// On 10.10 that's fine because actual scrolling is performed by some other
// layer (gesture recognizer on the contained NSScrollView, or the VC's
// own bounds-mutation path). On 10.9 those alternative paths don't fire
// and the underlying NSScrollView never gets the event, so the scroll
// view doesn't scroll. After Keynote's VC handler runs, manually forward
// the event to view.superview so the responder chain continues into the
// enclosing NSScrollView -- it scrolls and Keynote's local tracking
// inside the VC handler still happens.
typedef void (*KpfVCScrollImp)(id, SEL, NSEvent *);
typedef struct {
    Class           cls;
    KpfVCScrollImp  orig;
} KpfVCScrollEntry;
#define KPF_VC_SCROLL_MAX 64
static KpfVCScrollEntry kpf_vc_scroll_hooks[KPF_VC_SCROLL_MAX];
static int kpf_vc_scroll_count = 0;

static KpfVCScrollImp kpf_lookup_vc_scroll(Class cls) {
    for (int i = 0; i < kpf_vc_scroll_count; i++) {
        if (kpf_vc_scroll_hooks[i].cls == cls) return kpf_vc_scroll_hooks[i].orig;
    }
    return NULL;
}

static void kpf_vc_scroll_wrapper(id self, SEL _cmd, NSEvent *ev) {
    KpfVCScrollImp orig = NULL;
    for (Class c = [self class]; c && !orig; c = class_getSuperclass(c)) {
        orig = kpf_lookup_vc_scroll(c);
    }
    if (orig) {
        @try { orig(self, _cmd, ev); } @catch (id e) {}
    }
    // Forward into the responder chain past the VC so the enclosing
    // NSScrollView actually scrolls.
    NSView *v = nil;
    if ([self respondsToSelector:@selector(view)]) {
        v = [self performSelector:@selector(view)];
    }
    NSView *sup = [v superview];
    if (sup) [sup scrollWheel:ev];
}

static void kpf_install_vc_scroll_forward(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    SEL sel = @selector(scrollWheel:);
    Class vcRoot = [NSViewController class];
    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        // Don't wrap NSViewController itself -- our category provides a
        // forwarding -scrollWheel: there for the non-overriding case, and
        // wrapping it would intercept [super scrollWheel:] calls from
        // concrete subclasses and bounce them back through the same wrap
        // (lookup_orig walks the receiver class chain).
        if (c == vcRoot) continue;
        // is c a subclass of NSViewController?
        BOOL isVC = NO;
        for (Class p = c; p; p = class_getSuperclass(p)) {
            if (p == vcRoot) { isVC = YES; break; }
        }
        if (!isVC) continue;
        // does c *own* (not inherit) scrollWheel: ?
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        BOOL owns = NO;
        for (unsigned int j = 0; j < mn; j++) {
            if (method_getName(ms[j]) == sel) { owns = YES; break; }
        }
        if (ms) free(ms);
        if (!owns) continue;
        if (kpf_vc_scroll_count >= KPF_VC_SCROLL_MAX) {
            NSLog(@"KPF/SCROLL table full");
            break;
        }
        Method m = class_getInstanceMethod(c, sel);
        kpf_vc_scroll_hooks[kpf_vc_scroll_count++] = (KpfVCScrollEntry){
            .cls  = c,
            .orig = (KpfVCScrollImp)method_getImplementation(m),
        };
        method_setImplementation(m, (IMP)kpf_vc_scroll_wrapper);
        if (getenv("KPF_TRACE_INSTALL")) {
            NSLog(@"KPF/SCROLL forward-wrap -[%s scrollWheel:]", class_getName(c));
        }
    }
    free(list);
}

__attribute__((constructor))
static void kpf_schedule_vc_scroll_install(void) {
    // Defer until classes are loaded -- Keynote VC classes don't exist at
    // dylib constructor time.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
            (void)n;
            kpf_install_vc_scroll_forward();
        }];
}

// ----- NSViewController in responder chain (10.10) -------------------------
// On 10.10 every NSViewController auto-inserts itself into the responder
// chain: a managed view's nextResponder is its controller, and the
// controller's nextResponder is the view's superview. Keynote's
// TSDMacCanvasViewController owns -mouseDown: / -keyDown: for the slide
// canvas, so without this splice, clicks reach TSDCanvasView (the view) and
// then forward to NSClipView, never visiting the controller -- the canvas
// becomes click-deaf and keystrokes go nowhere.
//
// We replicate Apple's wiring by associating each view with its controller
// on setView: and overriding -nextResponder on both ends.

static const void *KPF_VC_FOR_VIEW = &KPF_VC_FOR_VIEW;
static const void *KPF_VC_DIDLOAD_FIRED = &KPF_VC_DIDLOAD_FIRED;
static IMP kpf_orig_VC_setView           = NULL;
// nextResponder is inherited from NSResponder by both NSView and
// NSViewController; we capture NSResponder's IMP once and call it for the
// "default" path (returns nil unless an explicit nextResponder is set).
static IMP kpf_orig_NSResponder_nextResponder = NULL;

// 10.10's NSViewController invokes -viewDidLoad once after its view is set
// (loaded from nib or assigned). 10.9 has no such method, so any iWork
// subclass that puts its post-load wiring there (e.g.
// KNMacPlayToolbarMenuItemViewController populates topTextField /
// centerTextField / bottomTextField from -configuration) is silently
// skipped -- the user sees the nib's IB placeholder text ("Upper" /
// "Middle" / "Lower") instead of the real strings.
//
// Install a no-op -viewDidLoad on NSViewController so [super viewDidLoad]
// calls in subclass overrides don't raise. Then, on first -setView:,
// invoke -viewDidLoad if the actual class's IMP differs from the no-op
// (i.e. the subclass overrides). Guarded by an associated flag so it
// only fires once.
static void kpf_NSVC_viewDidLoad_noop(id self, SEL _cmd) { (void)self; (void)_cmd; }

// Returns YES iff `c` (or any subclass between c and NSResponder) declares
// its own implementation of at least one event-handler selector. NSResponder
// subclasses that DON'T override any of these handlers should not be inserted
// into the responder chain: AppKit's mouseDown dispatch stops at a responder
// whose nextResponder is such a "transparent" VC, breaking forwarding to
// the window (e.g. KNMacPlaybackWindow's slide-advance handler).
static BOOL kpf_class_owns_event_handler(Class c) {
    static const char *handlers[] = {
        "mouseDown:", "mouseUp:", "mouseDragged:",
        "rightMouseDown:", "rightMouseUp:", "rightMouseDragged:",
        "otherMouseDown:", "otherMouseUp:", "otherMouseDragged:",
        "keyDown:", "keyUp:", "flagsChanged:",
        "scrollWheel:", "magnifyWithEvent:", "swipeWithEvent:",
        "rotateWithEvent:", "smartMagnifyWithEvent:",
        "beginGestureWithEvent:", "endGestureWithEvent:",
        NULL,
    };
    // Stop at NSViewController (not NSResponder): we added our own
    // -scrollWheel: forwarder via a NSViewController category at the top of
    // this file, and we don't want that synthetic forwarder to count as
    // the subclass "owning" an event handler.
    Class stop = [NSViewController class];
    Class start = c;
    while (c && c != stop) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *name = sel_getName(method_getName(ms[i]));
            for (int j = 0; handlers[j]; j++) {
                if (strcmp(name, handlers[j]) == 0) {
                    if (getenv("KPF_TRACE_CHAIN")) {
                        NSLog(@"KPF/OWNS-MATCH start=%s match_on=%s sel=%s",
                              class_getName(start), class_getName(c), name);
                    }
                    if (ms) free(ms);
                    return YES;
                }
            }
        }
        if (ms) free(ms);
        c = class_getSuperclass(c);
    }
    return NO;
}

static void kpf_VC_setView(NSViewController *self, SEL _cmd, NSView *v) {
    ((void(*)(id, SEL, NSView *))kpf_orig_VC_setView)(self, _cmd, v);
    if (!v) return;
    // Only associate the VC with the view (which is what makes the shim's
    // -nextResponder route through the VC) if the VC actually handles some
    // event. Otherwise the VC sits in the chain as a dead end: AppKit's
    // mouseDown dispatch reaches the VC, the VC's inherited NSResponder
    // default mouseDown doesn't forward, and the event never reaches the
    // window. Playback (KNMacAnimatedPlaybackViewController has no event
    // handlers) used to lose clicks for exactly this reason.
    BOOL owns = kpf_class_owns_event_handler([self class]);
    if (getenv("KPF_TRACE_CHAIN")) {
        NSLog(@"KPF/VC-SETVIEW %s view=%s owns_handler=%d -> %s",
              class_getName([self class]),
              class_getName([v class]),
              owns,
              owns ? "associated" : "skipped");
    }
    if (owns) {
        objc_setAssociatedObject(v, KPF_VC_FOR_VIEW, self, OBJC_ASSOCIATION_ASSIGN);
    }
    if (objc_getAssociatedObject(self, KPF_VC_DIDLOAD_FIRED)) return;
    SEL didLoad = @selector(viewDidLoad);
    IMP imp  = class_getMethodImplementation([self class], didLoad);
    IMP base = class_getMethodImplementation([NSViewController class], didLoad);
    if (imp == base) return;  // subclass doesn't override -- nothing to call
    objc_setAssociatedObject(self, KPF_VC_DIDLOAD_FIRED, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void(*)(id, SEL))objc_msgSend)(self, didLoad);
}

static NSResponder *kpf_NSView_nextResponder(NSView *self, SEL _cmd) {
    NSViewController *vc = objc_getAssociatedObject(self, KPF_VC_FOR_VIEW);
    NSResponder *ret = vc ? (NSResponder *)vc :
        ((NSResponder *(*)(id, SEL))kpf_orig_NSResponder_nextResponder)(self, _cmd);
    if (getenv("KPF_TRACE_CHAIN")) {
        NSLog(@"KPF/NXT view %s -> %s%s",
              class_getName([self class]),
              ret ? class_getName([ret class]) : "(nil)",
              vc ? " [via VC]" : " [via NSResponder default]");
    }
    return ret;
}

static NSResponder *kpf_VC_nextResponder(NSViewController *self, SEL _cmd) {
    NSView *v = [self view];
    NSView *sup = [v superview];
    NSResponder *ret = sup ? (NSResponder *)sup :
        ((NSResponder *(*)(id, SEL))kpf_orig_NSResponder_nextResponder)(self, _cmd);
    if (getenv("KPF_TRACE_CHAIN")) {
        NSLog(@"KPF/NXT vc   %s -> %s%s",
              class_getName([self class]),
              ret ? class_getName([ret class]) : "(nil)",
              sup ? " [view.superview]" : " [NSResponder default]");
    }
    return ret;
}

__attribute__((constructor))
static void kpf_install_vc_responder_chain(void) {
    Class vc = [NSViewController class];
    Class vw = [NSView class];

    // setView: is owned by NSViewController itself -- normal IMP swap is fine.
    Method m1 = class_getInstanceMethod(vc, @selector(setView:));
    kpf_orig_VC_setView = method_getImplementation(m1);
    method_setImplementation(m1, (IMP)kpf_VC_setView);

    // Capture NSResponder's inherited nextResponder IMP for fallback.
    Method base = class_getInstanceMethod([NSResponder class], @selector(nextResponder));
    kpf_orig_NSResponder_nextResponder = method_getImplementation(base);
    const char *types = method_getTypeEncoding(base);

    // Add (not replace) per-class IMPs so we don't disturb NSResponder.
    class_addMethod(vw, @selector(nextResponder), (IMP)kpf_NSView_nextResponder, types);
    class_addMethod(vc, @selector(nextResponder), (IMP)kpf_VC_nextResponder,     types);

    // Backfill -viewDidLoad on NSViewController if AppKit doesn't ship it
    // (true on 10.9). class_addMethod returns NO if it already exists, in
    // which case we leave AppKit's IMP alone.
    class_addMethod(vc, @selector(viewDidLoad), (IMP)kpf_NSVC_viewDidLoad_noop, "v@:");
}

// ----- Direct-IMP hooks for Keynote event handlers ------------------------
// We capture the original IMP for each (class, selector) pair into a small
// table and replace the method with a wrapper that calls the original IMP
// as a plain C function, passing the *original* selector for `_cmd`. That
// keeps NSResponder's `objc_msgSend(nextResponder, _cmd, ev)` forwarding
// intact -- earlier attempts used a renamed shadow selector, which broke
// the responder chain (NSClipView complains it doesn't know kpf_orig_*).
typedef void (*KpfEventImp)(id, SEL, NSEvent *);

typedef struct {
    Class       cls;
    SEL         sel;
    KpfEventImp orig;
} KpfHookEntry;

#define KPF_MAX_HOOKS 32
static KpfHookEntry kpf_hooks[KPF_MAX_HOOKS];
static int kpf_hook_count = 0;

static KpfEventImp kpf_lookup_orig(Class cls, SEL sel) {
    for (int i = 0; i < kpf_hook_count; i++) {
        if (kpf_hooks[i].sel == sel) {
            // Walk up the class hierarchy until we find the entry that
            // matches; the same selector may be hooked on multiple classes.
            for (Class c = cls; c; c = class_getSuperclass(c)) {
                if (kpf_hooks[i].cls == c && kpf_hooks[i].sel == sel) {
                    return kpf_hooks[i].orig;
                }
            }
        }
    }
    return NULL;
}

static void kpf_log_event_handler(id self, SEL _cmd, NSEvent *ev) {
    NSLog(@"KPF/HOOK >> -[%@ %s] type=%ld loc=%@",
          [self class], sel_getName(_cmd), (long)[ev type],
          NSStringFromPoint([ev locationInWindow]));
    KpfEventImp orig = kpf_lookup_orig([self class], _cmd);
    if (!orig) {
        NSLog(@"KPF/HOOK !! no orig IMP for -[%@ %s]", [self class], sel_getName(_cmd));
        return;
    }
    @try {
        orig(self, _cmd, ev);
    } @catch (NSException *e) {
        NSLog(@"KPF/HOOK !! -[%@ %s] threw: %@ %@", [self class], sel_getName(_cmd),
              [e name], [e reason]);
    }
    // Get the window via either the view (for views) or the controller's
    // view (for view controllers); some hooked classes are NSViewController
    // subclasses where -window isn't a method.
    id w = nil;
    if ([self respondsToSelector:@selector(window)]) {
        w = [self performSelector:@selector(window)];
    } else if ([self respondsToSelector:@selector(view)]) {
        id v = [self performSelector:@selector(view)];
        if ([v respondsToSelector:@selector(window)]) {
            w = [v performSelector:@selector(window)];
        }
    }
    id fr = [w respondsToSelector:@selector(firstResponder)]
            ? [w performSelector:@selector(firstResponder)] : nil;
    NSLog(@"KPF/HOOK <<  -[%@ %s] returned, firstResp=<%@>",
          [self class], sel_getName(_cmd), fr);
}

static void kpf_wrap_method(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"KPF/HOOK no %s on %@", sel_getName(sel), cls); return; }
    // Skip if `cls` doesn't *own* the method (just inherits it). Wrapping
    // an inherited method would let class_addMethod succeed, but the IMP
    // captured via method_getImplementation is whatever lives on the
    // superclass *right now* -- which may already be our own hook from an
    // earlier kpf_wrap_method call on the parent. That creates an infinite
    // recursion when our hook calls orig(). The parent's wrap already
    // catches calls on subclass instances anyway.
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL owned = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { owned = YES; break; }
    }
    if (list) free(list);
    if (!owned) {
        NSLog(@"KPF/HOOK skip inherited -[%@ %s]", cls, sel_getName(sel));
        return;
    }
    if (kpf_hook_count >= KPF_MAX_HOOKS) { NSLog(@"KPF/HOOK table full"); return; }
    kpf_hooks[kpf_hook_count++] = (KpfHookEntry){
        .cls  = cls, .sel = sel,
        .orig = (KpfEventImp)method_getImplementation(m),
    };
    method_setImplementation(m, (IMP)kpf_log_event_handler);
    NSLog(@"KPF/HOOK wrapped -[%@ %s]", cls, sel_getName(sel));
}

// Print every Keynote-prefixed class that has its OWN mouseDown:/keyDown:
// (not inherited). Tells us which class actually owns the canvas/text-box
// event logic.
static void kpf_dump_keynote_event_owners(void) {
    SEL sels[] = { @selector(mouseDown:), @selector(mouseUp:),
                   @selector(rightMouseDown:), @selector(keyDown:),
                   @selector(insertText:), @selector(interpretKeyEvents:),
                   @selector(scrollWheel:), @selector(magnifyWithEvent:) };
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        const char *name = class_getName(c);
        if (strncmp(name, "TS", 2) != 0 &&
            strncmp(name, "KN", 2) != 0 &&
            strncmp(name, "TMA", 3) != 0) continue;
        // Walk the direct method list -- avoids inherited methods.
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        for (unsigned int j = 0; j < mn; j++) {
            SEL ms_sel = method_getName(ms[j]);
            for (size_t s = 0; s < sizeof(sels)/sizeof(sels[0]); s++) {
                if (ms_sel == sels[s]) {
                    NSLog(@"KPF/OWN -[%s %s]", name, sel_getName(ms_sel));
                }
            }
        }
        if (ms) free(ms);
    }
    free(list);
}

static void kpf_install_keynote_event_hooks(void) {
    if (!getenv("KPF_TRACE_EVENTS")) return;
    kpf_dump_keynote_event_owners();
    // Wrap scrollWheel: on the canvas VC, scrollview, and base NSScrollView
    // so we can see whether scroll events reach the scroll layer at all.
    const char *names[] = {"TSKScrollView", NULL};
    for (int i = 0; names[i]; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        kpf_wrap_method(c, @selector(scrollWheel:));
    }
    // Playback-mouse diagnostics: wrap -mouseDown: on the container view
    // and the playback window so we can see whether each handler is
    // actually invoked when the user clicks during a presentation.
    const char *playback_classes[] = {
        "KNMacAnimatedPlaybackContainerView",
        "KNMacPlaybackWindow",
        NULL,
    };
    for (int i = 0; playback_classes[i]; i++) {
        Class c = objc_getClass(playback_classes[i]);
        if (!c) continue;
        kpf_wrap_method(c, @selector(mouseDown:));
        kpf_wrap_method(c, @selector(mouseUp:));
    }
}


// ----- Constraint-creation tracer (KPF_TRACE_CONSTRAINTS=lo,hi) -----------
// Logs every NSLayoutConstraint factory + setConstant: call whose constant
// lands in [lo, hi], with a stack trace so we can see who's planting the
// "73pt top inset" type values that come from the 10.10-overlay
// assumptions.
static CGFloat kpf_trace_lo = 0, kpf_trace_hi = 0;
static IMP kpf_orig_NSLC_factory = NULL;
static IMP kpf_orig_NSLC_initCoder = NULL;
static IMP kpf_orig_NSLC_initItem  = NULL;
static IMP kpf_orig_NSLC_setConstant = NULL;
static IMP kpf_orig_NSView_addConstraint = NULL;

static void kpf_maybe_log_constraint(NSLayoutConstraint *c, const char *where) {
    if (!c) return;
    CGFloat v = c.constant;
    if (v < kpf_trace_lo || v > kpf_trace_hi) return;
    NSLog(@"KPF/LC %s c=%g first=<%@>.%ld rel=%ld second=<%@>.%ld mul=%g priority=%g",
          where, v,
          [c.firstItem className], (long)c.firstAttribute,
          (long)c.relation,
          c.secondItem ? [c.secondItem className] : @"nil", (long)c.secondAttribute,
          c.multiplier, c.priority);
    NSArray *frames = [NSThread callStackSymbols];
    for (NSUInteger i = 0; i < MIN(frames.count, (NSUInteger)15); i++) {
        NSLog(@"KPF/LC   %@", frames[i]);
    }
}

static id kpf_NSLC_factory(id self, SEL _cmd,
                            id v1, NSLayoutAttribute a1, NSLayoutRelation r,
                            id v2, NSLayoutAttribute a2,
                            CGFloat mul, CGFloat c) {
    NSLayoutConstraint *cons = ((id(*)(id, SEL, id, NSLayoutAttribute, NSLayoutRelation,
                                       id, NSLayoutAttribute, CGFloat, CGFloat))
                                kpf_orig_NSLC_factory)(self, _cmd, v1, a1, r, v2, a2, mul, c);
    kpf_maybe_log_constraint(cons, "factory");
    return cons;
}

static id kpf_NSLC_initCoder(id self, SEL _cmd, NSCoder *coder) {
    id cons = ((id(*)(id, SEL, NSCoder *))kpf_orig_NSLC_initCoder)(self, _cmd, coder);
    kpf_maybe_log_constraint(cons, "initCoder");
    return cons;
}

static id kpf_NSLC_initItem(id self, SEL _cmd,
                             id v1, NSLayoutAttribute a1, NSLayoutRelation r,
                             id v2, NSLayoutAttribute a2,
                             CGFloat mul, CGFloat c) {
    id cons = ((id(*)(id, SEL, id, NSLayoutAttribute, NSLayoutRelation,
                      id, NSLayoutAttribute, CGFloat, CGFloat))
               kpf_orig_NSLC_initItem)(self, _cmd, v1, a1, r, v2, a2, mul, c);
    kpf_maybe_log_constraint(cons, "initItem");
    return cons;
}

static void kpf_NSLC_setConstant(NSLayoutConstraint *self, SEL _cmd, CGFloat v) {
    ((void(*)(id, SEL, CGFloat))kpf_orig_NSLC_setConstant)(self, _cmd, v);
    if (v >= kpf_trace_lo && v <= kpf_trace_hi) {
        kpf_maybe_log_constraint(self, "setConstant");
    }
}

// Walk a view's subtree and zero any Top-Top, Equal, mul=1 constraint whose
// |constant| matches the window's chrome height (titlebar + toolbar on 10.9).
// Keynote/Pages/Numbers were built expecting NSFullSizeContentViewWindowMask
// and bake the chrome offset into their layout constraints; on 10.9 the
// contentView already starts below the chrome so the offset becomes a
// visible gap. We can't prevent Keynote from creating the constraints
// (their construction is inside Keynote's own -updateConstraints), so we
// just keep zeroing them.
static void kpf_walk_and_zero_chrome(NSView *v, CGFloat chrome) {
    for (NSLayoutConstraint *c in v.constraints) {
        if (c.firstAttribute  != NSLayoutAttributeTop)  continue;
        if (c.secondAttribute != NSLayoutAttributeTop)  continue;
        if (c.relation != NSLayoutRelationEqual)        continue;
        if (c.multiplier != 1.0)                        continue;
        if (!c.secondItem)                              continue;
        @try {
            CGFloat val = c.constant;
            if (fabs(fabs(val) - chrome) < 1.5 && val != 0) {
                if (getenv("KPF_TRACE_FIX")) {
                    NSLog(@"KPF/FIX zero chrome inset <%@>.Top == <%@>.Top %+g  (chrome=%g)",
                          [c.firstItem className], [c.secondItem className], val, chrome);
                }
                c.constant = 0;
            }
        } @catch (id e) {
            // NIB-loaded constraints sometimes hold symbolic constants
            // (NSSpace) that raise when -constant is read on 10.9; nothing
            // to do for those, skip.
        }
    }
    for (NSView *sub in v.subviews) kpf_walk_and_zero_chrome(sub, chrome);
}

// iWork ships its own title bars (TSCHMacCDEWindowTitleBar et al.) including
// their own close/min/zoom buttons (TSCHMacCDEWindowStandardButtonsView).
// On Yosemite, NSFullSizeContentViewWindowMask + titlebarAppearsTransparent
// + NSWindowTitleHidden makes the system title bar invisible so iWork's
// title bar IS the title bar. Mavericks has none of those APIs, so dropping
// NSTitledWindowMask is the closest equivalent: the system chrome
// disappears, contentView fills the whole window, and iWork's title bar --
// originally framed at y = windowHeight - barHeight -- ends up flush with
// the top of the (now full-height) contentView.
//
// Keep this list explicit -- a broad `*TitleBar*` substring match risked
// sweeping in AppKit / 3rd-party views.
static const char *kpf_iwork_title_bar_classes[] = {
    "TSCHMacCDEWindowTitleBar",   // Keynote Chart Data Editor
    NULL,
};

static NSView *kpf_iwork_title_bar(NSView *cv) {
    for (NSView *sub in cv.subviews) {
        const char *name = class_getName([sub class]);
        if (!name) continue;
        for (size_t i = 0; kpf_iwork_title_bar_classes[i]; i++) {
            if (strcmp(name, kpf_iwork_title_bar_classes[i]) == 0) return sub;
        }
    }
    return nil;
}

// For windows we DON'T de-chrome (no iWork title bar): iWork sometimes still
// frames a top-anchored subview at y = windowHeight - h (assuming Yosemite's
// full-size content view). Slide any direct contentView subview whose top
// overflows by roughly `chrome` back down so it sits flush with the
// contentView top.
static void kpf_fix_title_bar_overflow(NSView *cv, CGFloat chrome) {
    CGFloat cvTop = cv.bounds.size.height;
    for (NSView *sub in cv.subviews) {
        if (sub.isHidden) continue;
        NSRect f = sub.frame;
        CGFloat overflow = NSMaxY(f) - cvTop;
        if (overflow > 0.5 && overflow <= chrome + 0.5) {
            f.origin.y -= overflow;
            [sub setFrame:f];
        }
    }
}

// HUD windows (KNMacHUDBackgroundView root) want light text on the dark
// fill. On Yosemite, the window's VibrantDark appearance makes
// NSColor.labelColor / .controlTextColor return light; Mavericks's
// labelColor is a fixed black-w-alpha so any label inside reads black on
// black. Recolor non-editable NSTextFields under the HUD subtree once
// each (associated-object guard prevents the observer from churning
// setNeedsDisplay every update cycle).
static NSColor *kpf_hud_light_color(void) {
    return [NSColor colorWithCalibratedWhite:1.0 alpha:0.95];
}

static BOOL kpf_color_is_light(NSColor *c) {
    NSColor *rgb = [c colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (!rgb) return NO;
    return rgb.redComponent > 0.85 && rgb.greenComponent > 0.85 && rgb.blueComponent > 0.85;
}

// Returns YES iff v sits inside a KNMacHUD* subtree AND no bordered NSButton
// sits between v and that ancestor. Bordered buttons (Cancel, OK, etc.)
// have their own light bezel, so their title text needs the system color,
// not our HUD light override.
static BOOL kpf_view_under_HUD(NSView *v) {
    for (NSView *p = v; p; p = p.superview) {
        if ([p isKindOfClass:[NSButton class]] && [(NSButton *)p isBordered]) return NO;
        if ([NSStringFromClass([p class]) hasPrefix:@"KNMacHUD"]) return YES;
    }
    return NO;
}

// Globally intercept -[NSTextField setTextColor:]: if the field is currently
// in a KNMacHUD* subtree, force the color to light. Catches iWork's
// re-paint after a checkbox toggle (which re-sets textColor to black),
// without depending on the observer firing in time.
static IMP kpf_orig_NSTF_setTextColor = NULL;
static void kpf_NSTF_setTextColor(NSTextField *self, SEL _cmd, NSColor *c) {
    BOOL under = kpf_view_under_HUD(self);
    if (getenv("KPF_TRACE_HUD")) {
        NSMutableString *chain = [NSMutableString string];
        for (NSView *p = self.superview; p; p = p.superview) {
            BOOL bord = NO;
            if ([p isKindOfClass:[NSButton class]]) {
                @try { bord = [(NSButton *)p isBordered]; } @catch (id e) {}
            }
            [chain appendFormat:@" -> %s%s",
             class_getName([p class]), bord ? "[bordered]" : ""];
        }
        NSLog(@"KPF/HUD setTextColor tf=\"%@\" under_HUD=%d chain:%@",
              [self stringValue], under, chain);
    }
    if (under) c = kpf_hud_light_color();
    ((void(*)(id, SEL, id))kpf_orig_NSTF_setTextColor)(self, _cmd, c);
}

__attribute__((constructor))
static void kpf_install_NSTF_setTextColor_override(void) {
    Method m = class_getInstanceMethod([NSTextField class], @selector(setTextColor:));
    if (!m) return;
    kpf_orig_NSTF_setTextColor = method_getImplementation(m);
    method_setImplementation(m, (IMP)kpf_NSTF_setTextColor);
}

static void kpf_recolor_hud_subtree(NSView *root) {
    BOOL trace = (getenv("KPF_TRACE_HUD") != NULL);
    for (NSView *v in root.subviews) {
        if (trace) {
            NSLog(@"KPF/HUD visit class=%s frame=%@",
                  class_getName([v class]),
                  NSStringFromRect(v.frame));
        }
        if ([v isKindOfClass:[NSTextField class]] && kpf_view_under_HUD(v)) {
            NSTextField *tf = (NSTextField *)v;
            NSColor *light = kpf_hud_light_color();
            // setTextColor: itself is intercepted to force light, so this
            // is mostly belt-and-braces -- but check current color anyway
            // to skip when iWork hasn't yet had a chance to re-set it.
            // kpf_view_under_HUD gates out NSTextFields inside bordered
            // NSButtons (Cancel/OK/Use Auto Layout), whose system bezel
            // is light -- white text there is invisible.
            if (!kpf_color_is_light(tf.textColor)) tf.textColor = light;
            NSAttributedString *as = nil;
            @try { as = [tf attributedStringValue]; } @catch (id e) {}
            if (as.length) {
                NSColor *fg = nil;
                @try { fg = [as attribute:NSForegroundColorAttributeName
                                   atIndex:0 effectiveRange:NULL]; } @catch (id e) {}
                if (!fg || !kpf_color_is_light(fg)) {
                    NSMutableAttributedString *m = [as mutableCopy];
                    [m addAttribute:NSForegroundColorAttributeName
                              value:light range:NSMakeRange(0, m.length)];
                    @try { [tf setAttributedStringValue:m]; } @catch (id e) {}
                }
            }
            if (trace) NSLog(@"KPF/HUD   tf=\"%@\" -> recolored", [tf stringValue]);
        }
        // NSMatrix cells (radio buttons) aren't NSViews -- they're NSCell
        // instances, so the recursive walk doesn't reach them. Recolor each
        // cell's attributed title in place.
        if ([v isKindOfClass:[NSMatrix class]]) {
            NSMatrix *m = (NSMatrix *)v;
            NSInteger rows = 0, cols = 0;
            @try { [m getNumberOfRows:&rows columns:&cols]; } @catch (id e) {}
            NSColor *light = kpf_hud_light_color();
            for (NSInteger r = 0; r < rows; r++) {
                for (NSInteger c = 0; c < cols; c++) {
                    NSCell *cell = nil;
                    @try { cell = [m cellAtRow:r column:c]; } @catch (id e) {}
                    if (!cell) continue;
                    NSString *title = nil;
                    @try { title = [cell title]; } @catch (id e) {}
                    if (!title.length) continue;
                    NSAttributedString *at = nil;
                    if ([cell respondsToSelector:@selector(attributedTitle)]) {
                        @try { at = [(id)cell attributedTitle]; } @catch (id e) {}
                    }
                    NSColor *fg = nil;
                    if (at.length) {
                        @try { fg = [at attribute:NSForegroundColorAttributeName
                                          atIndex:0 effectiveRange:NULL]; } @catch (id e) {}
                    }
                    if (fg && kpf_color_is_light(fg)) continue;
                    if (![cell respondsToSelector:@selector(setAttributedTitle:)]) continue;
                    NSMutableAttributedString *na;
                    if (at.length) {
                        // Preserve original font / paragraph style / etc.;
                        // only the foreground color changes.
                        na = [at mutableCopy];
                    } else {
                        NSFont *font = [cell font];
                        NSDictionary *base = font ? @{NSFontAttributeName: font} : @{};
                        na = [[NSMutableAttributedString alloc]
                              initWithString:title attributes:base];
                    }
                    [na addAttribute:NSForegroundColorAttributeName
                               value:light range:NSMakeRange(0, na.length)];
                    @try { [(id)cell setAttributedTitle:na]; } @catch (id e) {}
                    if (trace) NSLog(@"KPF/HUD   matrix cell[%ld,%ld]=\"%@\" -> recolored",
                                     (long)r, (long)c, title);
                }
            }
        }
        kpf_recolor_hud_subtree(v);
    }
}

static void kpf_fix_window_chrome(NSWindow *self) {
    NSView *cv = [self contentView];
    if (!cv) return;

    if ([NSStringFromClass([cv class]) hasPrefix:@"KNMacHUD"]) {
        if (getenv("KPF_TRACE_HUD")) {
            NSLog(@"KPF/HUD enter win=%s cv=%s cv.subviews.count=%lu",
                  class_getName([self class]),
                  class_getName([cv class]),
                  (unsigned long)cv.subviews.count);
        }
        kpf_recolor_hud_subtree(cv);
        // The observer often fires once when the HUD window's contentView is
        // installed but before its deeper subviews exist. Schedule a couple
        // of delayed passes to catch late-added text fields.
        static const void *KPF_HUD_SCHEDULED = &KPF_HUD_SCHEDULED;
        if (!objc_getAssociatedObject(self, KPF_HUD_SCHEDULED)) {
            objc_setAssociatedObject(self, KPF_HUD_SCHEDULED, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSWindow *w = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSView *cv2 = [w contentView];
                if (cv2 && [NSStringFromClass([cv2 class]) hasPrefix:@"KNMacHUD"]) {
                    if (getenv("KPF_TRACE_HUD")) NSLog(@"KPF/HUD delayed pass (0.2s)");
                    kpf_recolor_hud_subtree(cv2);
                }
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSView *cv2 = [w contentView];
                if (cv2 && [NSStringFromClass([cv2 class]) hasPrefix:@"KNMacHUD"]) {
                    if (getenv("KPF_TRACE_HUD")) NSLog(@"KPF/HUD delayed pass (1.0s)");
                    kpf_recolor_hud_subtree(cv2);
                }
            });
        }
    }

    NSView *iworkBar = kpf_iwork_title_bar(cv);
    if (iworkBar) {
        NSUInteger mask = [self styleMask];
        if (mask & NSTitledWindowMask) {
            // Drop the system title bar. iWork already provides its own
            // (TSCHMacCDEWindowTitleBar) with embedded close/min/zoom
            // buttons (TSCHMacCDEWindowStandardButtonsView), so removing
            // NSTitled gives us the contentView at full window height.
            // Trade-off: Mavericks borderless windows lose the AppKit
            // drop shadow; -setHasShadow:YES doesn't restore it here.
            [self setStyleMask:(mask & ~NSTitledWindowMask)];
            cv = [self contentView]; // refresh: bounds grew by chrome
        }
        // Snap the title bar to the top of the (now full-height)
        // contentView. Covers two cases: (a) a prior chrome-overflow pass
        // moved it down, and (b) autoresize didn't re-anchor it after the
        // styleMask change.
        NSRect f = iworkBar.frame;
        CGFloat desiredY = cv.bounds.size.height - f.size.height;
        if (fabs(f.origin.y - desiredY) > 0.5) {
            f.origin.y = desiredY;
            [iworkBar setFrame:f];
        }
        return;
    }

    CGFloat chrome = self.frame.size.height - cv.bounds.size.height;
    if (chrome > 0) {
        kpf_walk_and_zero_chrome(cv, chrome);
        kpf_fix_title_bar_overflow(cv, chrome);
    }
}

// Single hook for the chrome-inset fix: NSWindowDidUpdateNotification fires
// after every window-update cycle, by which point AppKit has run anything
// Keynote added during -updateConstraints. Walks the contentView subtree
// and zeroes chrome-style constraints. Cheap (the inner filter short-
// circuits on attribute/relation/multiplier mismatches before touching
// -constant) and self-correcting -- any constraint Keynote re-installs
// later (e.g. when entering Edit Master Slide) gets zeroed on the next
// update notification.
__attribute__((constructor))
static void kpf_install_chrome_inset_fix(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidUpdateNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
            NSWindow *w = note.object;
            if (w) kpf_fix_window_chrome(w);
        }];
}

// Trace-only addConstraint hook: logs (and forwards) constraints whose
// constant lands in the user-requested [lo, hi] range. Used by the
// KPF_TRACE_CONSTRAINTS diagnostic; not part of the production fix.
static void kpf_NSView_addConstraint_trace(NSView *self, SEL _cmd, NSLayoutConstraint *c) {
    ((void(*)(id, SEL, id))kpf_orig_NSView_addConstraint)(self, _cmd, c);
    if (kpf_trace_lo == kpf_trace_hi) return;
    @try {
        CGFloat v = c.constant;
        if (v >= kpf_trace_lo && v <= kpf_trace_hi) {
            NSLog(@"KPF/LC addConstraint host=<%@>", [self className]);
            kpf_maybe_log_constraint(c, "addConstraint");
        }
    } @catch (id e) {}
}

__attribute__((constructor))
static void kpf_install_constraint_tracer(void) {
    const char *env = getenv("KPF_TRACE_CONSTRAINTS");
    if (!env) return;
    double lo = 0, hi = 0;
    if (sscanf(env, "%lf,%lf", &lo, &hi) != 2) return;
    kpf_trace_lo = lo; kpf_trace_hi = hi;

    Class meta = object_getClass([NSLayoutConstraint class]);
    Method m1 = class_getClassMethod([NSLayoutConstraint class],
        @selector(constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:));
    if (m1) {
        kpf_orig_NSLC_factory = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)kpf_NSLC_factory);
    }
    (void)meta;
    Method m2 = class_getInstanceMethod([NSLayoutConstraint class], @selector(initWithCoder:));
    if (m2) {
        kpf_orig_NSLC_initCoder = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)kpf_NSLC_initCoder);
    }
    // Also hook the designated initializer (covers callers that bypass the
    // class-method factory, e.g. via [[NSLayoutConstraint alloc] init...]).
    SEL initSel = @selector(initWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:);
    Method m4 = class_getInstanceMethod([NSLayoutConstraint class], initSel);
    if (m4) {
        kpf_orig_NSLC_initItem = method_getImplementation(m4);
        method_setImplementation(m4, (IMP)kpf_NSLC_initItem);
    }
    Method m3 = class_getInstanceMethod([NSLayoutConstraint class], @selector(setConstant:));
    if (m3) {
        kpf_orig_NSLC_setConstant = method_getImplementation(m3);
        method_setImplementation(m3, (IMP)kpf_NSLC_setConstant);
    }
    Method m5 = class_getInstanceMethod([NSView class], @selector(addConstraint:));
    if (m5) {
        kpf_orig_NSView_addConstraint = method_getImplementation(m5);
        method_setImplementation(m5, (IMP)kpf_NSView_addConstraint_trace);
    }
    NSLog(@"KPF: constraint tracer installed for c in [%g, %g]", lo, hi);
}

// ----- UI inspection dump (kill -USR1 <pid> OR Ctrl-Opt-Cmd-D) -------------
// Writes the full window + view hierarchy of every NSWindow in the app to
// /tmp/kpf_view_dump.txt: class name, frame, bounds, hidden/alpha,
// translatesAutoresizingMaskIntoConstraints, intrinsicContentSize, NSWindow
// styleMask / toolbar, and every autolayout constraint owned by each view.
// Position the UI in the state you want to inspect, then trigger the dump
// with kill -USR1 or the key combo and scp the file back.

static void kpf_describe_constraint(FILE *f, NSLayoutConstraint *c) {
    static const char *atts[] = {
        "none","Left","Right","Top","Bottom","Leading","Trailing",
        "Width","Height","CenterX","CenterY","Baseline",
        "LeftMargin","RightMargin","TopMargin","BottomMargin",
        "LeadingMargin","TrailingMargin","CenterXMargin","CenterYMargin",
        "BaselineMargin"
    };
    static const char *rels[] = { "<=", "==", ">=" };
    NSInteger fa = c.firstAttribute, sa = c.secondAttribute;
    NSInteger r  = c.relation + 1; // -1,0,1 -> 0,1,2
    const char *fname = (fa >= 0 && fa < (NSInteger)(sizeof(atts)/sizeof(*atts))) ? atts[fa] : "?";
    const char *sname = (sa >= 0 && sa < (NSInteger)(sizeof(atts)/sizeof(*atts))) ? atts[sa] : "?";
    const char *rstr  = (r >= 0 && r < 3) ? rels[r] : "?";
    fprintf(f, "%s.%s %s ", [[c.firstItem className] UTF8String] ?: "nil", fname, rstr);
    if (c.secondItem) {
        fprintf(f, "%s.%s ", [[c.secondItem className] UTF8String] ?: "nil", sname);
        if (c.multiplier != 1.0) fprintf(f, "*%g ", c.multiplier);
        if (c.constant != 0)     fprintf(f, "%+g ", c.constant);
    } else {
        fprintf(f, "%g ", c.constant);
    }
    fprintf(f, "[p=%g]", c.priority);
}

static void kpf_dump_view(FILE *f, NSView *v, int depth) {
    for (int i = 0; i < depth; i++) fputs("  ", f);
    NSRect fr = v.frame, b = v.bounds;
    fprintf(f, "%s %p frame=(%g,%g %gx%g)",
            [[v className] UTF8String], v, fr.origin.x, fr.origin.y, fr.size.width, fr.size.height);
    if (!NSEqualRects(b, (NSRect){{0,0}, fr.size})) {
        fprintf(f, " bounds=(%g,%g %gx%g)", b.origin.x, b.origin.y, b.size.width, b.size.height);
    }
    if (v.isHidden)              fprintf(f, " HIDDEN");
    if (v.alphaValue != 1.0)     fprintf(f, " alpha=%g", v.alphaValue);
    NSSize ics = v.intrinsicContentSize;
    if (ics.width != NSViewNoInstrinsicMetric || ics.height != NSViewNoInstrinsicMetric) {
        fprintf(f, " intrinsic=(%g,%g)", ics.width, ics.height);
    }
    if (!v.translatesAutoresizingMaskIntoConstraints) fprintf(f, " noAuto");
    NSString *txt = nil;
    if ([v respondsToSelector:@selector(stringValue)]) {
        @try { txt = [(id)v stringValue]; } @catch (id e) {}
    } else if ([v respondsToSelector:@selector(title)]) {
        @try { txt = [(id)v title]; } @catch (id e) {}
    }
    if (txt.length) fprintf(f, " %s", [[NSString stringWithFormat:@"\"%@\"", txt] UTF8String]);
    NSArray *cs = v.constraints;
    if (cs.count) fprintf(f, " constraints=%lu", (unsigned long)cs.count);
    fputc('\n', f);
    for (NSLayoutConstraint *c in cs) {
        for (int i = 0; i < depth + 1; i++) fputs("  ", f);
        fputs("| ", f); kpf_describe_constraint(f, c); fputc('\n', f);
    }
    for (NSView *sub in v.subviews) kpf_dump_view(f, sub, depth + 1);
}

static void kpf_dump_all_windows(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    NSDate *now = [NSDate date];
    fprintf(f, "=== kpf view dump %s ===\n", [[now description] UTF8String]);
    for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
        NSRect fr = w.frame;
        fprintf(f, "\n[Window %p %s] frame=(%g,%g %gx%g) styleMask=0x%lx visible=%d key=%d title=\"%s\"\n",
                w, [[w className] UTF8String], fr.origin.x, fr.origin.y, fr.size.width, fr.size.height,
                (unsigned long)w.styleMask, w.isVisible, w.isKeyWindow,
                [[w title] UTF8String] ?: "");
        if (w.toolbar) {
            fprintf(f, "  toolbar=%s visible=%d sizeMode=%ld\n",
                    [[w.toolbar className] UTF8String], w.toolbar.isVisible, (long)w.toolbar.sizeMode);
        }
        if (w.contentView) kpf_dump_view(f, w.contentView, 1);
    }
    fclose(f);
    NSLog(@"KPF/DUMP wrote %s", path);
    NSBeep();  // audible "dump succeeded" confirmation
}

// Produce a per-process dump path like /tmp/kpf_view_dump_Keynote.txt so
// dumps from multiple iWork apps don't clobber each other.
static const char *kpf_dump_path(void) {
    static char buf[256];
    const char *name = [[[NSProcessInfo processInfo] processName] UTF8String] ?: "app";
    snprintf(buf, sizeof(buf), "/tmp/kpf_view_dump_%s.txt", name);
    return buf;
}

static void kpf_sigusr1_handler(int sig) {
    (void)sig;
    // signal handler -> dispatch onto main queue (object access not async-safe)
    dispatch_async(dispatch_get_main_queue(), ^{
        kpf_dump_all_windows(kpf_dump_path());
    });
}

__attribute__((constructor))
static void kpf_install_dump_hooks(void) {
    signal(SIGUSR1, kpf_sigusr1_handler);
    [NSEvent addLocalMonitorForEventsMatchingMask:NSKeyDownMask
                                          handler:^NSEvent *(NSEvent *e) {
        NSUInteger m = e.modifierFlags & (NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask|NSShiftKeyMask);
        // Ctrl-Opt-Cmd-D: chosen to avoid collision with any Keynote shortcut.
        if (m == (NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)
            && [[e charactersIgnoringModifiers] isEqualToString:@"d"]) {
            kpf_dump_all_windows(kpf_dump_path());
            return nil; // swallow the event
        }
        return e;
    }];
    if (getenv("KPF_TRACE_INSTALL")) {
        NSLog(@"KPF: view dump installed (kill -USR1 %d  or  Ctrl-Opt-Cmd-D, -> %s)",
              getpid(), kpf_dump_path());
    }
}

// ----- Debug event tracer (opt-in via KPF_TRACE_EVENTS=1) -----------------
// Logs left/right mouse-down and key-down events the moment they reach the
// app, alongside the window, hit-test view, and current first responder.
// We get a side-by-side picture of why left-click is dropped but right-click
// is not -- if hitTest returns different views, or one path nils out the
// first responder, etc.
__attribute__((constructor))
static void kpf_install_event_tracer(void) {
    if (!getenv("KPF_TRACE_EVENTS")) return;
    [NSEvent addLocalMonitorForEventsMatchingMask:
        (NSLeftMouseDownMask | NSRightMouseDownMask | NSKeyDownMask
         | NSLeftMouseUpMask | NSScrollWheelMask)
        handler:^NSEvent *(NSEvent *ev) {
            NSWindow *w = [ev window] ?: [NSApp keyWindow];
            NSPoint locWin = [ev locationInWindow];
            id hit = w ? [[w contentView] hitTest:locWin] : nil;
            id fr  = [w firstResponder];
            NSString *kind = @"?";
            switch ([ev type]) {
                case NSLeftMouseDown:  kind = @"L-DOWN"; break;
                case NSLeftMouseUp:    kind = @"L-UP";   break;
                case NSRightMouseDown: kind = @"R-DOWN"; break;
                case NSKeyDown:        kind = @"KEY";    break;
                case NSScrollWheel:    kind = @"SCROLL"; break;
                default: break;
            }
            NSString *extra = @"";
            if ([ev type] == NSKeyDown) extra = [ev charactersIgnoringModifiers];
            else if ([ev type] == NSScrollWheel) {
                extra = [NSString stringWithFormat:@"dx=%g dy=%g phase=%lu mphase=%lu",
                         [ev scrollingDeltaX], [ev scrollingDeltaY],
                         (unsigned long)[ev phase], (unsigned long)[ev momentumPhase]];
            }
            NSLog(@"KPF/EV %@ win=%@ loc=%@ hit=<%@ %p> firstResp=<%@ %p> %@",
                  kind, [w className], NSStringFromPoint(locWin),
                  [hit class], hit, [fr class], fr, extra);
            // For scroll events, also dump the responder chain starting at
            // the hit-test view -- tells us whether NSViewController is in
            // there and where the chain reaches NSScrollView (if at all).
            if ([ev type] == NSScrollWheel && hit && [ev phase] == 1) {
                NSMutableString *chain = [NSMutableString string];
                id r = hit;
                int depth = 0;
                while (r && depth++ < 12) {
                    [chain appendFormat:@"%@%@", chain.length ? @" -> " : @"",
                     [r className]];
                    r = [r respondsToSelector:@selector(nextResponder)]
                        ? [r nextResponder] : nil;
                }
                NSLog(@"KPF/EV chain: %@", chain);
            }
            return ev;
        }];
    NSLog(@"KPF: event tracer installed");

    // Hook Keynote-specific handlers once the app has finished launching
    // (the classes don't exist until Keynote's binary text is mapped in).
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        (void)n;
        kpf_install_keynote_event_hooks();
    }];
}

// ----- Associated-object storage helpers ----------------------------------
// Categories on Apple classes can't add ivars, so getter/setter pairs are
// backed by objc_setAssociatedObject using the getter SEL as the key. This
// way setting and then getting returns the same value, which matches what
// Keynote expects for things like preferredContentSize, contentInsets etc.

static inline void kpf_set_obj(id self_, void *key, id value) {
    objc_setAssociatedObject(self_, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline id kpf_get_obj(id self_, void *key) {
    return objc_getAssociatedObject(self_, key);
}
static inline void kpf_set_bool(id self_, void *key, BOOL v) {
    objc_setAssociatedObject(self_, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline BOOL kpf_get_bool(id self_, void *key) {
    return [objc_getAssociatedObject(self_, key) boolValue];
}
static inline void kpf_set_int(id self_, void *key, NSInteger v) {
    objc_setAssociatedObject(self_, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline NSInteger kpf_get_int(id self_, void *key) {
    return [objc_getAssociatedObject(self_, key) integerValue];
}
static inline void kpf_set_cgfloat(id self_, void *key, CGFloat v) {
    objc_setAssociatedObject(self_, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline CGFloat kpf_get_cgfloat(id self_, void *key) {
    return [objc_getAssociatedObject(self_, key) doubleValue];
}
static inline void kpf_set_size(id self_, void *key, NSSize v) {
    objc_setAssociatedObject(self_, key, [NSValue valueWithSize:v], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline NSSize kpf_get_size(id self_, void *key) {
    NSValue *v = objc_getAssociatedObject(self_, key);
    return v ? [v sizeValue] : NSZeroSize;
}
static inline void kpf_set_insets(id self_, void *key, NSEdgeInsets v) {
    NSValue *val = [NSValue valueWithBytes:&v objCType:@encode(NSEdgeInsets)];
    objc_setAssociatedObject(self_, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline NSEdgeInsets kpf_get_insets(id self_, void *key) {
    NSValue *v = objc_getAssociatedObject(self_, key);
    NSEdgeInsets out = {0, 0, 0, 0};
    if (v) [v getValue:&out];
    return out;
}

// ----- Yosemite-only classes -----------------------------------------------

// NSVisualEffectView: 10.10+. Stub as a plain NSView with a solid fill per
// material -- Mavericks has no blur compositor, so we approximate the
// "vibrant" surface with the matching opaque palette color that Yosemite/
// El Capitan settled on. This gives content behind comments bars, rulers,
// sidebars, etc. a visible backing instead of leaking the page underneath.
@interface NSVisualEffectView : NSView
@property (nonatomic) NSInteger material;
@property NSInteger blendingMode;
@property NSInteger state;
@property NSInteger interiorBackgroundStyle;
@property(retain) NSImage *maskImage;
@property BOOL emphasized;
@end

// NSVisualEffectMaterial values from the 10.10 / 10.11 SDK.
//   0 AppearanceBased (deprecated)   1 Light (deprecated)
//   2 Dark (deprecated)              3 Titlebar
//   4 Selection                      5 Menu
//   6 Popover                        7 Sidebar
//   8 MediumLight                    9 UltraDark
// Newer materials (10.14+: HeaderView, Sheet, WindowBackground, ...) we map
// onto the closest pre-10.11 surface.
static NSColor *kpf_color_for_vfx_material(NSInteger m) {
    switch (m) {
        case 2:  // Dark
        case 9:  // UltraDark
            return [NSColor colorWithCalibratedWhite:0.18 alpha:1.0];
        case 4:  // Selection -- match 10.9 "alternate selected" blue, muted
            return [NSColor colorWithCalibratedRed:0.722 green:0.835 blue:0.957 alpha:1.0];
        case 5:  // Menu
            return [NSColor colorWithCalibratedWhite:0.965 alpha:1.0];
        case 6:  // Popover
            return [NSColor colorWithCalibratedWhite:0.96  alpha:1.0];
        case 7:  // Sidebar -- Mavericks Finder sidebar bluish-gray
            return [NSColor colorWithCalibratedRed:227.0/255.0
                                             green:231.0/255.0
                                              blue:237.0/255.0
                                             alpha:1.0];
        case 8:  // MediumLight
            return [NSColor colorWithCalibratedWhite:0.92  alpha:1.0];
        case 3:  // Titlebar -- Mavericks titlebar gray
            return [NSColor colorWithCalibratedWhite:0.86  alpha:1.0];
        case 0:  // AppearanceBased
        case 1:  // Light
        default:
            // Match the sidebar palette: iWork uses VisualEffectView mostly as
            // chrome behind toolbars/rulers/comments where the sidebar color
            // reads correctly. A plain near-white would clash with the
            // surrounding sidebar.
            return [NSColor colorWithCalibratedRed:227.0/255.0
                                             green:231.0/255.0
                                              blue:237.0/255.0
                                             alpha:1.0];
    }
}

@implementation NSVisualEffectView {
    NSInteger _material;
    NSInteger _blendingMode;
    NSInteger _state;
    NSInteger _interiorBackgroundStyle;
    NSImage *_maskImage;
    BOOL _emphasized;
}
@synthesize material = _material;
@synthesize blendingMode = _blendingMode;
@synthesize state = _state;
@synthesize interiorBackgroundStyle = _interiorBackgroundStyle;
@synthesize maskImage = _maskImage;
@synthesize emphasized = _emphasized;

- (void)setMaterial:(NSInteger)m {
    if (_material == m) return;
    _material = m;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    [kpf_color_for_vfx_material(_material) set];
    NSRectFill(dirty);
}
@end

// ----- KNMacHUDBackgroundView: rounded HUD fill ---------------------------
// KNMacHUDBackgroundView : NSVisualEffectView overrides -wantsUpdateLayer
// (YES) and -updateLayer, expecting Yosemite's NSVisualEffectView blur
// compositor to underlay a dark translucent panel (e.g. Presenter Display's
// "Customize Options" floating window). On Mavericks there's no blur and
// our VFX shim's solid -drawRect: is bypassed because AppKit routes
// drawing through -updateLayer when wantsUpdateLayer is YES -- the user
// sees a fully see-through window.
//
// Two patches on the subclass only ([[objc-swizzle-subclass]]):
//   1. wantsUpdateLayer -> NO, so AppKit falls back to drawRect:.
//   2. add a drawRect: that paints a rounded-rect dark fill. Inheriting
//      the VFX shim's NSRectFill would lose the corner rounding.
static BOOL kpf_HUDBackground_wantsUpdateLayer(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static void kpf_HUDBackground_drawRect(NSView *self, SEL _cmd, NSRect dirty) {
    (void)_cmd; (void)dirty;
    NSRect b = [self bounds];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:b xRadius:6.0 yRadius:6.0];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.85] setFill];
    [path fill];
}

__attribute__((constructor))
static void kpf_install_HUDBackground_draw(void) {
    Class c = NSClassFromString(@"KNMacHUDBackgroundView");
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(wantsUpdateLayer));
    if (m) method_setImplementation(m, (IMP)kpf_HUDBackground_wantsUpdateLayer);
    char enc[64];
    snprintf(enc, sizeof(enc), "v@:%s", @encode(NSRect));
    class_addMethod(c, @selector(drawRect:), (IMP)kpf_HUDBackground_drawRect, enc);
}

// NSStackView: 10.9 actually (in some SDKs), but defensively stub if missing.
// We only define if not already provided by the runtime.
__attribute__((constructor))
static void kpf_register_optional_stubs(void) {
    // Nothing dynamic for now; symbol-level definitions above handle it.
}

// ----- NSFont system font with weight (10.10) ------------------------------

@interface NSFont (KPFYosemiteFontWeight)
@end

@implementation NSFont (KPFYosemiteFontWeight)
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight {
    // Map our shimmed NSFontWeight* values onto the closest 10.9 NSFontManager weights.
    // Bold (>= 0.3) -> boldSystemFont; otherwise standard system font.
    if (weight >= 0.3) {
        return [NSFont boldSystemFontOfSize:fontSize];
    }
    return [NSFont systemFontOfSize:fontSize];
}
+ (NSFont *)monospacedDigitSystemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight {
    return [self systemFontOfSize:fontSize weight:weight];
}
@end

// ----- NSPressureConfiguration stub (10.10) --------------------------------
// 10.10 Force Touch trackpad config. Method list extracted via:
//   otool -ov /Volumes/Yosemite/.../AppKit | grep -A1 NSPressureConfiguration
// Public ABI: -initWithPressureBehavior:, -pressureBehavior, -set, and
// NSCoding. The ivar layout (one int64 _pressureBehavior at offset 8) is
// preserved so any caller poking _pressureBehavior directly still works.
@interface NSPressureConfiguration : NSObject <NSCoding>
- (instancetype)initWithPressureBehavior:(NSInteger)behavior;
@property(readonly) NSInteger pressureBehavior;
- (void)set;
@end

@implementation NSPressureConfiguration {
    NSInteger _pressureBehavior;
}
- (instancetype)initWithPressureBehavior:(NSInteger)behavior {
    self = [super init];
    if (self) _pressureBehavior = behavior;
    return self;
}
- (NSInteger)pressureBehavior { return _pressureBehavior; }
- (void)set                   { /* no-op: no Force Touch on 10.9 */ }
- (NSString *)description {
    return [NSString stringWithFormat:@"<NSPressureConfiguration %p behavior=%ld>",
            self, (long)_pressureBehavior];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) _pressureBehavior = [coder decodeIntegerForKey:@"_pressureBehavior"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_pressureBehavior forKey:@"_pressureBehavior"];
}
@end

// ----- NSInputFeedbackManager stub (10.10) ---------------------------------
// 10.10 added NSInputFeedbackManager for input-device haptics. Keynote calls
// +defaultPerformer to get a singleton and then sends -performInputFeedback:
// at various input events. A nil-returning singleton with a no-op performer
// keeps Keynote happy.
@interface NSInputFeedbackManager : NSObject
+ (instancetype)defaultPerformer;
- (void)performInputFeedback:(NSInteger)kind performanceTime:(NSInteger)t;
@end
@implementation NSInputFeedbackManager
+ (instancetype)defaultPerformer {
    static NSInputFeedbackManager *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[self alloc] init]; });
    return p;
}
- (void)performInputFeedback:(NSInteger)kind performanceTime:(NSInteger)t {
    (void)kind; (void)t;
}
@end

// ----- NSUserActivity stub (10.10) -----------------------------------------
// 10.10 introduced NSUserActivity for Handoff. Keynote pokes
// -initWithActivityType: and a handful of properties; provide a usable
// no-op implementation so the document-open path completes.
@interface NSUserActivity : NSObject
@property(copy) NSString *activityType;
@property(copy) NSString *title;
@property(copy) NSDictionary *userInfo;
@property(copy) NSURL *webpageURL;
@property(getter=isEligibleForHandoff) BOOL eligibleForHandoff;
@property(getter=isEligibleForSearch)  BOOL eligibleForSearch;
@property(getter=isEligibleForPublicIndexing) BOOL eligibleForPublicIndexing;
@property(getter=isCurrent) BOOL current;
@property(weak) id delegate;
@property BOOL needsSave;
@property(copy) NSSet *requiredUserInfoKeys;
@property(copy) NSArray *keywords;
@property(copy) NSString *targetContentIdentifier;
@property(copy) NSString *persistentIdentifier;
@property(copy) NSDate *expirationDate;
@property BOOL supportsContinuationStreams;
@property(copy) NSArray *referrerURL;
@end

@implementation NSUserActivity {
    NSString *_activityType;
    NSString *_title;
    NSDictionary *_userInfo;
    NSURL *_webpageURL;
}
@synthesize activityType = _activityType;
@synthesize title = _title;
@synthesize userInfo = _userInfo;
@synthesize webpageURL = _webpageURL;
@synthesize eligibleForHandoff;
@synthesize eligibleForSearch;
@synthesize eligibleForPublicIndexing;
@synthesize current;
@synthesize delegate;
@synthesize needsSave;
@synthesize requiredUserInfoKeys;
@synthesize keywords;
@synthesize targetContentIdentifier;
@synthesize persistentIdentifier;
@synthesize expirationDate;
@synthesize supportsContinuationStreams;
@synthesize referrerURL;
- (instancetype)initWithActivityType:(NSString *)type {
    self = [super init];
    if (self) { _activityType = [type copy]; }
    return self;
}
- (void)becomeCurrent          {}
- (void)resignCurrent          {}
- (void)invalidate             {}
- (void)addUserInfoEntriesFromDictionary:(NSDictionary *)d { (void)d; }
@end

// ----- ABRecord.displayName (10.10) ----------------------------------------
@interface ABRecord (KPFYosemiteDisplayName)
@end
@implementation ABRecord (KPFYosemiteDisplayName)
- (NSString *)displayName {
    NSString *first = (NSString *)[self valueForProperty:kABFirstNameProperty];
    NSString *last  = (NSString *)[self valueForProperty:kABLastNameProperty];
    if (first.length && last.length) {
        return [NSString stringWithFormat:@"%@ %@", first, last];
    }
    NSString *org = (NSString *)[self valueForProperty:kABOrganizationProperty];
    return first ?: last ?: org ?: @"";
}
@end

// ----- NSWindow.styleMask: strip NSFullSizeContentViewWindowMask (10.10) --
// Bit 15 (1<<15) is NSFullSizeContentViewWindowMask -- it makes the window's
// contentView extend behind the titlebar for vibrancy effects. 10.9 AppKit
// doesn't recognize the bit but the property does store it, and Keynote
// reads it back to decide how much top inset to leave for the titlebar +
// toolbar overlay. With the bit set, Keynote pins its content split view
// 73pt below the container's top (titlebar 22 + toolbar 38 + padding) --
// on 10.9 that's wasted space because the contentView already starts below
// the toolbar, so it manifests as a large gap above the slide navigator.
//
// Stripping in the getter is enough: AppKit's setter accepts the bit (it
// just sits in the mask as a no-op for layout), and every Keynote read
// goes through the getter.
static IMP kpf_orig_NSWindow_styleMask = NULL;
#define KPF_FULL_SIZE_CONTENT_MASK ((NSUInteger)1 << 15)
static NSUInteger kpf_NSWindow_styleMask(NSWindow *self, SEL _cmd) {
    NSUInteger m = ((NSUInteger(*)(id, SEL))kpf_orig_NSWindow_styleMask)(self, _cmd);
    return m & ~KPF_FULL_SIZE_CONTENT_MASK;
}
__attribute__((constructor))
static void kpf_install_window_mask_strip(void) {
    Method m = class_getInstanceMethod([NSWindow class], @selector(styleMask));
    kpf_orig_NSWindow_styleMask = method_getImplementation(m);
    method_setImplementation(m, (IMP)kpf_NSWindow_styleMask);
}

// ----- NSPopover.appearance ABI shift (10.9 int -> 10.10 NSAppearance *) ---
// On 10.9, NSPopover.appearance is the NSPopoverAppearance enum (an int).
// Keynote was compiled against 10.10 where the type became NSAppearance *,
// so calls to -setAppearance: now arrive with a pointer that 10.9 AppKit
// reinterprets as the int enum -- it raises "Invalid value to setAppearance:".
// Hook the IMP so object args silently no-op; enum args pass through.
// Only hook the setter -- the getter returns the int enum, which 10.9
// AppKit's NSPopoverFrame still reads via the original method; if we
// substituted an NSAppearance pointer there it would be reinterpreted as
// a bogus int and trigger "Unknown popover appearance!" during draw.
static void kpf_popover_setAppearance(id self, SEL _cmd, id value) {
    (void)self; (void)_cmd;
    if (value && [value isKindOfClass:[NSAppearance class]]) {
        return; // 10.10-style appearance object -- nothing to do on 10.9
    }
    // Otherwise this is the legacy int enum coming through the same
    // selector; leave _appearance at its default (0 = Minimal).
}

__attribute__((constructor))
static void kpf_install_popover_shims(void) {
    Class c = [NSPopover class];
    Method m = class_getInstanceMethod(c, @selector(setAppearance:));
    if (m) {
        method_setImplementation(m, (IMP)kpf_popover_setAppearance);
    }
}

// ----- NSAppearance vibrant -> Aqua fallback (10.10) -----------------------
// 10.10 added NSAppearanceNameVibrantDark/Light. On 10.9 those names mean
// nothing to +[NSAppearance appearanceNamed:], which returns nil; then
// -[NSPopover setAppearance:] raises on the nil result. Rather than swizzle
// the lookup, give the constants the *literal value* of NSAppearanceNameAqua
// -- by Apple convention Name-constants equal their own identifier string,
// and a quick test confirms NSAppearanceNameAqua == @"NSAppearanceNameAqua".
// Now Keynote's appearanceNamed:NSAppearanceNameVibrantDark resolves to
// appearanceNamed:@"NSAppearanceNameAqua" on 10.9, which works.
NSString * const NSAppearanceNameVibrantDark  = @"NSAppearanceNameAqua";
NSString * const NSAppearanceNameVibrantLight = @"NSAppearanceNameAqua";

// ----- NSWindowController contentViewController (10.10) -------------------
// 10.10 added -contentViewController on NSWindowController as a passthrough
// to self.window.contentViewController. Keynote queries this during its
// startup chain (probably to detect 10.10 view-controller-driven windows).
// Forward to the window's contentViewController shim we already provide.
@interface NSWindowController (KPFYosemiteContentVC)
@end
@implementation NSWindowController (KPFYosemiteContentVC)
- (id)contentViewController {
    NSWindow *w = [self window];
    if ([w respondsToSelector:@selector(contentViewController)]) {
        return [w performSelector:@selector(contentViewController)];
    }
    return nil;
}
- (void)setContentViewController:(id)c {
    NSWindow *w = [self window];
    if ([w respondsToSelector:@selector(setContentViewController:)]) {
        [w performSelector:@selector(setContentViewController:) withObject:c];
    }
}
@end

// ----- NSColor system colors (10.10 additions) -----------------------------

@interface NSColor (KPFYosemiteColors)
@end

@implementation NSColor (KPFYosemiteColors)
// Label hierarchy: black with descending alpha. The earlier shim used
// -disabledControlTextColor (a medium gray) for every secondary/tertiary
// rank, which made all secondary labels look identical and uniformly
// washed-out. Aqua/Yosemite both use black-with-alpha for the label
// hierarchy because it composites naturally over arbitrary backgrounds.
+ (NSColor *)labelColor             { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.85]; }
+ (NSColor *)secondaryLabelColor    { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.50]; }
+ (NSColor *)tertiaryLabelColor     { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.25]; }
+ (NSColor *)quaternaryLabelColor   { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.10]; }
+ (NSColor *)placeholderTextColor   { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.30]; }

// Separator: hairline-style light gray with low opacity, matches the
// "thin divider" look used in iWork's inspector groupings.
+ (NSColor *)separatorColor         { return [NSColor colorWithCalibratedWhite:0.0 alpha:0.10]; }

// linkColor: the system Aqua link blue (#0066CC-ish) -- pure NSColor.blueColor
// is too saturated for body text. Match what AppKit's textColor uses for
// link attribute styling on 10.9.
+ (NSColor *)linkColor              { return [NSColor colorWithCalibratedRed:0.0  green:0.4  blue:0.8 alpha:1.0]; }

// System "named" colors -- the values Apple shipped with these names in
// 10.10. Softer / less saturated than NSColor.redColor etc., balanced for
// UI accents (badge pills, status dots, tinted glyphs).
+ (NSColor *)systemRedColor         { return [NSColor colorWithCalibratedRed:1.0     green:0.231  blue:0.188  alpha:1.0]; }
+ (NSColor *)systemGreenColor       { return [NSColor colorWithCalibratedRed:0.298   green:0.851  blue:0.392  alpha:1.0]; }
+ (NSColor *)systemBlueColor        { return [NSColor colorWithCalibratedRed:0.0     green:0.478  blue:1.0    alpha:1.0]; }
+ (NSColor *)systemOrangeColor      { return [NSColor colorWithCalibratedRed:1.0     green:0.584  blue:0.0    alpha:1.0]; }
+ (NSColor *)systemYellowColor      { return [NSColor colorWithCalibratedRed:1.0     green:0.800  blue:0.0    alpha:1.0]; }
+ (NSColor *)systemBrownColor       { return [NSColor colorWithCalibratedRed:0.635   green:0.518  blue:0.369  alpha:1.0]; }
+ (NSColor *)systemPinkColor        { return [NSColor colorWithCalibratedRed:1.0     green:0.176  blue:0.333  alpha:1.0]; }
+ (NSColor *)systemPurpleColor      { return [NSColor colorWithCalibratedRed:0.345   green:0.337  blue:0.839  alpha:1.0]; }
+ (NSColor *)systemGrayColor        { return [NSColor colorWithCalibratedRed:0.557   green:0.557  blue:0.576  alpha:1.0]; }
@end

// ----- NSWindow titlebar APIs (10.10) --------------------------------------

@interface NSWindow (KPFYosemiteTitlebar)
@end

@implementation NSWindow (KPFYosemiteTitlebar)
// titleVisibility / titlebarAppearsTransparent: Keynote sets these to the
// 10.10-style "vibrant overlay" values (Hidden / YES) to make its toolbar
// draw over the contentView. On 10.9 the overlay doesn't exist, so reading
// those values back tricks Keynote into reserving 73pt of top space for an
// overlay that isn't there. Accept the setter (so call sites don't crash on
// missing selectors) but always report the legacy values from the getter so
// Keynote's layout falls into the no-overlay branch.
- (NSInteger)titleVisibility                  { return 0; /* NSWindowTitleVisible */ }
- (void)setTitleVisibility:(NSInteger)v       { (void)v; }
- (BOOL)titlebarAppearsTransparent            { return NO; }
- (void)setTitlebarAppearsTransparent:(BOOL)b { (void)b; }
- (NSArray *)titlebarAccessoryViewControllers {
    NSArray *a = kpf_get_obj(self, _cmd);
    return a ?: @[];
}
- (void)addTitlebarAccessoryViewController:(id)c {
    if (!c) return;
    NSMutableArray *arr = kpf_get_obj(self, @selector(titlebarAccessoryViewControllers));
    if (!arr) { arr = [NSMutableArray array]; kpf_set_obj(self, @selector(titlebarAccessoryViewControllers), arr); }
    [arr addObject:c];
}
- (void)removeTitlebarAccessoryViewControllerAtIndex:(NSInteger)i {
    NSMutableArray *arr = kpf_get_obj(self, @selector(titlebarAccessoryViewControllers));
    if (i >= 0 && (NSUInteger)i < arr.count) [arr removeObjectAtIndex:(NSUInteger)i];
}
// contentLayoutRect (10.10): the part of the contentView usable for layout,
// expressed in the contentView's *own* coordinates. On 10.10 with
// NSFullSizeContentViewWindowMask the titlebar sits above part of the
// contentView and the layout rect excludes that overlap; on 10.9 the
// contentView never extends behind the titlebar in the first place, so the
// usable rect is just the contentView's whole bounds.
//
// (An earlier version returned -contentRectForFrameRect:[self frame], which
// is in *screen* coordinates -- Keynote then assigned that to a SplitView
// frame as if it were content-view-relative and the result was a giant top
// gap matching the window's screen y-origin.)
- (NSRect)contentLayoutRect {
    NSView *cv = [self contentView];
    return cv ? [cv bounds] : NSZeroRect;
}
// contentLayoutGuide (10.10) is supposed to be a layout-anchor target
// covering the "below the toolbar" area of the contentView. On 10.10 it's
// a private guide-like object; the public NSLayoutGuide class didn't exist
// until 10.11. Returning nil leaves any constraint of the form
//   view.Top == window.contentLayoutGuide.Top + 0
// with a nil secondItem -- which the autolayout engine collapses to
//   view.Top == 0
// (a self-only constraint that pins the top edge to y=0). In default
// non-flipped NSView coordinates that anchors the view to the BOTTOM of
// its superview, which is why the Pages track-changes bar, Numbers
// inspector, etc. all show up clinging to the wrong edge.
//
// On 10.9 the contentView already excludes the chrome, so its bounds
// rectangle is exactly what 10.10's contentLayoutGuide would resolve to.
// Returning the contentView gives every constraint a sensible target.
- (id)contentLayoutGuide  { return [self contentView]; }
// contentViewController (10.10): the controller that owns the contentView.
// On 10.10 the setter unconditionally installs the controller's -view as
// the window's contentView. On 10.9 we only do that when the *current*
// contentView is a stock NSView -- nothing custom has been set up yet.
// The main TMADocumentWindow gets its KNMacDocumentBackgroundView
// installed programmatically BEFORE the controller is wired, so we leave
// it alone. The KNMacPlaybackWindow goes the other way -- it has no
// contentView pre-set and relies on this auto-install to wire in the
// playback view; without that the window stays a black empty NSView.
- (id)contentViewController                  { return kpf_get_obj(self, _cmd); }
- (void)setContentViewController:(id)c {
    kpf_set_obj(self, @selector(contentViewController), c);
    if (!c || ![c respondsToSelector:@selector(view)]) return;
    NSView *cv = [self contentView];
    if (cv && [cv class] == [NSView class] && cv.subviews.count == 0) {
        NSView *v = [c view];
        if (v && v != cv) [self setContentView:v];
    }
}
- (NSInteger)occlusionState                  { return 1 << 1; /* NSWindowOcclusionStateVisible */ }
@end

// ----- NSLayoutConstraint +activate/+deactivate (10.10) --------------------

@interface NSLayoutConstraint (KPFYosemiteAutolayout)
@end

// Find the lowest common ancestor of two views in the superview chain.
// 10.10's +activateConstraints: handles this internally; AppKit refuses to
// install a constraint on a view that doesn't contain both items.
static NSView *kpf_common_ancestor(NSView *a, NSView *b) {
    if (!a) return b;
    if (!b) return a;
    NSMutableSet *as = [NSMutableSet set];
    for (NSView *v = a; v; v = [v superview]) [as addObject:v];
    for (NSView *v = b; v; v = [v superview]) {
        if ([as containsObject:v]) return v;
    }
    return nil;
}
static NSView *kpf_host_view_for_constraint(NSLayoutConstraint *c) {
    id f = [c firstItem], s = [c secondItem];
    NSView *fv = [f isKindOfClass:[NSView class]] ? (NSView *)f : nil;
    NSView *sv = [s isKindOfClass:[NSView class]] ? (NSView *)s : nil;
    if (fv && sv) return kpf_common_ancestor(fv, sv);
    NSView *only = fv ?: sv;
    return only;
}

@implementation NSLayoutConstraint (KPFYosemiteAutolayout)
+ (void)activateConstraints:(NSArray *)constraints {
    for (NSLayoutConstraint *c in constraints) {
        NSView *host = kpf_host_view_for_constraint(c);
        if (host) [host addConstraint:c];
    }
}
+ (void)deactivateConstraints:(NSArray *)constraints {
    for (NSLayoutConstraint *c in constraints) {
        NSView *host = kpf_host_view_for_constraint(c);
        if (host) [host removeConstraint:c];
    }
}
// -setActive: / -isActive (10.10) -- each constraint can be flipped
// individually. YES adds it to a natural container (first.superview);
// NO removes from wherever it currently is. Backed by associated-object
// storage so the getter round-trips. Pages/Numbers use the instance
// form throughout their inspector setup; Keynote tends to use the +array
// forms.
- (BOOL)isActive {
    return [objc_getAssociatedObject(self, @selector(isActive)) boolValue];
}
- (void)setActive:(BOOL)active {
    NSView *host = kpf_host_view_for_constraint(self);
    if (host) {
        if (active) [host addConstraint:self];
        else        [host removeConstraint:self];
    }
    objc_setAssociatedObject(self, @selector(isActive), @(active),
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

// ----- NSOperation/Queue QualityOfService (10.10) --------------------------

@interface NSOperation (KPFYosemiteQoS)
@end
@implementation NSOperation (KPFYosemiteQoS)
- (NSInteger)qualityOfService             { return kpf_get_int(self, _cmd); }
- (void)setQualityOfService:(NSInteger)q  { kpf_set_int(self, @selector(qualityOfService), q); }
@end

@interface NSOperationQueue (KPFYosemiteQoS)
@end
@implementation NSOperationQueue (KPFYosemiteQoS)
- (NSInteger)qualityOfService             { return kpf_get_int(self, _cmd); }
- (void)setQualityOfService:(NSInteger)q  { kpf_set_int(self, @selector(qualityOfService), q); }
@end

// ----- NSScrollView automaticallyAdjustsContentInsets (10.10) --------------

@interface NSScrollView (KPFYosemiteInsets)
@end
// Fallback: any object can answer -setContentInsets: without crashing.
// Numbers has an NSProxy whose target isn't a real NSScrollView and that
// ends up receiving setContentInsets: -- NSProxy refuses, raises
// "doesNotRecognizeSelector:" and the app dies before showing UI.
//
// IMPORTANT: do NOT also add -contentInsets here. -contentInsets returns
// NSEdgeInsets (a 32-byte struct), so callers compile it with
// objc_msgSend_stret. If a caller's declared return type is id (e.g. a
// proxy that just probes "respondsToSelector:contentInsets" for any
// selector), it'll instead pick plain objc_msgSend -- our stret IMP
// then leaves %rax with the calling convention's hidden-buffer pointer,
// the caller treats that pointer as an autoreleased object, the run
// loop later releases it, and we get the "objc_msgSend selector name:
// release" main-queue crash that showed up across all three apps.
// Keeping just the void setter avoids the stret-vs-non-stret ABI hazard.
@interface NSObject (KPFContentInsetsFallback)
- (void)setContentInsets:(NSEdgeInsets)i;
@end
@implementation NSObject (KPFContentInsetsFallback)
- (void)setContentInsets:(NSEdgeInsets)i { (void)i; }
@end

@implementation NSScrollView (KPFYosemiteInsets)
- (BOOL)automaticallyAdjustsContentInsets             { return kpf_get_bool(self, _cmd); }
- (void)setAutomaticallyAdjustsContentInsets:(BOOL)b  { kpf_set_bool(self, @selector(automaticallyAdjustsContentInsets), b); }
- (NSEdgeInsets)contentInsets                          { return kpf_get_insets(self, _cmd); }
// Drop callers' chrome-accommodation insets on the floor. On Yosemite,
// NSWindow with NSFullSizeContentViewWindowMask makes the contentView
// extend behind the titlebar/toolbar; iWork's
// -p_updateCanvasScrollViewContentInsets pushes a top inset equal to that
// chrome (~73pt) so the document canvas doesn't disappear under it. On
// Mavericks the contentView never extends behind the chrome in the first
// place -- adopting that inset is double-counting and the canvas ends up
// drawing with a giant empty band at the top. Store zero so any later
// read of -contentInsets reports "no chrome to dodge".
- (void)setContentInsets:(NSEdgeInsets)i {
    (void)i;
    NSEdgeInsets zero = {0, 0, 0, 0};
    kpf_set_insets(self, @selector(contentInsets), zero);
}
- (NSEdgeInsets)scrollerInsets                         { return kpf_get_insets(self, _cmd); }
- (void)setScrollerInsets:(NSEdgeInsets)i              { kpf_set_insets(self, @selector(scrollerInsets), i); }
@end

// ----- C constants (10.10 additions) ---------------------------------------

// NSEdgeInsetsZero is exported by Foundation on 10.10+. Provide for flat
// lookup. Type: NSEdgeInsets is a struct of 4 CGFloat.
const struct { CGFloat top, left, bottom, right; } NSEdgeInsetsZero = {0, 0, 0, 0};

// NSFontWeight* constants are 10.10+ CGFloat externs. Values from Apple's
// public NSFontDescriptor.h documentation.
const CGFloat NSFontWeightUltraLight = -0.80;
const CGFloat NSFontWeightThin       = -0.60;
const CGFloat NSFontWeightLight      = -0.40;
const CGFloat NSFontWeightRegular    =  0.00;
const CGFloat NSFontWeightMedium     =  0.23;
const CGFloat NSFontWeightSemibold   =  0.30;
const CGFloat NSFontWeightBold       =  0.40;
const CGFloat NSFontWeightHeavy      =  0.56;
const CGFloat NSFontWeightBlack      =  0.62;

// OSAtomic Increment/Decrement entry points live in stubs/kpf_osatomic.c --
// they conflict with the 10.9 SDK's `__inline static` declarations, so we
// keep them in a separate TU that doesn't include OSAtomic.h.

// ----- NSEdgeInsetsEqual (10.10) -------------------------------------------
BOOL NSEdgeInsetsEqual(NSEdgeInsets a, NSEdgeInsets b) {
    return a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right;
}

// ----- dispatch_queue_attr_make_with_qos_class (10.10) ---------------------
// On 10.9 there's no QoS support; return the passed-in attr unchanged so
// callers get a valid (non-QoS-aware) queue attribute back.
dispatch_queue_attr_t
dispatch_queue_attr_make_with_qos_class(dispatch_queue_attr_t attr,
                                        int qos_class,
                                        int relative_priority) {
    (void)qos_class; (void)relative_priority;
    return attr;
}

// ----- NSViewController 10.10 selectors -------------------------------------
// 10.10 added a true view-controller lifecycle. The most commonly-checked
// selector is -isViewLoaded; provide it by peeking at the (private) _view
// ivar via KVC, falling back to NO if KVC throws.
@interface NSViewController (KPFYosemiteLifecycle)
@end
@implementation NSViewController (KPFYosemiteLifecycle)
- (BOOL)isViewLoaded {
    @try {
        id v = [self valueForKey:@"_view"];
        return v != nil;
    } @catch (id e) { (void)e; return NO; }
}
- (void)viewWillAppear      {}
- (void)viewDidAppear       {}
- (void)viewWillDisappear   {}
- (void)viewDidDisappear    {}
- (void)viewWillLayout      {}
- (void)viewDidLayout       {}
- (NSSize)preferredContentSize                  { return kpf_get_size(self, _cmd); }
- (void)setPreferredContentSize:(NSSize)s       { kpf_set_size(self, @selector(preferredContentSize), s); }
- (CGFloat)preferredMaximumLayoutWidth          { return kpf_get_cgfloat(self, _cmd); }
- (void)setPreferredMaximumLayoutWidth:(CGFloat)w { kpf_set_cgfloat(self, @selector(preferredMaximumLayoutWidth), w); }
- (NSArray *)childViewControllers {
    NSArray *a = kpf_get_obj(self, _cmd);
    return a ?: @[];
}
- (void)addChildViewController:(id)c {
    if (!c) return;
    NSMutableArray *arr = kpf_get_obj(self, @selector(childViewControllers));
    if (!arr) { arr = [NSMutableArray array]; kpf_set_obj(self, @selector(childViewControllers), arr); }
    [arr addObject:c];
    kpf_set_obj(c, @selector(parentViewController), self);
}
- (void)removeFromParentViewController {
    NSViewController *parent = kpf_get_obj(self, @selector(parentViewController));
    NSMutableArray *arr = kpf_get_obj(parent, @selector(childViewControllers));
    [arr removeObject:self];
    kpf_set_obj(self, @selector(parentViewController), nil);
}
- (id)parentViewController                      { return kpf_get_obj(self, _cmd); }
- (id)presentedViewControllers                  { return kpf_get_obj(self, _cmd); }
- (id)presentingViewController                  { return kpf_get_obj(self, _cmd); }
@end

// ----- NSDocument 10.10 selectors -------------------------------------------
// Keynote 6.6.2 expects -userActivity (NSUserActivity *) and -setUserActivity:
// on NSDocument; both were added in 10.10. Provide nil-returning shims so
// Keynote's "track which document is current" plumbing no-ops gracefully.
@interface NSDocument (KPFYosemiteUserActivity)
@end
@implementation NSDocument (KPFYosemiteUserActivity)
- (id)userActivity                 { return kpf_get_obj(self, _cmd); }
- (void)setUserActivity:(id)act    { kpf_set_obj(self, @selector(userActivity), act); }
- (void)restoreUserActivityState:(id)act    { (void)act; }
- (void)updateUserActivityState:(id)act     { (void)act; }
// More 10.10 NSDocument plumbing that Keynote pokes during document open.
// alternateContents is the read/write companion to setAlternateContents:.
- (id)alternateContents                       { return kpf_get_obj(self, _cmd); }
- (void)setAlternateContents:(id)c            { kpf_set_obj(self, @selector(alternateContents), c); }
- (BOOL)isInViewingMode                       { return NO; }
- (id)backupFileURL                           { return nil; }
- (id)browserURL                              { return nil; }
- (BOOL)isEntireFileLoaded                    { return YES; }
- (BOOL)isLocked                              { return NO; }
// fileTypeFromLastRunSavePanel (10.10) is "the type chosen in the most
// recent save panel". Apple's default is nil if no panel has been shown.
// Keynote's TMADocument.writeToURL: asserts when the type is nil, which
// suggests it consults this property directly as the source of truth on
// save -- so fall back to the document's current fileType. Stored value
// (set via setFileTypeFromLastRunSavePanel:) overrides the fallback.
- (id)fileTypeFromLastRunSavePanel {
    id stored = kpf_get_obj(self, _cmd);
    return stored ?: [self fileType];
}
- (void)setFileTypeFromLastRunSavePanel:(id)t {
    kpf_set_obj(self, @selector(fileTypeFromLastRunSavePanel), t);
}
- (id)presentedItemOperationQueue             { return [NSOperationQueue mainQueue]; }
- (id)fileNameExtensionForType:(NSString *)t saveOperation:(NSUInteger)op {
    (void)op;
    return [t pathExtension];
}
@end

// NSResponder also picks up -userActivity / -setUserActivity: on 10.10,
// because NSDocument calls through NSResponder; mirror them so any other
// responder subclass receiving the message succeeds too.
@interface NSResponder (KPFYosemiteUserActivity)
@end
@implementation NSResponder (KPFYosemiteUserActivity)
- (id)userActivity                 { return kpf_get_obj(self, _cmd); }
- (void)setUserActivity:(id)act    { kpf_set_obj(self, @selector(userActivity), act); }
@end

// ----- NSAccessibility{Frame,Point}InView (10.10) --------------------------
// Convert frame/point in `parentView`'s coordinates to the window's coordinates.
// On 10.9 the accessibility machinery uses screen coords; doing the local->window
// conversion is the conservative no-op-equivalent shim.
NSRect NSAccessibilityFrameInView(NSView *parentView, NSRect frame) {
    if (!parentView) return frame;
    return [parentView convertRect:frame toView:nil];
}
NSPoint NSAccessibilityPointInView(NSView *parentView, NSPoint point) {
    if (!parentView) return point;
    return [parentView convertPoint:point toView:nil];
}

// ----- LSCopyApplicationURLsForBundleIdentifier (10.10) --------------------
// The 10.9 equivalent is LSFindApplicationForInfo, which returns at most one
// URL. We wrap it into a single-element CFArrayRef so callers iterating the
// array still find the primary app.
extern OSStatus LSFindApplicationForInfo(OSType inCreator,
                                         CFStringRef inBundleID,
                                         CFStringRef inName,
                                         FSRef *outAppRef,
                                         CFURLRef *outAppURL);
#ifndef kLSUnknownCreator
#define kLSUnknownCreator '\?\?\?\?'
#endif
CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef bundleID,
                                                    CFErrorRef *outError) {
    if (outError) *outError = NULL;
    CFURLRef url = NULL;
    OSStatus s = LSFindApplicationForInfo(kLSUnknownCreator, bundleID, NULL, NULL, &url);
    if (s != noErr || url == NULL) return NULL;
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)&url, 1, &kCFTypeArrayCallBacks);
    CFRelease(url);
    return arr;
}

// ----- CFBundleCopyLocalizedStringForLocalization (10.10) ------------------
// 10.9's CFBundleCopyLocalizedString ignores the explicit `locale` arg; just
// forward to it -- callers that pass a non-default locale will silently get
// the bundle's default localization.
CFStringRef CFBundleCopyLocalizedStringForLocalization(CFBundleRef bundle,
                                                       CFStringRef key,
                                                       CFStringRef value,
                                                       CFStringRef tableName,
                                                       CFStringRef localizationName) {
    (void)localizationName;
    return CFBundleCopyLocalizedString(bundle, key, value, tableName);
}

// ----- ASL iteration helpers (10.10) ---------------------------------------
// asl_next/release operate on the opaque asl_object_t cursor returned by
// asl_search on 10.10. On 10.9 the corresponding type is aslresponse and the
// per-message access is asl_next() with a different signature, or by index.
// For correctness in absence of a real implementation, return NULL/no-op --
// Keynote uses these for log retrieval which is non-critical.
void *asl_next(void *obj)    { (void)obj; return NULL; }
void  asl_release(void *obj) { (void)obj; }

// ----- xattr_name_* / xattr_preserve_for_intent (10.10) --------------------
// These are helpers for the new flag-encoded xattr namespaces. On 10.9 only
// plain xattr names exist, so identity mappings are correct.
char *xattr_name_with_flags(const char *name, int flags) {
    (void)flags;
    return name ? strdup(name) : NULL;
}
char *xattr_name_without_flags(const char *name) {
    return name ? strdup(name) : NULL;
}
int xattr_preserve_for_intent(const char *name, int intent) {
    (void)name; (void)intent;
    return 1; // "preserve" -- the conservative default on copies
}

// ----- os_activity / os_trace (10.10) --------------------------------------
// Both are tracing breadcrumbs; no-oping them is safe.
void _os_activity_set_breadcrumb(const char *name) { (void)name; }
void _os_trace_with_buffer(void *unused1, const char *fmt,
                            unsigned long arg, const void *buf, size_t buflen,
                            void *unused2) {
    (void)unused1; (void)fmt; (void)arg; (void)buf; (void)buflen; (void)unused2;
}
// os_activity_initiate(label, flags, block) creates a new activity scope.
// On 10.9 we have no activity tracing, so just invoke the block in-place
// -- the caller's intended work still runs.
void _os_activity_initiate(const char *label, uint32_t flags, void (^block)(void)) {
    (void)label; (void)flags;
    if (block) block();
}

// ----- TMAExportFormatChooserItemView click-to-select ---------------------
// The Export sheet's format strip (PDF/PowerPoint/QuickTime/HTML/Images/
// Keynote'09) is an NSCollectionView subclass (TMAExportFormatChooserView)
// with TMAExportFormatChooserItemView per cell. Neither class declares
// -mouseDown:, and on 10.9 NSCollectionView doesn't auto-translate item
// clicks into selection changes -- arrows still work because the chooser
// implements -keyDown: itself, but clicks land on the item view and die.
//
// Add a -mouseDown: to the item view: walk up to the parent NSCollection-
// View, compute the clicked item's index by sorted x position among same-
// class siblings, and push it through -setSelectionIndexes:. The chooser's
// keyDown path uses the same setter, so this mirrors the keyboard behavior
// exactly (KVO drives the controller's selectedIndex and the rest of the
// export UI).
static void kpf_TMAExportItemView_mouseDown(NSView *self, SEL _cmd, NSEvent *ev) {
    (void)_cmd; (void)ev;
    NSView *p = self.superview;
    while (p && ![p isKindOfClass:[NSCollectionView class]]) p = p.superview;
    if (!p) return;
    NSCollectionView *cv = (NSCollectionView *)p;

    Class sCls = [self class];
    NSArray *sorted = [cv.subviews sortedArrayUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger idx = NSNotFound, n = 0;
    for (NSView *v in sorted) {
        if (![v isKindOfClass:sCls]) continue;
        if (v == self) { idx = n; break; }
        n++;
    }
    if (idx == NSNotFound) return;
    [cv setSelectionIndexes:[NSIndexSet indexSetWithIndex:idx]];
}

__attribute__((constructor))
static void kpf_install_TMAExportItemView_mouseDown(void) {
    Class c = NSClassFromString(@"TMAExportFormatChooserItemView");
    if (!c) return;
    SEL sel = @selector(mouseDown:);
    char enc[64];
    snprintf(enc, sizeof(enc), "v@:%s", @encode(NSEvent *));
    class_addMethod(c, sel, (IMP)kpf_TMAExportItemView_mouseDown, enc);
}

// ----- One-shot method-list dump for chooser introspection ----------------
__attribute__((constructor))
static void kpf_dump_chooser_methods_once(void) {
    if (!getenv("KPF_DUMP_CHOOSER")) return;
    const char *names[] = {
        "TMAExportFormatChooserItemView",
        "TMAExportFormatChooserView",
        "TMAExportFormatChooserViewController",
        NULL,
    };
    for (int i = 0; names[i]; i++) {
        Class c = NSClassFromString([NSString stringWithUTF8String:names[i]]);
        if (!c) { NSLog(@"KPF/CHOOSER %s: NULL", names[i]); continue; }
        NSLog(@"KPF/CHOOSER %s super=%s", names[i], class_getName(class_getSuperclass(c)));
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int j = 0; j < n; j++) {
            NSLog(@"KPF/CHOOSER   -%s", sel_getName(method_getName(ms[j])));
        }
        if (ms) free(ms);
    }
}

// ----- NSTextField label-style hit-test pass-through ----------------------
// Yosemite-era iWork wraps clickable cells (e.g. each segment of
// TMAExportFormatChooserView's PDF/PowerPoint/QuickTime/HTML/Images/
// Keynote'09 strip) in plain views whose only child is a non-editable,
// non-selectable NSTextField label. 10.10 NSTextField passes mouse
// events through when configured as a "label" so the click reaches the
// parent (TMAExportFormatChooserItemView) which then runs the selection
// action. 10.9 NSTextField swallows the click, so the segment never
// changes. Event trace confirmed: hit=<NSTextField>, firstResp stayed
// pinned to TMAExportFormatChooserView, no selection update.
//
// Override -hitTest: on NSTextField so label-style fields (editable=NO
// AND selectable=NO) return nil and AppKit's hit walk continues to the
// parent. Editable / selectable fields keep their normal behavior.
static IMP kpf_orig_NSTextField_hitTest = NULL;
static NSView *kpf_NSTextField_hitTest(NSTextField *self, SEL _cmd, NSPoint p) {
    if (![self isEditable] && ![self isSelectable]) {
        return nil;
    }
    return ((NSView *(*)(id, SEL, NSPoint))kpf_orig_NSTextField_hitTest)(self, _cmd, p);
}

__attribute__((constructor))
static void kpf_install_textfield_label_passthrough(void) {
    Class c = [NSTextField class];
    SEL sel = @selector(hitTest:);
    // Capture the inherited NSView IMP for super-style forwarding (only
    // used for editable/selectable fields).
    kpf_orig_NSTextField_hitTest = class_getMethodImplementation(c, sel);
    char enc[64];
    snprintf(enc, sizeof(enc), "@@:%s", @encode(NSPoint));
    if (!class_addMethod(c, sel, (IMP)kpf_NSTextField_hitTest, enc)) {
        // NSTextField already declares its own -hitTest: -- safe to swizzle
        // in place; method_setImplementation here targets NSTextField, not
        // the inherited NSView Method ([[objc-swizzle-subclass]]).
        Method m = class_getInstanceMethod(c, sel);
        kpf_orig_NSTextField_hitTest = method_getImplementation(m);
        method_setImplementation(m, (IMP)kpf_NSTextField_hitTest);
    }
}

// ----- AHLookupAnchor interpose (Help > Keyboard Shortcuts crash) ---------
// Keynote's -[TMAApplicationDelegate showKeyboardShortcuts:] calls
// AHLookupAnchor(bookName, "keyboardShortcutAPDID") to verify the help
// anchor exists, then opens Help Viewer to it. The anchor exists in the
// Yosemite-format help bundle Keynote 6.6 ships, but the Mavericks Help
// system can't resolve it -- AHLookupAnchor returns non-zero, Keynote
// raises an NSException ("AHLookupAnchor failed"), and the app crashes.
//
// Pretend success: the lookup verification stops failing and Keynote
// proceeds to open Help Viewer. The Viewer may still not render the
// keyboard-shortcuts page correctly on Mavericks, but the click no
// longer crashes the app.
extern int32_t AHLookupAnchor(CFStringRef bookName, CFStringRef anchor);

static int32_t kpf_AHLookupAnchor(CFStringRef bookName, CFStringRef anchor) {
    int32_t r = AHLookupAnchor(bookName, anchor);
    if (r != 0) {
        NSLog(@"KPF: suppressing AHLookupAnchor failure (book=%@ anchor=%@ err=%d)",
              (__bridge NSString *)bookName, (__bridge NSString *)anchor, r);
        return 0;
    }
    return r;
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} kpf_interpose_AHLookupAnchor __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&kpf_AHLookupAnchor,
    (const void *)&AHLookupAnchor,
};

// ----- TSDGLLayer setMaximumDrawableCount: (Trace build animation) ---------
// Keynote's Trace build code does [glLayer setMaximumDrawableCount:N], a
// CAMetalLayer API introduced in 10.11. TSDGLLayer isn't a CAMetalLayer and
// the parent chain on 10.9 doesn't respond, so the selector goes unrecognized
// and we crash. The value just bounds the drawable pool; with TSDGLLayer
// backed by CAOpenGLLayer there's nothing meaningful to do, so a no-op
// setter is enough to keep the build from throwing.
static void kpf_TSDGLLayer_setMaximumDrawableCount(id self, SEL _cmd, NSUInteger n) {
    (void)self; (void)_cmd; (void)n;
}

__attribute__((constructor))
static void kpf_install_TSDGLLayer_shim(void) {
    Class cls = NSClassFromString(@"TSDGLLayer");
    if (!cls) return;
    SEL sel = @selector(setMaximumDrawableCount:);
    char enc[64];
    snprintf(enc, sizeof(enc), "v@:%s", @encode(NSUInteger));
    // class_addMethod only installs if cls doesn't already have its own IMP;
    // if it does, we leave it alone -- this is purely a backfill.
    class_addMethod(cls, sel, (IMP)kpf_TSDGLLayer_setMaximumDrawableCount, enc);
}

#pragma clang diagnostic pop
