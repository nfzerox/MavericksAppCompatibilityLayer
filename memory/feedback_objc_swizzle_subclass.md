---
name: objc-swizzle-subclass
description: "When swizzling an Objective-C subclass method, class_getInstanceMethod walks to the parent; pair class_addMethod with a saved parent IMP instead, or you swizzle the whole hierarchy"
metadata: 
  node_type: memory
  type: feedback
---

`class_getInstanceMethod(cls, sel)` returns the Method object even when `cls` doesn't override `sel` -- it walks up the inheritance chain. Calling `method_setImplementation` on that result then mutates the parent class's IMP, so every subclass that doesn't override `sel` ends up running the new code.

For [[kpf-numbers-canvas-inset]] / KPF, this bit us when trying to recolor `TNMacTabTitlePassthroughTextField`'s `-drawRect:`: the class itself inherits `drawRect:` from `NSTextField`, so the swizzle silently retargeted *every* `NSTextField` in the process. Symptom from the user: every `NSToolbar` button label disappeared (we'd been clobbering shared drawing while not actually overriding the subclass).

**Why:** the runtime stores Methods on the class that *defines* the IMP, not on every descendant. `class_getInstanceMethod` is convenient but reaches up the chain transparently.

**How to apply:** to swizzle a subclass-only:

```objc
SEL sel = @selector(drawRect:);
IMP parentIMP = class_getMethodImplementation(cls, sel);   // for calling super
char enc[64];
snprintf(enc, sizeof(enc), "v@:%s", @encode(NSRect));
if (!class_addMethod(cls, sel, (IMP)my_override, enc)) {
    // cls really does declare its own -drawRect:; safe to swizzle in place
    Method m = class_getInstanceMethod(cls, sel);
    parentIMP = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_override);
}
```

`class_addMethod` returns NO if the class already has its own IMP for `sel`; only then is a `method_setImplementation` safe (it'll target the class itself, not the parent). The captured `parentIMP` is what you call from the override for super-style forwarding.
