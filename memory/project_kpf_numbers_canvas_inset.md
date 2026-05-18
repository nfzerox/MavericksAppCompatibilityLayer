---
name: kpf-numbers-canvas-inset
description: "WIP — Numbers canvas drawing is offset by Yosemite chrome+tabstrip assumptions; stash@{0} on main has the latest attempt"
metadata: 
  node_type: memory
  type: project
---

In Numbers, iWork's canvas drawing assumes Yosemite's `NSFullSizeContentViewWindowMask` layout: the contentView extends behind the chrome (titlebar + toolbar) and the tab strip ("+ Sheet 1" row) floats over the canvas. They dodge it with `-[NSScrollView setContentInsets:]` (10.10+).

On Mavericks the contentView never extends behind the chrome, so adopting iWork's inset double-counts and leaves the canvas top-row hidden in various ways:

- Stored inset = 101 (chrome 73 + tabstrip 28): canvas drawn 101pt below clipview top — visible 73pt empty band at the top.
- Stored inset = 0: column-letter ruler hides behind the tab strip; alternatively no ruler drawn at all.
- Stored inset = 28 (chrome subtracted): ruler visible, but iWork's second `setContentInsets` call passes our stored-and-read-back value back through and re-subtracts → effectively 0 → ruler hidden, or row 2 stops being visible.

The stash on `stash@{0}` is the most recent combined attempt:

1. **Chrome-subtract setContentInsets** with a *monotonic-max* guard (don't let a later, smaller push clobber what we stored from the first 101 → 28 push).
2. **Frame-shrink scrollview** in the `NSWindowDidUpdateNotification` observer (alongside the existing chrome-zero pass): if a direct-child `NSVisualEffectView` sits at the parent's top edge (height ≤60), pull the sibling `NSScrollView`'s top edge down to the bar's bottom by reducing the scrollview's frame height. (Constraint pinning is NOT usable — Mavericks caps `NSLayoutConstraint.priority` at 1000, raising an exception for `1001`.)

Open issues with the stash:

- Frame shrink ping-pongs: a later layout pass restores the scrollview to full content-view height. Observer fires after each update, but there's a window where the scrollview is full-height. May need a `-setFrame:` swizzle, not just a notification-time fix, to keep it stable.
- Even when both layers hold, the visible result still has some rows hidden — user has described it as "row 2 missing", "rows 2–5 missing", or "internal content inset wrong" depending on combination.
- The actual lever for the canvas's *internal* drawing offset is unclear. `contentInsets` storage is read by *some* iWork code path, but iWork may also cache the value at the first push and use it regardless of later reads. The setter is the only obvious lever; the strings `hasTopInset`, `_canAddUnderTitlebarView`, `p_updateCanvasScrollViewContentInsets`, `contentInsetsDidChangeForScrollView:` are in the Numbers binary and may offer alternative entry points.

**To resume:** `git stash pop` on `main`, then iterate. The native Mavericks Numbers comparison screenshot was at `~/Desktop` on the [[reference-kpf-ssh]] guest.
