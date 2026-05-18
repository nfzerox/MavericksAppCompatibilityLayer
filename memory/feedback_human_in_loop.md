---
name: feedback-human-in-loop
description: "Synthesis of how the human-in-the-loop kept the agent on track during this build. Patterns to repeat and pitfalls to avoid, drawn from the actual commit + conversation history."
metadata:
  type: feedback
---

This is a retrospective for future maintainers — human or agent —
about how the collaboration that built this repo actually worked.
The headline patterns aren't about prompting style or any one
clever trick. They're about *when* the human stepped in and *what
kind* of judgment was load-bearing.

If you (the agent) are working in this repo and finding yourself
spinning, scan this list for the situation that matches yours and
reach for the corresponding human assist.

## Where humans saved real time

### 1. "Go back to commit X" as a debugging primitive

The single most useful course-correction in this project's history
was the human saying *"we had it working at commit 04bb2de5 —
compared to everything at that state, what changed that broke
it?"* The agent had been trying to debug the
`_OSAtomicIncrement32Barrier` crash from first principles, looking
at dyld internals, libSystem re-exports, and weak-import semantics
on Mavericks. The actual answer was "the new installer uses the
older blanket weakener instead of the surgical patcher that
04bb2de5 had wired up." Minutes of `git diff` answered what would
have been hours of dyld spelunking.

**Pattern:** when a regression appears in a project with a
known-good prior state, *diff against the known-good state first*,
debug semantics second. The agent has a bias toward
first-principles reasoning that the human can short-circuit with
"this used to work, so look at what changed." Future agents
working here: keep that question in your back pocket.

### 2. Comparison against the native version

