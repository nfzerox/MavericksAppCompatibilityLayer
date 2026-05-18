---
name: feedback-ssh-efficiency
description: "When SSH'd into a remote host, trust stdout — don't round-trip through remote temp files. Keep commands fast."
metadata: 
  node_type: memory
  type: feedback
---

When working over SSH (and similar remote shells), pipe results directly to stdout rather than writing remote `/tmp/foo.txt` files and re-fetching them. SSH stdout returns to the local tool result reliably; the round-trip is wasted work.

Keep commands tight — don't loop `file` + `otool` over hundreds of binaries when one targeted check suffices. The user watches progress and gets impatient with slow commands.

**Why:** User explicitly called this out while debugging a Mach-O patching task on a Mavericks host — they could see the SSH output directly on the remote and wondered why I was struggling. The honest answer was that my commands were just slow / over-broad.

**How to apply:** For remote inspection: print to stdout, scope commands narrowly (one file, one grep). If a wide scan is genuinely needed, say so explicitly and explain the time cost up front. If the user pastes output from the remote themselves, treat that as authoritative and proceed.
