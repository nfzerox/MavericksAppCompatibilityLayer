#!/bin/bash
#
# install_iwork2015.sh -- patch a 2015-era iWork app to run on
# Mac OS X 10.9 Mavericks.
#
# This is the friendly entry point for the Mavericks workflow. Run it
# directly on the Mavericks Mac. Drag a Keynote / Pages / Numbers .app
# onto Terminal.app after typing "./install_iwork2015.sh ", or pass the
# path as an argument:
#
#   ./install_iwork2015.sh /path/to/Keynote.app
#   ./install_iwork2015.sh /path/to/Pages.app
#   ./install_iwork2015.sh /path/to/Numbers.app
#
# The .app is patched in place. A pristine backup of the original
# main binary is kept alongside the modified one as <App>.orig so the
# patch is repeatable.
#
# What it does (in order):
#   1. Identifies the app by its Info.plist CFBundleExecutable (so a
#      bundle renamed to "Pages5.app" still works).
#   2. Saves Contents/MacOS/<App>.orig if it doesn't exist.
#   3. Runs dlcheck against the binary's bind tables to discover
#      (library, symbol) pairs that don't exist on this Mavericks
#      install -> /tmp/<App>.manifest.json. This is the "what does
#      this app need that Mavericks doesn't have" diff.
#   4. Surgical-patches the binary: for each missing (lib, symbol),
#      flips its bind ordinal to BIND_SPECIAL_DYLIB_FLAT_LOOKUP and
#      ORs in BIND_SYMBOL_FLAGS_WEAK_IMPORT. Everything else stays
#      two-level-bound -- libSystem, libobjc, etc. are not touched,
#      which is essential on Mavericks where the lazy-bind fast path
#      can mis-handle weakened re-exports (e.g. _OSAtomicIncrement32Barrier
#      lives in libsystem_platform.dylib and is re-exported via
#      libSystem.B.dylib; blanket weakening of libSystem breaks it).
#   5. Installs kpf_stubs.dylib into Contents/Frameworks/ (prebuilt
#      from dist/, or freshly compiled from stubs/ if Xcode is
#      available).
#   6. Embeds Apple's Yosemite CoreUI.framework so the .car asset
#      catalogs Keynote/Pages/Numbers ship decode correctly. Without
#      this step the app still launches, but icons render as boxes.
#   7. Lowers LSMinimumSystemVersion to 10.9.0 and adds an LSEnvironment
#      entry pointing DYLD_INSERT_LIBRARIES at the embedded dylib.
#   8. Ad-hoc re-signs the bundle so the kernel page-hash check passes.
#
# After this script finishes, double-clicking the .app from Finder works.
#
# See README.md for what to do if you don't yet have one of the 2015
# iWork apps -- short version: archive.org has Keynote 6.6.2 and
# Pages 5.6.2; Numbers 3.6.2 can be re-downloaded from the Purchased
# tab of the Mac App Store on OS X Yosemite.
#
# Requirements: only what ships with Mavericks. Mavericks ships
# /usr/bin/python (2.7.5), /usr/bin/codesign, /usr/libexec/PlistBuddy.
# No Xcode required if dist/ has the prebuilt dylib and dlcheck.

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: $0 <path-to-Keynote.app|Pages.app|Numbers.app>

Tip: in Terminal.app, type "./install_iwork2015.sh " (with a trailing
space) and then drag the .app onto the Terminal window. The path will
be filled in for you.
EOF
  exit 1
}

[ $# -ge 1 ] || usage

APP_PATH="${1%/}"   # strip trailing slash if the drag-and-drop added one
if [ ! -d "$APP_PATH" ]; then
  echo "error: not a directory: $APP_PATH" >&2
  usage
fi

PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
  echo "error: not a Mac app bundle (no $PLIST)" >&2
  exit 1
fi

# Identify the app by its Info.plist, not by the bundle's filename --
# users routinely rename "Keynote.app" to "Keynote 6.app" / "Pages5.app"
# to keep older and newer versions side by side, and we want those to
# work too.
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
case "$APP_NAME" in
  Keynote|Pages|Numbers) ;;
  *)
    echo "error: bundle's CFBundleExecutable is '$APP_NAME'." >&2
    echo "this installer only patches the 2015 iWork apps" >&2
    echo "(Keynote 6.6.2, Pages 5.6.2, Numbers 3.6.2)." >&2
    exit 1
    ;;
