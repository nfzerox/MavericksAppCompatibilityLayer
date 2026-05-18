#!/bin/bash
# hotswap_kpf9_10_12.sh [user@host]
#
# Fast-iterate on the 10.12 Keynote 9 bundle. Pushes the latest
# kpf_stubs_keynote9_10_12.m (and the auto_stubs from the previous setup run),
# rebuilds kpf_stubs.dylib on the guest, drops it into the bundle's
# Frameworks/ and into every nested XPCService's Frameworks/.
#
# Does NOT re-sign. Mavericks/Sierra both accept hot-swapped dylibs in
# an already-ad-hoc-signed bundle without resign as long as the bundle's
# code signature isn't validated by the loader (it isn't for ad-hoc).
#
# Run scripts/setup_keynote9_10_12.sh once before this for the
# patcher / orchestrator first pass; after that this script is enough
# for iteration on stubs.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${1:-}") || exit 1
ROOT=$(dirname "$DIR")
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

"$SCP" "$ROOT/stubs/kpf_stubs_keynote9_10_12.m" "$HOST:kpf_build/kpf_stubs.m"
"$SSH" "$HOST" 'set -e
  cd ~/kpf_build && clang \
    -mmacosx-version-min=10.12 -fobjc-arc -Wall -O0 -g \
    -dynamiclib \
    -framework Foundation -framework AppKit \
    -install_name @rpath/kpf_stubs.dylib \
    -o kpf_stubs.dylib \
    kpf_stubs.m kpf_auto_stubs.m 2>&1 | tail -5
  BUNDLE=$HOME/Keynote9.app
  cp kpf_stubs.dylib "$BUNDLE/Contents/Frameworks/kpf_stubs.dylib"
  for xpc in $(find "$BUNDLE" -name "*.xpc" -type d 2>/dev/null); do
    mkdir -p "$xpc/Contents/Frameworks"
    cp kpf_stubs.dylib "$xpc/Contents/Frameworks/kpf_stubs.dylib"
  done
  echo "kpf_stubs.dylib hot-swapped into bundle + $(find "$BUNDLE" -name "*.xpc" -type d | wc -l | tr -d " ") XPC services"
'
