#!/usr/bin/env bash
# _bash_guard.sh — centralised bash 5+ check.
#
# Every entry-point script in this repo (scripts/erts-*.sh, scripts/local/*.sh)
# sources this file as the very first thing after the shebang. If the
# interpreter is older than bash 5 we refuse to run, because the rest of the
# code relies on:
#
#   - `declare -A` (associative arrays)          (bash 4+)
#   - `${var,,}` / `${var^^}` (case munging)     (bash 4+)
#   - `mapfile` / `readarray`                   (bash 4+)
#   - `${BASH_SOURCE[0]}` portability fixes      (bash 3+)
#
# macOS still ships /bin/bash = bash 3.2.57 (from 2007) as the system default
# in 2026. Without this guard you get a baffling "unbound variable" error
# four hundred lines deep into the script — at the first `declare -A` line.
# This file makes the failure immediate and the fix obvious.
#
# This file is meant to be sourced, never executed directly. The bottom
# guard catches a direct `bash _bash_guard.sh` and exits 1 with a hint.

# ── Direct-execution guard ───────────────────────────────────────────────
# If this file is being run (not sourced), $BASH_SOURCE[0] == $0.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '[batamanta-erts] _bash_guard.sh is a library; do not run it directly.\n' >&2
  printf '  It is meant to be sourced from the entry-point scripts in scripts/.\n' >&2
  exit 1
fi

# ── Bash 5+ check ────────────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 5 )); then
  printf '[batamanta-erts] ERROR: bash %s.%s detected, need bash 5+.\n' \
    "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" >&2
  printf '  This script uses declare -A, mapfile, ${var,,} and other features that\n' >&2
  printf '  do not exist in bash 3.2 (the default /bin/bash on macOS since 2007).\n' >&2
  printf '\n' >&2
  printf '  Install bash 5 and re-run with the new interpreter:\n' >&2
  printf '\n' >&2
  printf '    brew install bash\n' >&2
  printf '    /opt/homebrew/bin/bash %s %s\n' "$0" "$*" >&2
  printf '\n' >&2
  printf '  Or add /opt/homebrew/bin/bash to your PATH before /bin/bash.\n' >&2
  printf '  (CI on ubuntu-latest ships bash 5.1, so this never fires there.)\n' >&2
  # `return` works when sourced; `exit` works when run. Try `return` first
  # so we don't kill the parent shell on a sourced failure.
  return 1 2>/dev/null || exit 1
fi
