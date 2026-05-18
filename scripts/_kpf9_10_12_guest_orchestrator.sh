#!/bin/bash
# _kpf9_10_12_guest_orchestrator.sh -- runs on the 10.12 Sierra guest.
#
# Patches Keynote 9 in place for 10.12 deployment. setup_keynote9_10_12.sh
# pushes this script (plus the Python tools + kpf_stubs.dylib + auto stubs)
# and invokes it via SSH.
#
# Differences from the 10.9-targeted _kpf9_10_9_guest_orchestrator.sh:
#   - rewrites LC_VERSION_MIN_MACOSX to 10.12 (not 10.9)
#   - does NOT side-load Yosemite CoreUI (10.12 has CSI builtin)
#   - does NOT inject kpf_stubs as a dep of every TS framework -- the
#     10.13->10.12 delta has no +load-init-order trickery, so kpf_stubs
#     only needs to be loaded once via the main binary
#   - LSMinimumSystemVersion set to 10.12.0
#
# Expectations:
#   - $HOME/UnmodifiedApps/Keynote9.app exists (pristine source).
#   - $HOME/kpf_build/dlcheck         built (tools/dlcheck.c).
#   - $HOME/kpf_build/kpf_stubs.dylib built.
#   - $HOME/kpf_build/tools/          contains the Python tools.
#   - /usr/local/bin/python3          installed.

set -euo pipefail

APP=Keynote9
PRISTINE=$HOME/UnmodifiedApps/$APP.app
DST=$HOME/$APP.app
MIN_VERSION=10.12

TOOLS=$HOME/kpf_build/tools
DLCHECK=$HOME/kpf_build/dlcheck
KPF_DYLIB=$HOME/kpf_build/kpf_stubs.dylib
PY=/usr/local/bin/python3

INSERT_PATH='@executable_path/../Frameworks/kpf_stubs.dylib'

[ -d "$PRISTINE" ]   || { echo "missing pristine $PRISTINE"; exit 1; }
[ -x "$DLCHECK" ]    || { echo "missing dlcheck $DLCHECK"; exit 1; }
[ -f "$KPF_DYLIB" ]  || { echo "missing kpf_stubs.dylib $KPF_DYLIB"; exit 1; }
[ -x "$PY" ]         || { echo "missing python3 $PY"; exit 1; }

echo "==> [$APP] kill running, copy pristine"
pkill -9 Keynote 2>/dev/null || true
rm -rf "$DST"
cp -R "$PRISTINE" "$DST"

echo "==> [$APP] enumerate Mach-O binaries"
BINARIES=$(
  echo "$DST/Contents/MacOS/Keynote"
  for fw in "$DST"/Contents/Frameworks/*.framework; do
    name=$(basename "$fw" .framework)
    [ -f "$fw/Versions/A/$name" ] && echo "$fw/Versions/A/$name"
  done
  find "$DST" -path '*/XPCServices/*.xpc/Contents/MacOS/*' -type f 2>/dev/null
)
echo "    $(echo "$BINARIES" | wc -l | tr -d ' ') binaries"

for bin in $BINARIES; do
  base=$(basename "$bin")
  echo
  echo "==> [$base] patch_min_version --min $MIN_VERSION"
  "$PY" "$TOOLS/patch_min_version.py" --min "$MIN_VERSION" "$bin" | sed 's/^/    /'

  echo "==> [$base] diff_imports"
  manifest=/tmp/k9_${base}.manifest.json
  "$PY" "$TOOLS/diff_imports.py" "$bin" --dlcheck "$DLCHECK" > "$manifest" 2>/tmp/k9_${base}.diff.err || {
    echo "    diff_imports failed; err tail:"; tail -10 /tmp/k9_${base}.diff.err; exit 1; }
  "$PY" -c "
import json
m = json.load(open('$manifest'))
print('    libs_missing={}, symbols_missing={}'.format(len(m['missing_libraries']), len(m['missing_symbols'])))"

  # Only the main binary gets the kpf_stubs LC_LOAD_DYLIB injection.
  # The 10.13->10.12 delta has no +load init order requirement (unlike
  # 10.13->10.9, where __NSArray0__/__NSDictionary0__ had to be live
  # before TS framework static init).
  inject=""
  if [ "$bin" = "$DST/Contents/MacOS/Keynote" ]; then
    inject="--inject-dylib $INSERT_PATH"
  fi
  echo "==> [$base] patch_surgical${inject:+ (+inject)}"
  "$PY" "$TOOLS/patch_surgical.py" "$bin" "$manifest" --out "$bin.patched" $inject 2>&1 | tail -3 | sed 's/^/    /'
  mv "$bin.patched" "$bin"
done

echo
echo "==> [$APP] install kpf_stubs.dylib (main bundle + each XPC service)"
FW="$DST/Contents/Frameworks"
cp "$KPF_DYLIB" "$FW/kpf_stubs.dylib"
for xpc in $(find "$DST" -name '*.xpc' -type d); do
  xpc_fw="$xpc/Contents/Frameworks"
  mkdir -p "$xpc_fw"
  cp "$KPF_DYLIB" "$xpc_fw/kpf_stubs.dylib"
done

echo "==> [$APP] edit Info.plist (LSMinimumSystemVersion = $MIN_VERSION.0)"
PLIST="$DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_VERSION.0" "$PLIST"

echo "==> [$APP] ad-hoc deep sign"
# Do NOT preserve the pristine entitlements: Apple's amfid rejects an
# ad-hoc-signed binary that carries private com.apple.* entitlements
# (the CloudKit / iCloud / ClassKit ones), and the bundle fails to
# launch entirely. Strip them. CloudKit's runtime entitlement check
# is bypassed in kpf_stubs_keynote9_10_12.m via a swizzle on
# -[CKContainer _checkSelfContainerIdentifier].
codesign --force --deep --sign - "$DST" 2>&1 | tail -3

echo "==> [$APP] LaunchServices register"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DST" >/dev/null

echo
echo "   $APP.app ready: 'open $DST'"
