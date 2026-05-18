#!/bin/bash
# build_kpf9_autostubs.sh [user@host]
#
# Builds stubs/kpf_auto_stubs.m from the per-binary manifests that
# setup_keynote9_10_9.sh / _kpf9_10_9_guest_orchestrator.sh left at /tmp/k9_*.manifest.json
# on the guest. Pre-emptively covers every missing-on-Mavericks symbol
# Keynote 9 imports so we don't discover them one crash at a time.
#
# Flow:
#   1. scp guest:/tmp/k9_*.manifest.json -> build/kpf9_manifests/
#   2. tools/aggregate_manifests.py -> build/kpf9_all.manifest.json
#   3. tools/classify_symbols.py (host, with 10.13 SDK + RootFS via env)
#      -> build/kpf9_all.classified.json
#   4. tools/gen_stubs.py -> stubs/kpf_auto_stubs.m
#   5. hotswap_kpf9_10_9.sh -> rebuild kpf_stubs.dylib on guest, drop into bundle
#
# Requires originals/SDK/10.13/Xcode.app/.../MacOSX10.13.sdk and
# originals/RootFS/10.13/System on the host (already in the repo per
# .gitignore).

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${1:-}") || exit 1
ROOT=$(dirname "$DIR")
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

SDK="$ROOT/originals/SDK/10.13/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk"
ROOTFS="$ROOT/originals/RootFS/10.13/System"
[ -d "$SDK" ]    || { echo "missing SDK $SDK"; exit 1; }
[ -d "$ROOTFS" ] || { echo "missing RootFS $ROOTFS"; exit 1; }

WORK="$ROOT/build/kpf9_autostubs"
rm -rf "$WORK" && mkdir -p "$WORK/manifests"

echo "==> pull per-binary manifests from guest"
"$SSH" "$HOST" 'cd /tmp && tar c k9_*.manifest.json' \
  | tar x -C "$WORK/manifests"
echo "    $(ls "$WORK/manifests" | wc -l | tr -d ' ') manifests"

echo "==> aggregate"
python3 "$ROOT/tools/aggregate_manifests.py" \
  "$WORK"/manifests/k9_*.manifest.json \
  --out "$WORK/all.manifest.json"
python3 -c "
import json
m = json.load(open('$WORK/all.manifest.json'))
print('    libs={} symbols={}'.format(len(m['missing_libraries']), len(m['missing_symbols'])))"

echo "==> classify (10.13 SDK headers + 10.13 RootFS dylibs)"
KPF_SDK="$SDK" KPF_ROOTFS="$ROOTFS" \
  python3 "$ROOT/tools/classify_symbols.py" "$WORK/all.manifest.json" \
  > "$WORK/all.classified.json"

python3 -c "
import json
from collections import Counter
m = json.load(open('$WORK/all.classified.json'))
c = Counter(s['kind'] for s in m['missing_symbols'])
for k, n in sorted(c.items()):
    print('    {:18s} {}'.format(k, n))"

echo "==> generate auto stubs"
python3 "$ROOT/tools/gen_stubs.py" "$WORK/all.classified.json" \
  --out "$ROOT/stubs/kpf_auto_stubs.m" \
  --skip "$ROOT/stubs/manual_symbols.txt" 2>/dev/null || {
    # gen_stubs.py emits a warning to stderr listing function symbols; that's
    # informational (functions need hand-written stubs in kpf_stubs.m).
    python3 "$ROOT/tools/gen_stubs.py" "$WORK/all.classified.json" \
      --out "$ROOT/stubs/kpf_auto_stubs.m"
}

echo "==> done; stubs/kpf_auto_stubs.m updated"
echo "    next: scripts/hotswap_kpf9_10_9.sh $HOST"
