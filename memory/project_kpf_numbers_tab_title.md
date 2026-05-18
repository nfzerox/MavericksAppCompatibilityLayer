---
name: kpf-numbers-tab-title
description: "WIP — Numbers TNMacTabTitlePassthroughTextField (Sheet 1 label) renders in a faint blue; stash@{0} on main has the latest attempt"
metadata: 
  node_type: memory
  type: project
---

Numbers's tab strip label ("Sheet 1") draws faint on the (227,231,237) tab-strip backdrop (our NSVisualEffectView shim fill). The dump revealed iWork hands the field an `attributedStringValue` whose foreground color is `rgba(0.20,0.47,0.90,1.00)` (a muted blue meant for Yosemite's translucent vibrant backdrop). Both `-textColor` and `cell.textColor` are independently shimmable but ignored when the attributed string carries its own color.

Approaches tried on `stash@{0}`:

1. `+textColor` swizzle on the class → ignored (attributed string wins).
2. `-setAttributedStringValue:` swizzle → iWork doesn't go through it (probably sets the cell directly or via `-setObjectValue:`).
3. `-drawRect:` swizzle to rewrite the foreground color before super → first cut used `class_getInstanceMethod` + `method_setImplementation`, which silently retargeted `NSTextField` app-wide ([[objc-swizzle-subclass]] — all `NSToolbar` button labels went blank).

The stash already switches to `class_addMethod` with a captured parent IMP, and also includes dumper improvements (`attrFG`/`cell.text`/`bg` colors per view, and prefer `-title` over `-stringValue` for NSControl subclasses so toolbar buttons don't all print as `"0"` from `NSCell`'s boolean shadow).

**To resume:** `git stash pop` of `stash@{0}` on `main` and verify the drawRect override compiles and actually rewrites the color at draw time. Worth confirming via dump that `attrFG=rgba(0,0,0,0.85)` after the field has been drawn at least once. If still faint, the field may bypass `NSTextField` drawing entirely (custom drawing path) — at that point the lever is in `TNMacTabNavigatorTabView` / `TNMacTabBackgroundView`, not on the textfield class.