esac

BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
if [ ! -f "$BIN" ]; then
  echo "error: bundle is missing $BIN" >&2
  exit 1
fi

# If the bundle isn't writable (typical for /Applications-installed apps
# owned by root:admin), re-launch ourselves under sudo. Skip if we're
# already root, or if sudo isn't available, or if the user has opted
# out via KPF_NO_SUDO=1.
if [ "$(id -u)" != "0" ] && [ "${KPF_NO_SUDO:-}" != "1" ]; then
  if [ ! -w "$BIN" ] || [ ! -w "$APP_PATH/Contents" ] || [ ! -w "$APP_PATH/Contents/Info.plist" ]; then
    if command -v sudo >/dev/null; then
      echo "==> $APP_PATH is not user-writable; re-running under sudo." >&2
      echo "    (set KPF_NO_SUDO=1 to skip this and let the script fail instead.)" >&2
      exec sudo "$0" "$@"
    else
      echo "error: $APP_PATH is not writable and sudo isn't available." >&2
      echo "       Copy the .app somewhere user-writable (e.g. ~/Desktop)" >&2
      echo "       and run the installer against that copy." >&2
      exit 1
    fi
  fi
fi

REPO=$(cd "$(dirname "$0")" && pwd)
TOOLS="$REPO/tools"
DIST="$REPO/dist"

# ----- 1. sanity --------------------------------------------------------
echo "==> patching $APP_NAME at $APP_PATH"

OSVER=$(sw_vers -productVersion 2>/dev/null || echo "?")
case "$OSVER" in
  10.9*|10.9)
    : ;;
  *)
    echo "   note: detected macOS $OSVER, not 10.9. The patcher is" >&2
    echo "         portable, but the patched app only runs on Mavericks." >&2
    ;;
esac

# ----- 2. pristine backup ----------------------------------------------
if [ ! -f "$BIN.orig" ]; then
  cp "$BIN" "$BIN.orig"
  echo "   saved pristine binary -> $BIN.orig"
else
  echo "   pristine binary already present at $BIN.orig (re-using)"
fi

# ----- 3. dlcheck + diff_imports ---------------------------------------
# We need dlcheck (the local-helper that wraps dlsym(3)) to discover
# what the binary imports that isn't actually exported by the
# Mavericks system libraries. dist/dlcheck ships a precompiled copy;
# if missing, build it locally (needs clang).
DLCHECK="$DIST/dlcheck"
if [ ! -x "$DLCHECK" ]; then
  if command -v clang >/dev/null; then
    echo "   no prebuilt dlcheck found; compiling from source"
    clang -O2 "$TOOLS/dlcheck.c" -ldl -o "$DLCHECK"
    strip -S "$DLCHECK"
  else
    echo "error: dist/dlcheck is missing and clang isn't available." >&2
    echo "       install Xcode or download a release that bundles" >&2
    echo "       the prebuilt dlcheck." >&2
    exit 1
  fi
fi

MANIFEST="/tmp/$APP_NAME.manifest.json"
echo "   diffing $APP_NAME imports against this Mavericks (~30s)"
python "$TOOLS/diff_imports.py" "$BIN.orig" --dlcheck "$DLCHECK" > "$MANIFEST"
LIB_COUNT=$(python -c "import json; m=json.load(open('$MANIFEST')); print(len(m.get('missing_libraries',[])))")
SYM_COUNT=$(python -c "import json; m=json.load(open('$MANIFEST')); print(len(m.get('missing_symbols',[])))")
echo "   $LIB_COUNT missing libraries, $SYM_COUNT missing symbols"

# ----- 4. surgical patch ------------------------------------------------
# Yosemite CoreUI gets injected as LC_LOAD_DYLIB pointing inside the
# bundle so it loads before AppKit's own /System/.../CoreUI reference.
COREUI_INJECT='@executable_path/../Frameworks/CoreUI.framework/Versions/A/CoreUI'
echo "   surgical-patching $BIN.orig"
python "$TOOLS/patch_surgical.py" "$BIN.orig" "$MANIFEST" \
  --out "$BIN" \
  --inject-dylib "$COREUI_INJECT" | tail -3

# ----- 5. dylib ---------------------------------------------------------
DYLIB_SRC=""
if [ -f "$DIST/kpf_stubs_iwork2015_10_9.dylib" ]; then
  DYLIB_SRC="$DIST/kpf_stubs_iwork2015_10_9.dylib"
  echo "   using prebuilt dylib from dist/"
