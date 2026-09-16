#!/usr/bin/env bash
# =============================================================================
#  00-utils.sh — Logging, GH bootstrap, dry-run, small helpers.
# =============================================================================
#
#  Loaded first by _lib.sh (which is sourced in turn by every entry-point
#  script: erts-*.sh, the 10-targets/*.sh scripts, and `erts_gen`).
#  Nothing here knows about targets, OTP versions, or releases.
# =============================================================================

# Resolve our own location so absolute paths work even when this script
# is sourced from another directory.
_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sibling guard — refuse to run on bash < 5. macOS /bin/bash is 3.2.57.
# shellcheck source=_bash_guard.sh
. "$_UTILS_DIR/_bash_guard.sh"

# -----------------------------------------------------------------------------
#  Paths (declared by 00 so the other 0X files can rely on them)
# -----------------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/MANIFEST.json"
SRC_TEMP="$REPO_ROOT/src_temp"
DIST="$REPO_ROOT/dist"
LOCKS="$REPO_ROOT/.locks"
STATE_FILE="$REPO_ROOT/.build-state.json"
LOG_PREFIX="[batamanta-erts]"
# Lock files older than this are considered stale (a previous run died
# without releasing them) and will be cleaned up on the next start.
LOCK_MAX_AGE_SECONDS=3600

mkdir -p "$SRC_TEMP" "$DIST" "$LOCKS"

# -----------------------------------------------------------------------------
#  CLI flags (defaults; build_target updates these inline per invocation)
# -----------------------------------------------------------------------------
#  Default behavior: skip already-built versions, retry failed ones.
#  --force            rebuild everything, even if asset is on the release
#  --only=V1,V2,...   only build these versions (comma-separated)
#  --target=T1,T2,... only build these targets (glibc/musl/darwin-amd64/...)
#  --status           print what's done/pending/failed, then exit
#  --retries=N        network/docker retry count (default 3)
#  --no-upload        build but don't upload to GitHub
BATAMANTA_FORCE="${BATAMANTA_FORCE:-0}"
BATAMANTA_ONLY_VERSIONS="${BATAMANTA_ONLY_VERSIONS:-}"
BATAMANTA_ONLY_TARGETS="${BATAMANTA_ONLY_TARGETS:-}"
BATAMANTA_STATUS_ONLY="${BATAMANTA_STATUS_ONLY:-0}"
BATAMANTA_RETRIES="${BATAMANTA_RETRIES:-3}"
BATAMANTA_NO_UPLOAD="${BATAMANTA_NO_UPLOAD:-0}"

# Default REPO so callers can source _lib.sh directly (without going
# through erts_gen). erts_gen overrides this if the user passes --repo.
REPO="${REPO:-Lorenzo-SF/Batamanta---ERTS-repository}"
export REPO

# Note: flag parsing happens inline in build_target — bash `shift` inside
# a function only affects the function's local $@, not the caller's.

# -----------------------------------------------------------------------------
#  Logging
# -----------------------------------------------------------------------------
log()   { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn()  { printf '%s \033[33mWARN\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; }
err()   { printf '%s \033[31mERR\033[0m  %s\n' "$LOG_PREFIX" "$*" >&2; }
ok()    { printf '%s \033[32mOK\033[0m\n'   "$LOG_PREFIX" "$*" >&2; }

# -----------------------------------------------------------------------------
#  Dry-run wrapper
# -----------------------------------------------------------------------------
run() {
  # run <cmd...> — execute, respecting BATAMANTA_DRY_RUN
  if [[ "${BATAMANTA_DRY_RUN:-0}" == "1" ]]; then
    printf '  \033[36m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
#  Small command-level helpers
# -----------------------------------------------------------------------------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
as_root_or() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo_or_self "$@"; fi }
sudo_or_self() {
  if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# -----------------------------------------------------------------------------
#  GitHub auth bootstrap
# -----------------------------------------------------------------------------
#  Local runs on Windows can lose GH_TOKEN across the PowerShell→bash
#  boundary depending on how the wrapper is invoked (env scrubbing, keyring
#  re-auth, etc). gh CLI then prints "To get started with GitHub CLI" and
#  every release upload fails silently. We try to recover from a few common
#  sources so local builds Just Work.
if [[ -z "${GH_TOKEN:-}" && -n "${BATAMANTA_GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$BATAMANTA_GITHUB_TOKEN"
fi
# Common locations for secrets.ps1 on this dev box. We try this BEFORE
# falling back to $GH_TOKEN from the environment because PowerShell
# profiles occasionally leak a stale/cached token into the child bash,
# which then silently overrides the fresh one in secrets.ps1 and breaks
# release uploads with mysterious 403s.
for cand in \
  "$HOME/Documents/PowerShell/secrets.ps1" \
  "${USERPROFILE:-}/Documents/PowerShell/secrets.ps1" \
  "./secrets.ps1"; do
  if [[ -f "$cand" ]]; then
    # Match either `$Script:GH_TOKEN = '...'` or `$env:GH_TOKEN = '...'`
    # and grab the first quoted value. We use awk instead of grep -P for
    # portability with Git Bash (no -P flag in BSD grep on some setups).
    _tok="$(awk -F"'" '/GH_TOKEN[[:space:]]*=/{ for (i=2;i<=NF;i+=2) { gsub(/^[[:space:]]+/,"",$i); if (length($i) > 20) { print $i; exit } } }' "$cand" 2>/dev/null || true)"
    if [[ -n "$_tok" ]]; then
      if [[ -n "${GH_TOKEN:-}" && "$GH_TOKEN" != "$_tok" ]]; then
        warn "environment GH_TOKEN differs from $cand — using the file's value (likely fresher)"
      fi
      export GH_TOKEN="$_tok"
      log "loaded GH_TOKEN from $cand"
      break
    fi
  fi
done

# -----------------------------------------------------------------------------
#  gh CLI cache eviction
# -----------------------------------------------------------------------------
#  `gh` on Windows caches tokens in the system keyring. Once cached, the
#  cache wins over $GH_TOKEN from the environment, which means a refreshed
#  token never gets picked up and you get mysterious 403s on release
#  upload. Force `gh` to fall back to $GH_TOKEN by clearing the local
#  credential store on first use.
if cmd_exists gh; then
  _current="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$_current" && -n "${GH_TOKEN:-}" && "$_current" != "$GH_TOKEN" ]]; then
    log "gh auth cache out of sync with GH_TOKEN — clearing local credential store"
    gh auth logout --hostname github.com >/dev/null 2>&1 || true
  fi
  unset _current
fi

gh_auth_header() {
  # Use BATAMANTA_GITHUB_TOKEN if explicitly set, otherwise fall back to
  # GH_TOKEN (which GitHub Actions auto-injects as ${{ secrets.GITHUB_TOKEN }}).
  # Public API endpoints work with just `Accept`, so the third branch
  # (no auth) is fine for unauthenticated reads.
  if [[ -n "${BATAMANTA_GITHUB_TOKEN:-}" ]]; then
    printf 'Authorization: Bearer %s' "$BATAMANTA_GITHUB_TOKEN"
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    printf 'Authorization: Bearer %s' "$GH_TOKEN"
  else
    printf 'Accept: application/vnd.github+json'
  fi
}

gh_api() {
  # gh_api <endpoint> — GET a single page. Caller paginates manually.
  local endpoint="$1"
  curl -fsSL -H "$(gh_auth_header)" \
    "https://api.github.com${endpoint}"
}
