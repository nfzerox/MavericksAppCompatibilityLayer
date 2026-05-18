#!/bin/bash
# Re-sign Keynote / Pages / Numbers bundles in $HOME so Xcode's view
# debugger and lldb attach stop refusing them as "invalid page" after a
# kpf_stubs.dylib hot-swap.
#
# Mavericks's kernel verifies cs_mtime (stored in the bundle's code
# signature) against the actual mtime of each signed file. A hot-swapped
# dylib has a fresher mtime than the signed manifest recorded, so attach
# fails with "CODE SIGNING: rejecting invalid page" and the host (Xcode)
# is killed.
#
# Re-signing with the same ad-hoc identity rebuilds the manifest from
# current mtimes. Plain `open` and launchd don't enforce this check, so
# only run this when you actually want to attach a debugger.
set -e
for app in Keynote Pages Numbers; do
  bundle="$HOME/$app.app"
  if [ -d "$bundle" ]; then
    echo "==> resigning $bundle"
    codesign --force --deep --sign - "$bundle"
  else
    echo "skip: $bundle not present"
  fi
done
echo "done."
