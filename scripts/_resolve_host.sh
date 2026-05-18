#!/bin/bash
# Helper: resolve the Mavericks SSH target.
#
# Sources, in priority order:
#   1. The first non-empty argument passed to this helper (e.g. "$1" from
#      the calling script).
#   2. The MAV_HOST environment variable.
#   3. The first line of ~/.config/mavericks-app-compat/host.
#
# Echoes the resolved "user@host" string. Exits non-zero with a usage
# message if none of the above are set.
#
# Usage from a parent script:
#   HOST=$("$DIR/_resolve_host.sh" "${1:-}") || exit 1
__macl_resolve_host() {
  local h="${1:-${MAV_HOST:-}}"
  if [ -z "$h" ] && [ -r "$HOME/.config/mavericks-app-compat/host" ]; then
    h=$(head -n1 "$HOME/.config/mavericks-app-compat/host" | tr -d '[:space:]')
  fi
  if [ -z "$h" ]; then
    cat >&2 <<EOF
no Mavericks host configured.

Set one of:
  - pass user@host as the first argument
  - export MAV_HOST=user@host
  - echo user@host > ~/.config/mavericks-app-compat/host
EOF
    return 1
  fi
  printf '%s\n' "$h"
}

# If invoked as a script (not sourced), resolve and print.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  __macl_resolve_host "${1:-}"
fi
