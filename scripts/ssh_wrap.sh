#!/bin/bash
# Wrap ssh with Mavericks-era crypto + sshpass + ControlMaster
# (multiplex a single TCP connection across invocations so we don't
# re-authenticate every call and trip Mavericks's OpenSSH 6.2 throttle).
#
# Set MAV_PASS env var or put password in $HOME/.config/mavericks-app-compat/pass
set -e
pass="${MAV_PASS:-}"
if [ -z "$pass" ] && [ -r "$HOME/.config/mavericks-app-compat/pass" ]; then
  pass=$(cat "$HOME/.config/mavericks-app-compat/pass")
fi
if [ -z "$pass" ]; then
  echo "set MAV_PASS or write password to ~/.config/mavericks-app-compat/pass" >&2
  exit 1
fi
# /tmp not $TMPDIR — macOS's TMPDIR path overflows the 104-byte sockaddr_un limit
mkdir -p /tmp/macl-ssh
chmod 700 /tmp/macl-ssh
exec sshpass -p "$pass" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o ControlMaster=auto \
  -o "ControlPath=/tmp/macl-ssh/%C" \
  -o ControlPersist=300 \
  -o 'HostKeyAlgorithms=+ssh-rsa' \
  -o 'PubkeyAcceptedAlgorithms=+ssh-rsa' \
  -o 'KexAlgorithms=diffie-hellman-group14-sha1' \
  -o 'Ciphers=aes128-ctr' \
  -o 'MACs=hmac-sha1' \
  "$@"
