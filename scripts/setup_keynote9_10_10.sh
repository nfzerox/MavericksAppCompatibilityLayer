#!/bin/bash
# setup_keynote9_10_10.sh [user@host]
#
# Host wrapper. Pushes Python tools + kpf_stubs sources to the 10.10 Yosemite
# OS X guest, classifies the missing-symbol set against the 10.13 SDK
# headers (via the Xcode install on /Volumes/HighSierra), builds
# kpf_stubs.dylib there, runs the guest-side orchestrator that patches
# Keynote9.app for 10.10 deployment.
#
# Host resolution: explicit user@host arg, else $MAV_HOST, else first
# line of ~/.config/mavericks-app-compat/host. See scripts/_resolve_host.sh.

set -euo pipefail

echo "############################################################" >&2
echo "# WARNING: the 10.10 Keynote 9.1 port is BROKEN / work-in-  #" >&2
echo "# progress. Static-init heap corruption aborts before the   #" >&2
echo "# main window appears. Use the 10.9 iWork 2015 installer or #" >&2
echo "# the 10.11 Keynote 9 port instead. This script exists for  #" >&2
echo "# research / contributors who want to dig further.          #" >&2
echo "############################################################" >&2

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${1:-}") || exit 1
ROOT=$(dirname "$DIR")
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

echo "==> ensure ~/kpf_build/tools on guest"
"$SSH" "$HOST" 'mkdir -p ~/kpf_build/tools'

echo "==> push python tools"
"$SCP" "$ROOT"/tools/{patch_min_version.py,patch_surgical.py,diff_imports.py,macho_binds.py,aggregate_manifests.py,classify_symbols.py,gen_stubs.py,dlcheck.c} \
  "$HOST:kpf_build/tools/"

echo "==> push stubs + manual symbols + force-missing list"
"$SCP" "$ROOT/stubs/kpf_stubs_keynote9_10_10.m" "$HOST:kpf_build/kpf_stubs.m"
"$SCP" "$ROOT/stubs/manual_symbols_keynote9_10_10.txt" "$HOST:kpf_build/manual_symbols.txt"
"$SCP" "$ROOT/stubs/force_missing_keynote9_10_10.txt" "$HOST:kpf_build/force_missing.txt"

echo "==> push orchestrator"
"$SCP" "$ROOT/scripts/_kpf9_10_10_guest_orchestrator.sh" "$HOST:kpf_build/orchestrator.sh"

echo "==> build dlcheck on guest"
"$SSH" "$HOST" 'cd ~/kpf_build/tools && clang -O2 dlcheck.c -ldl -o ../dlcheck && ls -la ../dlcheck'

echo "==> first dlcheck/diff_imports pass for every binary -> manifests"
"$SSH" "$HOST" 'set -e
PY=/usr/local/bin/python3
APP=$HOME/UnmodifiedApps/Keynote9.app
BINS=$(
  echo "$APP/Contents/MacOS/Keynote"
  for fw in "$APP"/Contents/Frameworks/*.framework; do
    name=$(basename "$fw" .framework)
    [ -f "$fw/Versions/A/$name" ] && echo "$fw/Versions/A/$name"
  done
  find "$APP" -path "*/XPCServices/*.xpc/Contents/MacOS/*" -type f 2>/dev/null
)
cd ~/kpf_build
rm -f /tmp/k9_*.manifest.json
for bin in $BINS; do
  base=$(basename "$bin")
  $PY tools/diff_imports.py "$bin" --dlcheck ./dlcheck \
        --force-missing $HOME/kpf_build/force_missing.txt \
        > /tmp/k9_${base}.manifest.json 2>/dev/null
done
echo "  $(ls /tmp/k9_*.manifest.json | wc -l | tr -d " ") manifests written"'

echo "==> aggregate + classify + gen auto stubs on guest (10.13 SDK via HighSierra Xcode)"
"$SSH" "$HOST" 'set -e
PY=/usr/local/bin/python3
SDK=/Volumes/HighSierra/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk
ROOTFS=/Volumes/HighSierra
cd ~/kpf_build
$PY tools/aggregate_manifests.py /tmp/k9_*.manifest.json --out /tmp/k9_all.manifest.json
KPF_SDK=$SDK KPF_ROOTFS=$ROOTFS KPF_PP_CACHE=/tmp/k9_sdk.pp.m \
  $PY tools/classify_symbols.py /tmp/k9_all.manifest.json > /tmp/k9_all.classified.json
$PY tools/gen_stubs.py /tmp/k9_all.classified.json \
  --out kpf_auto_stubs.m --skip manual_symbols.txt 2>&1 | head -40'

echo "==> build kpf_stubs.dylib on guest (10.10 deployment target)"
"$SSH" "$HOST" 'cd ~/kpf_build && clang \
    -mmacosx-version-min=10.10 -fobjc-arc -Wall -O0 -g \
    -dynamiclib \
    -framework Foundation -framework AppKit \
    -install_name @rpath/kpf_stubs.dylib \
    -o kpf_stubs.dylib \
    kpf_stubs.m kpf_auto_stubs.m \
  && ls -la kpf_stubs.dylib'

echo "==> run guest orchestrator"
"$SSH" "$HOST" 'chmod +x ~/kpf_build/orchestrator.sh && ~/kpf_build/orchestrator.sh'

echo
echo "==> done. Try: ssh $HOST open ~/Keynote9.app"
