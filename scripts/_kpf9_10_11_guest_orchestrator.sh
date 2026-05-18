#!/bin/bash
# _kpf9_10_11_guest_orchestrator.sh -- runs on the 10.11 El Capitan guest.
#
# Patches Keynote 9 in place for 10.11 deployment. setup_keynote9_10_11.sh
# pushes this script (plus the Python tools + kpf_stubs.dylib + auto stubs)
# and invokes it via SSH.
#
# Differences from the 10.12-targeted orchestrator:
#   - rewrites LC_VERSION_MIN_MACOSX to 10.11 (not 10.12)
#   - LSMinimumSystemVersion set to 10.11.0
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
MIN_VERSION=10.11

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
# Also patch bundled libswift*.dylib: on 10.11 their direct binds to
# 10.12 libSystem symbols (e.g. _os_log_type_enabled) fail at lazy bind
# time because libSystem doesn't ship them yet. patch_surgical flips
# those binds to flat lookup, where kpf_stubs.dylib's implementation
# resolves them.
BINARIES=$(
  echo "$DST/Contents/MacOS/Keynote"
  for fw in "$DST"/Contents/Frameworks/*.framework; do
    name=$(basename "$fw" .framework)
    [ -f "$fw/Versions/A/$name" ] && echo "$fw/Versions/A/$name"
  done
  find "$DST/Contents/Frameworks" -maxdepth 1 -name 'libswift*.dylib' -type f 2>/dev/null
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
# Strip pristine entitlements; CloudKit's runtime check is bypassed in
# kpf_stubs_keynote9_10_11.m via a swizzle on +[CKContainer containerWithIdentifier:].
codesign --force --deep --sign - "$DST" 2>&1 | tail -3

echo "==> [$APP] LaunchServices register"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DST" >/dev/null

echo
echo "   $APP.app ready: 'open $DST'"
