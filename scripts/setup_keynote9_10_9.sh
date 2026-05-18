#!/bin/bash
# setup_keynote9_10_9.sh [user@host]
#
# Thin host-side wrapper: pushes the Python toolchain + the guest-side
# orchestrator (scripts/_kpf9_10_9_guest_orchestrator.sh) to ~/kpf_build/ on
# the Mavericks guest, then invokes the orchestrator over SSH. All the
# heavy lifting -- pristine copy, per-binary patch_min_version /
# diff_imports / patch_surgical, dylib install, Info.plist edits,
# ad-hoc resign -- happens on the guest using its own tools and the
# pristine bundle already at $HOME/UnmodifiedApps/Keynote9.app.
#
# No 900MB bundle scp; only a few KB of Python.

set -euo pipefail

echo "############################################################" >&2
echo "# WARNING: this is the FAILED Keynote 9.1 -> 10.9 attempt.  #" >&2
echo "# Keynote 9 aborts in a static initializer on Mavericks.    #" >&2
echo "# If you want Keynote on Mavericks, use ../install_iwork2015.sh" >&2
echo "# (Keynote 6.6.2, the 2015 release). This script is kept    #" >&2
echo "# only for contributors who want to retry the experiment.   #" >&2
echo "############################################################" >&2

DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_resolve_host.sh
source "$DIR/_resolve_host.sh"
HOST=$(__macl_resolve_host "${1:-}") || exit 1
ROOT=$(dirname "$DIR")
SSH="$DIR/ssh_wrap.sh"
SCP="$DIR/scp_wrap.sh"

echo "==> push Python tools + guest orchestrator"
"$SSH" "$HOST" "mkdir -p ~/kpf_build/tools"
for f in patch_min_version.py diff_imports.py patch_surgical.py macho_binds.py; do
  "$SCP" "$ROOT/tools/$f" "$HOST:kpf_build/tools/$f"
done
"$SCP" "$DIR/_kpf9_10_9_guest_orchestrator.sh" "$HOST:kpf_build/_kpf9_10_9_guest_orchestrator.sh"

echo "==> run guest orchestrator"
"$SSH" "$HOST" "bash ~/kpf_build/_kpf9_10_9_guest_orchestrator.sh"
