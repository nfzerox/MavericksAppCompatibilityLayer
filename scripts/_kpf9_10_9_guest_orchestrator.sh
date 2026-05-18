#!/bin/bash
# _kpf9_10_9_guest_orchestrator.sh -- runs on the Mavericks guest.
#
# Patches Keynote 9 in place using guest-side tools. setup_keynote9_10_9.sh
# pushes this script (plus the Python tools) and invokes it via SSH.
#
# Expectations:
#   - $HOME/UnmodifiedApps/Keynote9.app exists (pristine source).
#   - $HOME/kpf_build/dlcheck       built (tools/dlcheck.c).
#   - $HOME/kpf_build/kpf_stubs.dylib built.
#   - $HOME/kpf_build/tools/        contains the Python tools.
#   - /Volumes/Yosemite/...         mounted (for the CoreUI side-load).
#   - /usr/local/bin/python3        installed (Python 3.x).

set -euo pipefail

APP=Keynote9
PRISTINE=$HOME/UnmodifiedApps/$APP.app
DST=$HOME/$APP.app

TOOLS=$HOME/kpf_build/tools
DLCHECK=$HOME/kpf_build/dlcheck
KPF_DYLIB=$HOME/kpf_build/kpf_stubs.dylib
COREUI_SRC=/Volumes/Yosemite/System/Library/PrivateFrameworks/CoreUI.framework
PY=/usr/local/bin/python3

INSERT_PATH='@executable_path/../Frameworks/kpf_stubs.dylib'
COREUI_INJECT='@executable_path/../Frameworks/CoreUI.framework/Versions/A/CoreUI'

[ -d "$PRISTINE" ]   || { echo "missing pristine $PRISTINE"; exit 1; }
[ -x "$DLCHECK" ]    || { echo "missing dlcheck $DLCHECK"; exit 1; }
[ -f "$KPF_DYLIB" ]  || { echo "missing kpf_stubs.dylib $KPF_DYLIB"; exit 1; }
[ -x "$PY" ]         || { echo "missing python3 $PY"; exit 1; }

echo "==> [$APP] kill running, copy pristine"
pkill -9 Keynote 2>/dev/null || true
rm -rf "$DST"
cp -R "$PRISTINE" "$DST"

echo "==> [$APP] enumerate Mach-O binaries (main + bundled frameworks + XPC services)"
# Enumerate by known path patterns instead of file-by-file `file` probes
# (too slow over a several-thousand-file bundle):
#   - Contents/MacOS/Keynote
#   - Contents/Frameworks/*.framework/Versions/A/<name>
#   - Contents/XPCServices/.../Contents/MacOS/<name>   (recursive `find` for XPCs)
# Skips libswift*.dylib (back-deployed by Apple, already min=10.9).
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
  echo "==> [$base] patch_min_version"
  "$PY" "$TOOLS/patch_min_version.py" --min 10.9 "$bin" | sed 's/^/    /'

  echo "==> [$base] diff_imports (local dlcheck)"
  manifest=/tmp/k9_${base}.manifest.json
  "$PY" "$TOOLS/diff_imports.py" "$bin" --dlcheck "$DLCHECK" > "$manifest" 2>/tmp/k9_${base}.diff.err || {
    echo "    diff_imports failed; err tail:"; tail -10 /tmp/k9_${base}.diff.err; exit 1; }
  "$PY" -c "
import json, sys
m = json.load(open('$manifest'))
print('    libs_missing={}, symbols_missing={}'.format(len(m['missing_libraries']), len(m['missing_symbols'])))"

  # Every binary gets kpf_stubs as a dep via @executable_path/../Frameworks
  # -- for the main app binary that resolves to <bundle>/Contents/Frameworks,
  # for XPC services it resolves to <xpc.xpc>/Contents/Frameworks. We
  # later drop a copy of kpf_stubs.dylib into each Frameworks dir so the
  # path resolves identically everywhere.
  inject="--inject-dylib $INSERT_PATH"
  if [ "$bin" = "$DST/Contents/MacOS/Keynote" ]; then
    inject="$inject --inject-dylib $COREUI_INJECT"
  fi
  echo "==> [$base] patch_surgical (+inject)"
  "$PY" "$TOOLS/patch_surgical.py" "$bin" "$manifest" --out "$bin.patched" $inject 2>&1 | tail -3 | sed 's/^/    /'
  mv "$bin.patched" "$bin"
done

echo
echo "==> [$APP] install kpf_stubs.dylib + Yosemite CoreUI"
FW="$DST/Contents/Frameworks"
cp "$KPF_DYLIB" "$FW/kpf_stubs.dylib"
rm -rf "$FW/CoreUI.framework"
cp -R "$COREUI_SRC" "$FW/CoreUI.framework"

# Each bundled XPC service also needs kpf_stubs.dylib accessible at
# @executable_path/../Frameworks/kpf_stubs.dylib. Drop a copy alongside.
for xpc in $(find "$DST" -name '*.xpc' -type d); do
  xpc_fw="$xpc/Contents/Frameworks"
  mkdir -p "$xpc_fw"
  cp "$KPF_DYLIB" "$xpc_fw/kpf_stubs.dylib"
done

echo "==> [$APP] edit Info.plist"
PLIST="$DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 10.9.0' "$PLIST"
/usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $INSERT_PATH" "$PLIST"

echo "==> [$APP] ad-hoc deep sign"
codesign --force --deep --sign - "$DST" 2>&1 | tail -3

echo "==> [$APP] LaunchServices register"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DST" >/dev/null

echo
echo "   $APP.app ready: 'open $DST'"
