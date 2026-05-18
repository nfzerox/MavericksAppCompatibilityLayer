---
name: reference-kpf-ssh
description: Mavericks SSH (MavericksAppCompatibilityLayer) — wrappers and pitfalls for talking to <mav-host> (OpenSSH 6.2 daemon)
metadata: 
  node_type: memory
  type: reference
---

When working on `<this repo>`, the target host is `<user>@<mav-host>` running Mavericks 10.9.5 with OpenSSH 6.2. Pre-built wrappers:

- `scripts/ssh_wrap.sh` and `scripts/scp_wrap.sh` — sshpass + legacy crypto + ControlMaster.
- Same wrappers also live at `/tmp/mav_ssh.sh` / `/tmp/mav_scp.sh` from earlier sessions; just `cp scripts/*.sh /tmp/` if missing.

Password is at `~/.config/mavericks-app-compat/pass` (`<password>`).

**Required SSH options** (OpenSSH 6.2 doesn't speak modern KEX/host-key/cipher):
- `HostKeyAlgorithms=+ssh-rsa`
- `PubkeyAcceptedAlgorithms=+ssh-rsa`
- `KexAlgorithms=diffie-hellman-group14-sha1`
- `Ciphers=aes128-ctr`
- `MACs=hmac-sha1`

**ControlMaster** — Mavericks's sshd throttles rapid re-auth (intermittent "Permission denied (publickey,keyboard-interactive)" if you don't multiplex). Use:
- `ControlMaster=auto`, `ControlPath=/tmp/macl-ssh/%C` (NOT `$TMPDIR` — macOS's TMPDIR path overflows sockaddr_un's 104-byte limit), `ControlPersist=300`.

**scp gotcha** — pass `-O` on macOS scp 9.x+. Without it, the modern client uses sftp subsystem, which the old server rejects with the same misleading "Permission denied" message.

To check the Mavericks-side install_name of a system framework or whether a symbol is exported there:
```
ssh_wrap.sh <user>@<mav-host> 'nm -gjUE /System/Library/Frameworks/AppKit.framework/AppKit | grep _NSFontWeight'
ssh_wrap.sh <user>@<mav-host> '/Library/Developer/CommandLineTools/usr/bin/dyldinfo -export /System/Library/Frameworks/AppKit.framework/AppKit | grep ...'
```
