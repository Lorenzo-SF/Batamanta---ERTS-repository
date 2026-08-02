#!/usr/bin/env bash
# =============================================================================
#  detect-versions.sh â€” print OTP versions missing from MANIFEST.json
# =============================================================================
#
#  Used by the CI workflow as the "detect" job: this emits one X.Y.Z per
#  line for every OTP version that `erlang/otp` has released (stable) but
#  that the manifest doesn't yet cover for any target. The CI then passes
#  the list to the build matrix.
#
#  Usage:
#      ./detect-versions.sh             # stable only (default)
#      ./detect-versions.sh all         # include prereleases
#      ./detect-versions.sh stable | wc -l
#
#  Exit code: 0 if there's nothing to do (manifest is up to date), 1 if at
#  least one new version was detected. This lets the workflow decide whether
#  to skip the build step entirely.
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

policy="${1:-stable}"
new="$(detect_new_versions "$policy")"

if [[ -z "$new" ]]; then
    log "manifest is up to date (policy=$policy)"
    exit 0
fi

log "missing versions (policy=$policy):"
printf '%s\n' "$new"
exit 1
