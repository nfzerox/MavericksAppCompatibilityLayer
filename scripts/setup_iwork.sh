#!/bin/bash
# setup_iwork.sh <Keynote|Pages|Numbers> [user@host]
#
# Reproducibly patches a fresh iWork app from the Yosemite volume for 10.9
# launch. Idempotent -- every run starts by re-copying the pristine bundle
# from /Volumes/Yosemite, so prior modifications don't accumulate.
#
# What it does:
#   1. Re-copies ~/<App>.app from /Volumes/Yosemite/Applications/<App>.app
#   2. Saves the pristine binary as <App>.orig (for diff_imports / later
#      re-patching).
#   3. Diff-imports the binary against the live Mavericks dylibs (via the
#      remote dlcheck helper) -> JSON manifest of missing symbols/libs.
#   4. Classifies the missing symbols on the guest (uses 10.10 SDK headers
#      and the Yosemite dylibs from /Volumes/Yosemite for type info).
#   5. Surgical-patches the binary (flips LC_LOAD_DYLIB->WEAK for missing
#      libs and rewrites bind opcodes to BIND_SPECIAL_DYLIB_FLAT_LOOKUP +
#      BIND_SYMBOL_FLAGS_WEAK_IMPORT for missing symbols).
#   6. Embeds the prebuilt kpf_stubs.dylib at Contents/Frameworks/ inside
#      the bundle, so DYLD_INSERT_LIBRARIES can use the relocatable
#      @executable_path/../Frameworks/kpf_stubs.dylib.
#   7. Edits Info.plist: lowers LSMinimumSystemVersion to 10.9.0 and adds
#      the LSEnvironment dict that launchd applies to the process.
#   8. Ad-hoc signs the whole bundle (--deep) so Info.plist seal + binary
#      hashes are consistent.
#   9. Re-registers with LaunchServices so Finder/Dock see the new env.
#
# After this, the app is double-click launchable and ~/kpf_build/launch_iwork.sh
# is no longer required.
set -euo pipefail

APP="${1:?usage: $0 <Keynote|Pages|Numbers> [user@host]}"
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${2:-}") || exit 1
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

DYLIB_ON_GUEST='$HOME/kpf_build/kpf_stubs.dylib'
INSERT_PATH='@executable_path/../Frameworks/kpf_stubs.dylib'
# Yosemite CoreUI (308.6.0) reads the .car asset catalogs Apple shipped with
# Yosemite-era apps; Mavericks's CoreUI (231.1.0) chokes with "Unsupported
# pixel format in CSI" and no icons render. Both share install_name, so a
# DYLD_FRAMEWORK_PATH override pointing inside the bundle lets dyld
# substitute the Yosemite framework for every CoreUI consumer. The
# framework is copied into Contents/Frameworks so the bundle remains
# self-contained -- moving ~/<App>.app to another Mavericks box just works.
YOS_COREUI_SRC='/Volumes/Yosemite/System/Library/PrivateFrameworks/CoreUI.framework'
# CoreUI is forced via an LC_LOAD_DYLIB injected into the app's main
# binary that points at the bundled framework using @executable_path.
# dyld loads our framework before AppKit's; install_name match makes
# AppKit's own LC_LOAD_DYLIB to /System/.../CoreUI resolve to the
# already-loaded Yosemite copy. Self-contained AND relocatable -- 10.9
# dyld DOES expand @executable_path inside LC_LOAD_DYLIB references
# (unlike DYLD_FRAMEWORK_PATH, where it does not).
COREUI_INJECT='@executable_path/../Frameworks/CoreUI.framework/Versions/A/CoreUI'

echo "==> [$APP] kill running, re-copy pristine bundle"
"$SSH" "$HOST" "
  pkill -9 $APP 2>/dev/null || true
  rm -rf ~/${APP}.app
  cp -R /Volumes/Yosemite/Applications/${APP}.app ~/${APP}.app
  cp ~/${APP}.app/Contents/MacOS/${APP} ~/${APP}.app/Contents/MacOS/${APP}.orig
"

echo "==> [$APP] pull binary -> /tmp/${APP}.orig"
"$SCP" "$HOST:Users/${HOST##*@}/${APP}.app/Contents/MacOS/${APP}.orig" "/tmp/${APP}.orig" 2>/dev/null || \
  "$SCP" "$HOST:${APP}.app/Contents/MacOS/${APP}.orig" "/tmp/${APP}.orig"

echo "==> [$APP] diff imports"
python3 "$ROOT/tools/diff_imports.py" "/tmp/${APP}.orig" -- "$SSH" "$HOST" \
    > "/tmp/${APP}_manifest.json"

echo "==> [$APP] classify symbols on guest"
"$SCP" "/tmp/${APP}_manifest.json" "$HOST:/tmp/"
cat "$ROOT/tools/classify_symbols.py" \
  | "$SSH" "$HOST" "cat > /tmp/classify_symbols.py && python /tmp/classify_symbols.py /tmp/${APP}_manifest.json" \
  > "/tmp/${APP}_manifest.classified.json"

echo "==> [$APP] surgical-patch binary + inject CoreUI LC_LOAD_DYLIB"
python3 "$ROOT/tools/patch_surgical.py" \
    "/tmp/${APP}.orig" \
    "/tmp/${APP}_manifest.classified.json" \
    --out "/tmp/${APP}.surgical" \
    --inject-dylib "$COREUI_INJECT" | tail -3

echo "==> [$APP] install patched binary + embed dylib + edit plist + sign + register"
"$SCP" "/tmp/${APP}.surgical" "$HOST:/tmp/"
"$SSH" "$HOST" "set -e
  BUNDLE=\$HOME/${APP}.app
  FW=\$BUNDLE/Contents/Frameworks
  mkdir -p \"\$FW\"
  cp /tmp/${APP}.surgical \"\$BUNDLE/Contents/MacOS/${APP}\"
  cp $DYLIB_ON_GUEST \"\$FW/kpf_stubs.dylib\"
  # Embed Yosemite CoreUI.framework so the bundle is self-contained.
  rm -rf \"\$FW/CoreUI.framework\"
  cp -R $YOS_COREUI_SRC \"\$FW/CoreUI.framework\"
  PLIST=\"\$BUNDLE/Contents/Info.plist\"
  /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 10.9.0' \"\$PLIST\"
  /usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' \"\$PLIST\" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' \"\$PLIST\"
  /usr/libexec/PlistBuddy -c \"Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $INSERT_PATH\" \"\$PLIST\"
  codesign --force --deep --sign - \"\$BUNDLE\" 2>&1 | tail -2
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  \"\$LSR\" -f \"\$BUNDLE\" >/dev/null
  echo \"   ${APP}.app ready: double-click or 'open ~/${APP}.app'\"
"