elif command -v clang >/dev/null; then
  echo "   no prebuilt dylib found; compiling kpf_stubs from source"
  ( cd "$REPO/stubs" && make -s ) >/dev/null
  DYLIB_SRC="$REPO/stubs/kpf_stubs.dylib"
else
  echo "error: no prebuilt dylib in dist/ and no clang available." >&2
  echo "       install Xcode or download a release that bundles the" >&2
  echo "       precompiled dylib." >&2
  exit 1
fi

FW="$APP_PATH/Contents/Frameworks"
mkdir -p "$FW"
cp "$DYLIB_SRC" "$FW/kpf_stubs.dylib"
echo "   installed dylib at $FW/kpf_stubs.dylib"

# ----- 6. Yosemite CoreUI (so .car asset catalogs decode) ---------------
COREUI=""
if [ -d "$DIST/CoreUI.framework" ]; then
  COREUI="$DIST/CoreUI.framework"
elif [ -d /Volumes/Yosemite/System/Library/PrivateFrameworks/CoreUI.framework ]; then
  COREUI=/Volumes/Yosemite/System/Library/PrivateFrameworks/CoreUI.framework
fi
if [ -n "$COREUI" ]; then
  rm -rf "$FW/CoreUI.framework"
  cp -R "$COREUI" "$FW/CoreUI.framework"
  # codesign --deep refuses to seal a framework that has anything other
  # than Versions/ + symlinks to Versions/Current at its root. Apple's
  # own Yosemite CoreUI shipped a module.map and (sometimes) .DS_Store
  # at the root, and Apple's signing tooling tolerated that, but our
  # ad-hoc resign doesn't -- it errors with "unsealed contents present
  # in the root directory of an embedded framework" and leaves the
  # bundle with its old (Apple) signature plus our modified Info.plist,
  # which the kernel then SIGKILLs at exec. Scrub these defensively.
  find "$FW/CoreUI.framework" -maxdepth 1 -type f -name '.DS_Store' -delete
  find "$FW/CoreUI.framework" -maxdepth 1 -type f -name '*.modulemap' -delete
  rm -f "$FW/CoreUI.framework/module.map"
  echo "   embedded Yosemite CoreUI.framework so .car icons decode"
else
  echo "   note: no CoreUI in dist/ or /Volumes/Yosemite (icons will look rough)"
fi

# ----- 7. Info.plist ---------------------------------------------------
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 10.9.0' "$PLIST"
/usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$PLIST"
/usr/libexec/PlistBuddy -c \
  'Add :LSEnvironment:DYLD_INSERT_LIBRARIES string @executable_path/../Frameworks/kpf_stubs.dylib' \
  "$PLIST"
echo "   updated Info.plist (LSMinimumSystemVersion + LSEnvironment)"

# ----- 8. ad-hoc resign ------------------------------------------------
# Don't pipe stderr through tail -- if codesign fails (e.g. on an
# embedded framework whose layout it refuses), we want the actual
# error visible. A failed resign leaves the bundle with Apple's
# original signature plus our modified Info.plist, which the kernel
# rejects at exec time as "Code Signature Invalid".
if ! codesign --force --deep --sign - "$APP_PATH"; then
  echo "error: codesign failed; bundle is in a half-patched state." >&2
  echo "       The original binary is at $BIN.orig if you want to revert." >&2
  exit 1
fi
# Confirm by re-verifying. codesign sometimes reports success but leaves
# the seal in a state codesign --verify rejects (e.g. when an embedded
# subcomponent's seal didn't update). If verify fails, abort rather than
# pretend success.
if ! codesign --verify --verbose=1 "$APP_PATH" 2>&1; then
  echo "error: codesign --verify failed after resign; bundle won't launch." >&2
  echo "       Restore with: cp \"$BIN.orig\" \"$BIN\"" >&2
  exit 1
fi
echo "   re-signed bundle ad-hoc"

# ----- LaunchServices re-register so Finder picks up changes -----------
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSR" ] && "$LSR" -f "$APP_PATH" >/dev/null || true

cat <<EOF

==> done. Open the app:
    open "$APP_PATH"

Or just double-click it in Finder.

If something goes wrong, restore the original binary with:
    cp "$BIN.orig" "$BIN"
    codesign --force --deep --sign - "$APP_PATH"
EOF
