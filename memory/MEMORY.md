# Memory index

Notes captured during the work that built this repo. Read whichever is
relevant to what you're picking up. Files in this directory are
append-only — if a memory is wrong, append a correction with a date
rather than rewriting history. Links use `[[name]]` (kebab-case slug
from each file's frontmatter); a Markdown alternative `[label](file.md)`
also works for direct file access.

**Looking for the big-picture walkthrough?** The single most
comprehensive document is [`JOURNEY.md`](../JOURNEY.md) at the
repo root — 47 numbered checkpoints from "won't load" to
"Keynote 9.1 on El Capitan", each with the symptom, fix, and an
abstracted lesson. The notes in this directory are
deliberately finer-grained: they cover individual workflows,
pitfalls, and parked threads.

## Cross-cutting feedback (how to work in this repo)

- [Human-in-the-loop retrospective](feedback_human_in_loop.md) —
  start here. Synthesis of the patterns of judgment that
  unstuck the agent during this build: when to revert vs debug,
  when to ask the human for an A/B against the native version,
  when "the dumbest thing" is the right fix, when to push back
  on over-engineering.
- [SSH efficiency](feedback_ssh_efficiency.md) — over SSH to the
  Mavericks box, trust stdout; don't round-trip via remote temp files,
  and keep commands narrow.
- [Commit cadence](feedback_commit_cadence.md) — on long iterative
  loops, commit at each visible-progress checkpoint without being
  asked.
- [KPF dylib hot-swap](feedback_kpf_dylib_hot_swap.md) — after the
  first `setup_iwork.sh` install, just `cp` the rebuilt dylib into
  `Contents/Frameworks`; no resign or re-patch needed.
- [Systematic porting](feedback_systematic_porting.md) — static
  symbol diff beats blanket weakening + crash-driven discovery for
  any OS-back-port project.
- [Objc swizzle on a subclass](feedback_objc_swizzle_subclass.md) —
  `class_getInstanceMethod` walks up the chain; use
  `class_addMethod` first or you silently swizzle the parent.

## Reference

- [Mavericks SSH](reference_kpf_ssh.md) — legacy crypto +
  ControlMaster pattern for `<user>@<mav-host>`; password file location
  and pitfalls.

## Open work / parked threads

- [Numbers canvas inset WIP](project_kpf_numbers_canvas_inset.md) —
  chrome+tabstrip inset double-count; latest attempt stashed.
- [Numbers tab title color WIP](project_kpf_numbers_tab_title.md) —
  TNMacTabTitlePassthroughTextField; attrFG blue overrides
  textColor.

## Keynote-9 feasibility studies (not user-facing)

- [Keynote 9 → 10.11 state](project_kpf9_1011_state.md) —
  mostly-functional 10.11 result; remaining gaps: asset-catalog
  images, NSCollectionView nil-supplementary-view, NSGridView
  shallow API surface.
- [Keynote 9 → 10.10 state](project_kpf9_1010_state.md) — same
  protobuf-init heap canary as the 10.9 attempt; bisect
  candidates listed; `KPF_BYPASS_MALLOC_ABORT=1` confirms the
  canary is genuine.
- [Keynote 9 → Sierra CoreUI sideload](project_kpf9_sierra_coreui_sideload.md)
  — DYLD_FRAMEWORK_PATH overrides even private frameworks, but
  Sierra CoreUI pulls TextureIO + libate which would need ~60 more
  shims. Parked.
