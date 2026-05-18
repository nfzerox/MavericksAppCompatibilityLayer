---
name: commit-cadence
description: "For long iterative tasks, commit at each working-checkpoint without waiting to be asked"
metadata: 
  node_type: memory
  type: feedback
---

On long iterative SSH'd-into-guest debugging loops (e.g. [[reference-kpf-ssh]] /
MavericksAppCompatibilityLayer), commit progress at each natural checkpoint -- every time the
behaviour visibly advances (one more crash fixed, one more UI feature reached)
is worth its own commit.

**Why:** the user said "we're at good checkpoints" while reviewing 4+ untracked
files and tens of lines of unrecorded stub work. They want the history to be
recoverable and bisect-able as it accumulates, not bulk-dumped at the end.

**How to apply:**
- Don't ask "should I commit?" mid-loop; just do it when:
  - new tools/files settle into a useful shape,
  - a category of crash transitions from broken to fixed,
  - or before pivoting to a different layer of the problem.
- Per-topic commits (toolchain / scripts / stubs) read better than mixed ones.
- Keep going after the commit -- the loop doesn't pause for it.
