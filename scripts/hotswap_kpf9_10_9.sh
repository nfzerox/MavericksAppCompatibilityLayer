#!/bin/bash
# hotswap_kpf9_10_9.sh [user@host]
#
# Fast iteration on kpf_stubs.dylib for a Keynote 9 bundle that has
# already been through setup_keynote9_10_9.sh once.
#
# - Pushes the current stubs/kpf_stubs_iwork2015_10_9.m to the guest.
# - Rebuilds kpf_stubs.dylib on the guest (the existing ~/kpf_build/Makefile).
# - Copies the rebuilt dylib into every Frameworks/ folder inside
#   ~/Keynote9.app -- main bundle + each XPC service that has its own
#   Frameworks dir (because @executable_path resolves differently for
#   the XPC binaries).
# - Does NOT re-sign. The first setup_keynote9_10_9.sh run produced an ad-hoc
#   signature on the bundle; hot-swapping a single dylib doesn't require
#   re-signing on Mavericks for ad-hoc-signed bundles.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${1:-}") || exit 1
ROOT=$(dirname "$DIR")
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

"$SCP" "$ROOT/stubs/kpf_stubs_iwork2015_10_9.m" "$HOST:kpf_build/kpf_stubs_iwork2015_10_9.m"
"$SCP" "$ROOT/stubs/kpf_auto_stubs.m" "$HOST:kpf_build/kpf_auto_stubs.m"
"$SSH" "$HOST" 'set -e
  cd ~/kpf_build && make 2>&1 | tail -3
  BUNDLE=$HOME/Keynote9.app
  cp kpf_stubs.dylib "$BUNDLE/Contents/Frameworks/kpf_stubs.dylib"
  for xpc in $(find "$BUNDLE" -name "*.xpc" -type d 2>/dev/null); do
    cp kpf_stubs.dylib "$xpc/Contents/Frameworks/kpf_stubs.dylib"
  done
  echo "kpf_stubs.dylib hot-swapped into bundle + $(find "$BUNDLE" -name "*.xpc" -type d | wc -l | tr -d " ") XPC services"
'