Commit `04bb2de5` ("only splice subclass-own event-handling VCs
into responder chain") is the canonical example of the human as
visual oracle. Symptom: clicks during Keynote playback weren't
advancing slides. The agent could see, from logs, that
`-mouseDown:` was reaching *something* but the window's
slide-advance handler never fired. The human ran the native
Mavericks Keynote 6.2.2 side-by-side, confirmed the same gesture
*did* advance the slide there, and reported back: "shim ON ->
click eaten, shim OFF -> click advances." That A/B was definitive
in a way no amount of log-staring could have been. From there the
fix (don't splice transparent VCs into the responder chain) was
mechanical.

**Pattern:** *the previous, working OS version of the same app*
is the best regression oracle you have. Native Mavericks Keynote
6.2.2 is to this project what a passing test is to a normal
codebase. Use it. If you're guessing at "is this behavior weird
or just how the app always worked?", ask the human to compare
against the native build.

### 3. Reverting a half-finished pivot

Commit `dfd2828` ("revert dlcheck tightening; add per-binary
--force-missing list") is a self-described revert. The agent had
hardened `dlcheck`'s classification (drop `RTLD_DEFAULT`, require
`RTLD_FIRST`, etc.) because that *appeared* to be the cause of a
broader missing-symbol set during the Keynote-9 → 10.10 push. It
wasn't — heap corruption reproduced with both the tightened and
the original dlcheck. Backing the change out and replacing it
with a much narrower, opt-in `--force-missing` list was the right
move.

**Pattern:** when a change you made earlier in a debugging session
turns out not to have caused the improvement (or regression) you
attributed to it, *revert it cleanly* before continuing. Don't
let it sit as ambient context. The cost of carrying a wrong
hypothesis through subsequent commits compounds.

### 4. Tier-based seeding (and the discipline to commit verbatim copies)

Commit `a49978a` ("kpf9-1010: seed 10.10 tier from 10.11 (verbatim
base checkpoint)") and its successor `a5b01fe` ("kpf9-1010: 10.10
Yosemite adjustments to the 10.11 base") show the right rhythm
for the Keynote-9 multi-OS work: copy the working 10.11 stub set
*verbatim* in one commit, then make the 10.10-specific
adjustments in a second commit. That separation makes the
delta auditable in `git log`. Anyone bringing up a new tier later
(say 10.13 → 10.8) should do the same: seed from the nearest
working tier, commit, *then* adjust.

The human enforced this rhythm by asking for it explicitly. The
agent's natural tendency is to combine "seed" and "adjust" into
one big commit because the seed alone looks pointless. It isn't —
it's the diff anchor.

### 5. Naming as a domain call

The renaming pass late in this project (`kpf_stubs.m` →
`kpf_stubs_iwork2015_10_9.m`, `kpf_stubs_1010.m` →
`kpf_stubs_keynote9_10_10.m`, etc.) looks cosmetic but reflects a
real distinction: the 10.9 workflow patches *three apps* of the
**iWork 2015 generation**, while the 10.10/10.11/10.12 work
patches *one app*, **Keynote 9.1 (2019)**. Conflating those under
a single "kpf" prefix made it easy to miss when the agent grabbed
the wrong auto-stubs file (commit `f2421c1` had to fix exactly
this — `kpf_auto_stubs.m` had drifted to the Keynote-9 content
while the Mavericks workflow needed the iWork-2015 content).

The human caught this and renamed first, then refactored. Future
maintainers: file names are load-bearing here. If you find
yourself thinking "let me just have one
`kpf_stubs.m` and decide at build time which target to compile
for", resist. Per-target source files are diff-able; conditional
compilation isn't.

### 6. Personal porting experience as a debugging compass

The human has actually done Mavericks → Yosemite app ports
historically and used that intuition to point the agent at
specific Yosemite-era additions (`NSVisualEffectView`,
`NSViewController`'s expanded lifecycle, `NSLayoutAnchor`) when
the symptom matched those areas. This shortens the search
dramatically. When the agent is staring at "an inspector pane
isn't showing up" and the human says "that's almost certainly
NSVisualEffectView, look at the inspector chrome", the agent can
go directly to the right shim and stop spelunking.

**Pattern:** if the human has actual platform experience for the
gap you're crossing, *exploit it*. Don't politely refuse the
hint. The agent should treat human domain pointers as
high-information priors, not as opinions to be independently
verified.

### 7. Insisting on visual fidelity rather than no-ops

The `NSVisualEffectView` shim is a small but important example.
The agent's default for a missing class is "no-op subclass of
NSObject" or "no-op subclass of NSView with `drawRect:` empty".
The human pushed for "no, draw a per-material opaque color that
matches what Yosemite would actually render here". That's why the
patched Inspector chrome is visually plausible instead of being a
clear rectangle.

**Pattern:** visual shims should preserve *intent*, not just
satisfy the linker. The right default is "what color/shape would
the Yosemite version have drawn here?", picked once and committed
with a comment. Don't return nil. Don't draw nothing.

### 8. Catching expensive-by-default tracing

Several tracing call sites in the dylib were originally
unconditional — they logged once per launch (e.g. "view dump
installed" banner) or once per layout pass (e.g. chrome-zeroing).
The human flagged this near the end of release prep: "make sure
the end user version doesn't have expensive tracing code
enabled". The fix was trivial (`if (getenv("KPF_TRACE_*"))`
around the call sites) but the discipline wasn't: by default,
*nothing the stub does on a normal user launch should produce
output*. Anything the agent adds during iteration should either be
gated on first appearance, or gated as part of the commit that
introduces it.

**Pattern:** *every* `NSLog` or `fprintf(stderr, ...)` you add for
debugging should be born inside a `getenv("KPF_TRACE_<NAME>")`
guard. Removing the guard later is hard to remember; adding it up
front is cheap.

### 9. Catching overcommitted claims

At one point the README claimed the agent-human dialog was
"preserved verbatim in `memory/MEMORY.md`". The human asked
flatly: *"was this actually done?"* It hadn't been — the memory
notes are distilled summaries, not transcripts. The line came
out.

**Pattern:** the agent has a stylistic tendency to overstate
when claims sound rhetorically nice. Future humans should
challenge specific factual claims in user-facing docs. Future
agents: every concrete claim in the README is a falsifiable
statement; only make them when you've actually verified the
thing.

### 10. The hot-swap loop

Earlier in the project the iteration loop was full re-patch
(diff_imports, classify, surgical-patch, sign, launch). The human
noticed that for stub-only changes the existing ad-hoc-signed
bundle is happy with a new dylib dropped into
`Contents/Frameworks/` — no re-sign needed on Mavericks. From
that observation, the per-tier `hotswap_*.sh` scripts cut the
iteration loop from minutes to seconds. See
[[feedback-kpf-dylib-hot-swap]].

**Pattern:** before grinding on a slow loop, ask whether the
slow step is actually necessary. The human's instinct here was
"why am I re-signing? what does the kernel actually check?", and
the answer ("it checks page hashes of the main binary, not the
embedded framework's") freed up the fast path.

### 11. Workflow redesign when a primitive is wrong

The crash that motivated commit `f2421c1`'s installer rewrite —
Pages aborting at launch with `_OSAtomicIncrement32Barrier`
missing — was traced to the new installer using
`weaken_dylibs.py` (blanket bind weakener) instead of
`patch_surgical.py` (per-symbol flat redirect). The fix wasn't
"weaken less"; it was "use the right primitive." The human
asked the right question — "compare to 04bb2de5" — which pointed
straight at the workflow regression rather than at any individual
bug.

**Pattern:** when a fix involves walking back a layered chain of
"why did this break", check whether you actually want a different
primitive rather than tuning the wrong one. The blanket
weakener exists; it's just not the right tool for an
ad-hoc-resigned bundle that will be launched directly by
LaunchServices on Mavericks. The surgical patcher is.

### 12. Pushing back on agent over-engineering

The agent has a structural bias toward complex solutions — more
hooks, more swizzles, more code paths — when something simpler
would do. A canonical example: the .car asset-catalog problem on
Mavericks. CoreUI 231.1.0 on Mavericks chokes on the .car format
Yosemite-era iWork ships, with hundreds of "Unsupported pixel
format in CSI" warnings. The agent's instinct was to write
substitution stubs, runtime overrides, format conversion shims.
The human's response was effectively *"just drop in Yosemite's
CoreUI — it ships on Yosemite, copy it into the bundle, load it
first"*. For this specific gap (Mavericks ↔ Yosemite) the
drop-in works completely *unmodified* — Yosemite's CoreUI has
no 10.10-only dependencies that aren't already on 10.9. One
framework copy, one LC_LOAD_DYLIB injection, done. See the
`scripts: bundle Yosemite CoreUI` and `inject CoreUI via
LC_LOAD_DYLIB` commits.

This isn't always a free win. For larger gaps the drop-in is
still the right *starting point*, but you'll have shimming to
do. The parked El Capitan ↔ Sierra CoreUI attempt
(`project_kpf9_sierra_coreui_sideload.md`) shows the cost: Sierra
CoreUI loads fine on El Capitan via `DYLD_FRAMEWORK_PATH`, but
it pulls in `TextureIO.framework` + `libate.dylib` plus a
handful of CG additions (`_kCGColorSpaceExtendedLinearSRGB` /
`_kCGColorSpaceLinearSRGB` / `CGColorSpaceIsWideGamutRGB`).
~60 more shims are needed to satisfy the transitive surface.
We deferred that work — the project's focus is Mavericks — but
it's documented as "exercise to the reader" rather than
abandoned.

Another instance: the dark-on-dark HUD text problem. The agent
sketched a several-hundred-line subtree-walking recolor system
when the actual fix is to intercept `-[NSTextField setTextColor:]`
once, check if the text field is under a `KNMacHUD*` ancestor,
and force the color light. That's roughly twenty lines. The agent
*also* wrote the subtree-walking version (it does extra cleanup
for matrix cells), but the intercept is what carries the load.

**Pattern:** when the agent proposes a complex solution to a
seemingly-hard problem, ask "what's the dumbest thing that
would work?" and try that first. The fancy version is rarely
wrong, but the dumb version is rarely insufficient. Future
agents working here: when a closed-source binary is mis-behaving
because a system framework is too old, see if you can replace
the framework wholesale before rewriting it piece by piece.
"Drop the newer framework in and load it" is a one-line
intervention; "shim each missing method" is a project.

## Where the human stayed out of the way (and that mattered)

A complementary observation: the *boring* mechanical loop —
"crash log says `_NSSomeNewClass`, add an empty stub, rebuild,
relaunch, next crash" — the agent did unsupervised for hours at a
time. That's commit history from `2969785` through `9c07a99` in
broad strokes: each commit is one or two more classes / one or
two more fixes, all driven by crash logs. The human supervised
*direction* and *scope*, not individual stubs.

**Pattern:** humans should not micromanage the inner loop. Pick
the target, agree on the approach, then let the agent grind
until it hits something that needs judgment (a stub returning
the wrong type, a workflow regression, a visual question, a
naming question, a "this isn't actually the right approach"
moment). The agent will surface those naturally if you've made
it clear what kinds of decisions are out of scope without you.

## What's still hard

A few areas where the collaboration was uneven and would benefit
from explicit scaffolding next time:

- **Visual judgment.** The agent can't see the patched app. The
  `KPF_TRACE_*` knobs and the view-dump trigger help, but they
  don't replace "the inspector chrome looks slightly off."
  Future maintainers: lean hard on the View Debugger + class-name
  reporting pattern documented in
  `README.md` ("How the user assists the agent" and the
  "Tracing knobs" tables).
- **Long static-init bisects.** The Keynote-9 → 10.10 heap
  corruption work parked at "the canary is real, not spurious;
  next step is bisect every shim section." The agent has the
  patience but not the framework — there's no single tool that
  isolates "which constructor zeroes this 16 bytes." Future
  attempts at this tier should start by building that tool
  (probably an `MallocStackLoggingNoCompact + lldb` script that
  catches the bad write at its source) before resuming the bisect.

## How to extend this note

Future maintainers: when you and the agent solve something
non-obvious *together* — especially when the human contribution
was a judgment call the agent couldn't have made on its own —
add a numbered section here. Keep the same shape: situation,
what the human did, why it worked, the pattern abstracted out.
The point is not to celebrate individual moments; it's to
build up an inventory of the kinds of decisions worth
soliciting from a human, so future agents know when to ask.
