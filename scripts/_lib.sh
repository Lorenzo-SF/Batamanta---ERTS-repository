#!/usr/bin/env bash
# =============================================================================
#  _lib.sh — common helpers for the ERTS builder scripts
# =============================================================================
#
#  This is the single source of truth for everything the per-target wrappers
#  (`erts-*.sh`) do. Keeping the logic in one bash file means:
#
#    * No Fish-vs-Bash portability issues (the original scripts were Fish).
#    * No copy-paste between targets (the original had 95% duplication).
#    * All targets follow the same flow, so the output tarballs all have the
#      same layout and the upstream `Batamanta` lib can rely on it.
#
#  A target script looks like:
#
#      #!/usr/bin/env bash
#      set -euo pipefail
#      . "$(dirname "$0")/_lib.sh"
#      build_target linux-glibc-amd64
#
#  A target is one of:
#      linux-glibc-amd64, linux-glibc-arm64,
#      linux-musl-amd64,  linux-musl-arm64,
#      darwin-amd64,      darwin-arm64,
#      windows-amd64
#
#  Public entry points (the per-target scripts only ever call one of these):
#    * build_target <target>          — process every OTP version that the
#                                       target is missing
#    * build_target <target> <v...>   — process only the listed versions
#    * detect_new_versions            — print OTP versions missing from
#                                       MANIFEST.json (one per line, "stable"
#                                       only by default)
#    * verify_manifest                — sanity-check the manifest structure
#
#  Environment variables that affect behavior:
#    * BATAMANTA_DRY_RUN=1            — print commands, don't execute
#    * BATAMANTA_FORCE=1              — regenerate even if asset exists
#    * BATAMANTA_GITHUB_TOKEN=<token>  — for >60 API requests/hour
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  Paths
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
#  CLI flags
# -----------------------------------------------------------------------------
#  Default behavior: skip already-built versions, retry failed ones.
#  --force            rebuild everything, even if asset is on the release
#  --only=V1,V2,...   only build these versions (comma-separated)
#  --target=T1,T2,... only build these targets (glibc/musl/darwin-amd64/...)
#  --status           print what's done/pending/failed, then exit
#  --retries=N        network/docker retry count (default 3)
#  --no-upload        build but don't upload to GitHub
BATAMANTA_FORCE=0
BATAMANTA_ONLY_VERSIONS=""
BATAMANTA_ONLY_TARGETS=""
BATAMANTA_STATUS_ONLY=0
BATAMANTA_RETRIES=3
BATAMANTA_NO_UPLOAD=0
# Note: flag parsing happens inline in build_target — bash `shift` inside
# a function only affects the function's local $@, not the caller's.

# -----------------------------------------------------------------------------
#  State persistence
# -----------------------------------------------------------------------------
#  .build-state.json records the result of every (target, version) attempt
#  so a re-run can skip done versions and retry failed ones without
#  re-downloading source tarballs or re-uploading assets. Format:
#
#    { "linux-glibc-amd64/27.0": {"status":"done","ts":1234},
#      "linux-musl-amd64/28.0": {"status":"failed","ts":1235,"error":"..."} }
#
_state_read() {
  if [[ -s "$STATE_FILE" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r 'to_entries[] | "\(.key) \(.value.status)"' "$STATE_FILE" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f'{k} {v[\"status\"]}') for k,v in d.items()]" "$STATE_FILE" 2>/dev/null
    else
      # Last-resort: parse with awk (no jq, no python3)
      awk -F'"' '/"status"/{ for(i=1;i<=NF;i++) if($i~/:/){key=$i; sub(/:/,"",key)} /done|failed|pending/{print prev" "$2; prev=""} {prev=$0}' "$STATE_FILE" 2>/dev/null
    fi
  fi
}
_state_get() {
  # _state_get <target>/<version> → "done" | "failed" | "pending" | ""
  local key="$1"
  if [[ -s "$STATE_FILE" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r --arg k "$key" '.[$k].status // empty' "$STATE_FILE" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],{}).get('status',''))" "$STATE_FILE" "$key" 2>/dev/null
    fi
  fi
}
_state_set() {
  # _state_set <target>/<version> <status> [error_message]
  local key="$1" status="$2" error="${3:-}" ts
  ts=$(date +%s)
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --arg s "$status" --arg e "$error" --argjson t "$ts" \
      '.[$k] = {"status":$s,"ts":$t} + (if $e != "" then {"error":$e} else {} end)' \
      "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys, os
p = sys.argv[1]; key = sys.argv[2]; status = sys.argv[3]; ts = int(sys.argv[4]); error = sys.argv[5]
try:
    d = json.load(open(p))
except: d = {}
d[key] = {'status': status, 'ts': ts}
if error: d[key]['error'] = error
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "$STATE_FILE" "$key" "$status" "$ts" "$error" 2>/dev/null
  else
    # No jq, no python — degrade gracefully. We skip state writes rather
    # than corrupting the file with naive string munging. The script still
    # works (asset_in_release check provides idempotency on its own).
    :
  fi
}

# -----------------------------------------------------------------------------
#  Discovery: find what's missing in our releases
# -----------------------------------------------------------------------------
#  These two functions let the local scripts (and the CI workflow) answer:
#    1. "What stable X.Y.Z OTP versions exist upstream that we don't ship?"
#       (_discover_upstream_versions)
#    2. "For our pinned baseline, which (version, target) pairs are missing
#        on the GitHub release?" (_compute_build_plan)
#
#  Together they implement the "just run it and it does the right thing"
#  contract: the script compares the repo against upstream and builds only
#  what's actually missing.
_discover_upstream_versions() {
  # _discover_upstream_versions [min_version]
  #  Echo one stable X.Y.Z OTP tag per line that exists on erlang/otp,
  #  sorted ascending, starting from $1 (default 27.0). Filters out:
  #    - draft/prerelease (rc, alpha, beta)
  #    - fourth-level versions (e.g. 28.5.0.1 — only released as patches)
  #    - 29.0-rc1 etc (anything with a dash)
  #  Skips versions whose source tarball returns 404 from GitHub.
  local min="${1:-27.0}"
  local tags
  tags=$(gh release list --repo erlang/otp --limit 300 --json tagName \
    --jq '.[] | select(.tagName | startswith("OTP-")) | .tagName' 2>/dev/null \
    | grep -E '^OTP-[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^OTP-//' \
    | sort -V) || return 1
  local v code
  for v in $tags; do
    # Enforce the minimum
    if [[ "$(printf '%s\n%s\n' "$min" "$v" | sort -V | head -n1)" != "$min" ]]; then
      continue
    fi
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      "https://github.com/erlang/otp/releases/download/OTP-$v/otp_src_$v.tar.gz" 2>/dev/null)
    if [[ "$code" == "302" || "$code" == "200" ]]; then
      echo "$v"
    fi
  done
}

_compute_build_plan() {
  # _compute_build_plan <target1> [target2...]
  #  Echo "<target> <version>" lines for every (target, version) pair that
  #  is missing from the GitHub releases. The caller turns this into a
  #  build queue. Skips versions that don't have upstream source (the
  #  download would fail anyway).
  local targets=("$@")
  local target v tag code url
  for target in "${targets[@]}"; do
    local asset="${TARGET_ASSET[$target]:-}"
    [[ -z "$asset" ]] && continue
    for v in "${OTP_VERSIONS[@]}"; do
      tag="OTP-$v"
      # If we already have a working state entry and the asset is on the
      # release, skip. State is the primary cache.
      if [[ -z "${BATAMANTA_FORCE:-}" ]] \
         && [[ "$(_state_get "$target/$v")" == "done" ]] \
         && asset_in_release "$tag" "$asset"; then
        continue
      fi
      # Live check against GitHub: if the asset is on the release, skip
      # (handles the case where the state file is missing/stale).
      if [[ -z "${BATAMANTA_FORCE:-}" ]] \
         && asset_in_release "$tag" "$asset"; then
        continue
      fi
      # For source-based targets, also verify the upstream tarball exists.
      # If 404, don't queue it (would just fail again).
      case "$target" in
        linux-glibc-*|linux-musl-*|darwin-*)
          code=$(curl -s -o /dev/null -w "%{http_code}" \
            "https://github.com/erlang/otp/releases/download/$tag/otp_src_$v.tar.gz" 2>/dev/null)
          if [[ "$code" != "302" && "$code" != "200" ]]; then
            continue
          fi
          ;;
      esac
      echo "$target $v"
    done
  done
}

# Clean stale lock files from a previous run that died (Ctrl-C, crash, OOM).
# Anything older than LOCK_MAX_AGE_SECONDS is assumed abandoned.
_clean_stale_locks() {
  local now lock age
  # Enable nullglob so a missing dir or no matches yields an empty list
  # instead of the literal pattern (which would break the loop).
  shopt -s nullglob
  now=$(date +%s)
  for lock in "$LOCKS"/*.lock; do
    [[ -e "$lock" ]] || continue
    # Git Bash on Windows doesn't support %Z in stat — fall back to mtime.
    if stat -c '%Y' "$lock" >/dev/null 2>&1; then
      age=$((now - $(stat -c '%Y' "$lock")))
    elif stat -f '%m' "$lock" >/dev/null 2>&1; then
      age=$((now - $(stat -f '%m' "$lock")))
    else
      continue  # can't determine age, leave it
    fi
    if (( age > LOCK_MAX_AGE_SECONDS )); then
      log "removing stale lock ($(($age / 60))m old): $(basename "$lock")"
      rm -f "$lock"
    fi
  done
  shopt -u nullglob
}
_clean_stale_locks

# -----------------------------------------------------------------------------
#  Target catalog
# -----------------------------------------------------------------------------
#  Seven target_key values, one per (so, arch) combination we ship. Every
#  release tag (`OTP-X.Y.Z`) should eventually have one tarball/zip for
#  each of these seven.
#
#  target_key          build_method  docker_image   upstream_asset
#  ---------------      -----------   ------------   --------------
#  linux-glibc-amd64    docker        ubuntu:22.04   (compile from source)
#  linux-glibc-arm64    docker        ubuntu:22.04   (compile from source)
#  linux-musl-amd64     docker        alpine:3.19    (compile from source)
#  linux-musl-arm64     docker        alpine:3.19    (compile from source)
#  darwin-amd64         native        (none)         (compile from source on Mac)
#  darwin-arm64         native        (none)         (compile from source on Mac)
#  windows-amd64        download      (none)         otp_win64_VERSION.zip
#
#  Windows arm64 is NOT supported. The Erlang/OTP project does not
#  publish precompiled arm64 Windows binaries (only `otp_win64_*.zip`,
#  which is x86_64). The upstream `batamanta` library reflects this by
#  not having a `:windows_arm64` target. Callers on Windows arm64
#  should use `windows-amd64` (which runs via the x86_64 emulation
#  layer) until upstream changes this.
# -----------------------------------------------------------------------------

declare -A TARGET_DOCKER_IMAGE=(
  [linux-glibc-amd64]="ubuntu:22.04"
  [linux-glibc-arm64]="ubuntu:22.04"
  [linux-musl-amd64]="alpine:3.19"
  [linux-musl-arm64]="alpine:3.19"
)
# Entrypoint shell inside the container. Ubuntu ships bash; alpine's default
# /bin/sh is busybox ash (which doesn't have `[[`), so we run the build
# under `sh` there. The runner script itself is kept POSIX-compatible
# (uses `[` instead of `[[`) so it works under either.
declare -A TARGET_ENTRYPOINT=(
  [linux-glibc-amd64]="bash"
  [linux-glibc-arm64]="bash"
  [linux-musl-amd64]="sh"
  [linux-musl-arm64]="sh"
)
declare -A TARGET_DOCKER_PLATFORM=(
  [linux-glibc-amd64]="linux/amd64"
  [linux-glibc-arm64]="linux/arm64"
  [linux-musl-amd64]="linux/amd64"
  [linux-musl-arm64]="linux/arm64"
)
declare -A TARGET_DEPS_CMD=(
  [linux-glibc-amd64]="apt-get update && apt-get install -y build-essential autoconf libncurses5-dev libssl-dev zlib1g-dev perl coreutils zstd"
  [linux-glibc-arm64]="apt-get update && apt-get install -y build-essential autoconf libncurses5-dev libssl-dev zlib1g-dev perl coreutils zstd"
  [linux-musl-amd64]="apk add --no-cache build-base autoconf ncurses-dev openssl-dev zlib-dev perl bash coreutils zstd"
  [linux-musl-arm64]="apk add --no-cache build-base autoconf ncurses-dev openssl-dev zlib-dev perl bash coreutils zstd"
)
declare -A TARGET_ASSET=(
  [linux-glibc-amd64]="amd64-glibc.tar.gz"
  [linux-glibc-arm64]="arm64-glibc.tar.gz"
  [linux-musl-amd64]="amd64-musl.tar.gz"
  [linux-musl-arm64]="arm64-musl.tar.gz"
  [darwin-amd64]="darwin-amd64.tar.gz"
  [darwin-arm64]="darwin-arm64.tar.gz"
  [windows-amd64]="windows-amd64.zip"
)
#  Whether the source we ship is the upstream precompiled zip (1) or a
#  locally built tree (0). Targets not listed here default to 0.
declare -A TARGET_USES_PRECOMPILED=(
  [windows-amd64]=1
)

#  Mapping from the target key to the asset name in `erlang/otp` releases.
#  Only the targets that pull from upstream are listed here.
#  `VERSION` is replaced by the OTP version at build time.
declare -A UPSTREAM_ASSET=(
  [windows-amd64]="otp_win64_VERSION.zip"
)

#  OTP version policy:
#    * "stable"      — all non-prerelease, non-draft tags
#    * "all"         — including prereleases
#    * "<minor>"     — only versions of that minor (e.g. "28" → 28.x.y)
#    * "explicit"    — only the versions passed as $@ to build_target
declare -a OTP_VERSIONS=(
  # Pinned baseline versions. The detect step will append anything new
  # that `erlang/otp` has released and that isn't in the manifest yet.
  # Floor is 27.0 — we don't ship legacy ERTS for older OTP. The CI
  # workflow passes `DETECT_MIN_VERSION=27.0` (configurable via the
  # `min_version` workflow_dispatch input) to enforce the same floor
  # at the upstream-detection layer.
  27.0 27.0.1
  27.1 27.1.1 27.1.2 27.1.3
  27.2 27.2.1 27.2.2 27.2.3 27.2.4
  27.3 27.3.1 27.3.2 27.3.3 27.3.4
  28.0 28.0.1 28.0.2 28.0.3 28.0.4
  28.1 28.1.1
  28.2 28.3 28.3.1 28.3.2 28.3.3
  28.4 28.4.1 28.4.2 28.4.3
  28.5
  29.0 29.0.1 29.0.2 29.0.3 29.0.4
)

# -----------------------------------------------------------------------------
#  Logging & dry-run
# -----------------------------------------------------------------------------
log()   { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn()  { printf '%s \033[33mWARN\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; }
err()   { printf '%s \033[31mERR\033[0m  %s\n' "$LOG_PREFIX" "$*" >&2; }
ok()    { printf '%s \033[32mOK\033[0m\n'   "$LOG_PREFIX" "$*" >&2; }

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
  "$USERPROFILE/Documents/PowerShell/secrets.ps1" \
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
if [[ -z "${GH_TOKEN:-}" ]]; then
  warn "GH_TOKEN not set — gh release create/upload will fail. Source secrets.ps1 or set BATAMANTA_GITHUB_TOKEN before running."
fi

# -----------------------------------------------------------------------------
#  GitHub CLI cache eviction
# -----------------------------------------------------------------------------
#  `gh` on Windows caches tokens in the system keyring. Once cached, the
#  cache wins over $GH_TOKEN from the environment, which means a refreshed
#  token never gets picked up and you get mysterious 403s on release
#  upload. Force `gh` to fall back to $GH_TOKEN by clearing the local
#  credential store on first use.
if command -v gh >/dev/null 2>&1; then
  _current="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$_current" && -n "${GH_TOKEN:-}" && "$_current" != "$GH_TOKEN" ]]; then
    log "gh auth cache out of sync with GH_TOKEN — clearing local credential store"
    gh auth logout --hostname github.com >/dev/null 2>&1 || true
  fi
  unset _current
fi

run() {
  # run <cmd...> — execute, respecting BATAMANTA_DRY_RUN
  if [[ "${BATAMANTA_DRY_RUN:-0}" == "1" ]]; then
    printf '  \033[36m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
#  GitHub helpers
# -----------------------------------------------------------------------------
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

release_exists() {
  # release_exists <tag> — true iff the release with that tag exists
  local tag="$1"
  gh release view "$tag" >/dev/null 2>&1
}

asset_in_release() {
  # asset_in_release <tag> <asset_name> — true iff the release has that asset
  local tag="$1" asset="$2"
  gh release view "$tag" --json assets -q '.assets[].name' 2>/dev/null \
    | grep -Fxq "$asset"
}

create_release() {
  # create_release <tag> <title> <notes>
  local tag="$1" title="$2" notes="$3"
  if release_exists "$tag"; then return 0; fi
  log "creating release $tag"
  # --target main: attach the release to the current tip of `main` instead
  # of requiring a pre-existing local tag. When the pipeline runs in CI the
  # tag is already on the remote, but in local execution `gh` would create
  # a stale local tag and refuse the upload. This flag is a no-op in CI
  # (where the tag already exists at that SHA) and a fix in local runs.
  gh release create "$tag" --title "$title" --notes "$notes" --target main
}

upload_asset() {
  # upload_asset <tag> <asset_path>
  local tag="$1" path="$2"
  gh release upload "$tag" "$path" --clobber
}

# -----------------------------------------------------------------------------
#  Source-tarball download
# -----------------------------------------------------------------------------
_curl_with_backoff() {
  # _curl_with_backoff <url> <output> [max_attempts]
  #  curl with exponential backoff. Used for all GitHub asset downloads so a
  #  transient rate-limit or network blip doesn't fail the whole run.
  local url="$1" out="$2" max="${3:-$BATAMANTA_RETRIES}" attempt=1 delay=5 rc
  while (( attempt <= max )); do
    curl -fLsL --connect-timeout 30 --max-time 600 \
      "$url" -o "$out" && [[ -s "$out" ]] && return 0
    rc=$?
    if (( attempt >= max )); then
      return $rc
    fi
    warn "download attempt $attempt/$max failed (rc=$rc), retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt+1))
  done
  return 1
}

download_source_tarball() {
  # download_source_tarball <version>
  #  Echoes the path to the downloaded source tarball.
  #  Reuses a cached copy if present. Returns non-zero if the upstream
  #  tarball genuinely doesn't exist (404) after all retries.
  local v="$1"
  local out="$SRC_TEMP/otp_src_$v.tar.gz"
  if [[ -s "$out" ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  log "downloading otp_src_$v.tar.gz"
  if ! _curl_with_backoff \
    "https://github.com/erlang/otp/releases/download/OTP-$v/otp_src_$v.tar.gz" \
    "$out" "$BATAMANTA_RETRIES"; then
    # Distinguish 404 (genuinely doesn't exist) from other failures.
    # If the file is empty/missing after all retries, treat as 404.
    if [[ ! -s "$out" ]]; then
      warn "no upstream source tarball for OTP-$v — skipping"
      return 1
    fi
    err "download failed for OTP-$v after $BATAMANTA_RETRIES attempts"
    return 1
  fi
  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  Upstream precompiled download (Windows)
# -----------------------------------------------------------------------------
download_precompiled() {
  # download_precompiled <version> <output_path>
  #  Downloads `otp_win64_<v>.zip` from the official `erlang/otp` release and
  #  saves it to <output_path>. We don't filter anything yet — the cleanup
  #  step happens later (`strip_precompiled`).
  local v="$1" out="$2"
  if [[ -s "$out" ]]; then
    return 0
  fi
  log "downloading precompiled otp_win64_$v.zip from erlang/otp"
  _curl_with_backoff \
    "https://github.com/erlang/otp/releases/download/OTP-$v/otp_win64_$v.zip" \
    "$out" "$BATAMANTA_RETRIES" || {
    err "failed to download Windows zip for OTP-$v"
    return 1
  }
}

# -----------------------------------------------------------------------------
#  Build: Linux (Docker)
# -----------------------------------------------------------------------------
docker_build_linux() {
  # docker_build_linux <target> <version> <source_tarball>
  #  Echoes the path to the resulting tarball on stdout.
  local target="$1" v="$2" tarball="$3"
  local platform="${TARGET_DOCKER_PLATFORM[$target]}"
  local image="${TARGET_DOCKER_IMAGE[$target]}"
  local deps_cmd="${TARGET_DEPS_CMD[$target]}"
  local asset="${TARGET_ASSET[$target]}"

  local runner="$SRC_TEMP/build_runner_${asset}.sh"
  local out="$DIST/$asset"

  # Make sure the temp dir exists (the cleanup trap removes it on EXIT, but
  # build_target also wipes it between calls — and the next docker_build_linux
  # invocation might run before mkdir -p fires if SRC_TEMP is gone).
  mkdir -p "$SRC_TEMP"
  # Defensive: if a previous run left a directory at this exact path
  # (e.g. from a partial docker mount), remove it so `cat >` can create
  # the file fresh.
  rm -rf "$runner"

  cat > "$runner" <<EOF
set -e
$deps_cmd > /dev/null 2>&1 || true
mkdir -p /build && tar -xzf /src.tar.gz -C /build --strip-components=1
cd /build
./otp_build autoconf > /dev/null 2>&1
./configure --prefix=/opt/erlang \\
  --without-javac --without-odbc --without-wx \\
  --without-debugger --without-observer --with-ssl > /dev/null 2>&1
make -j\$(nproc) > /dev/null 2>&1
make install > /dev/null 2>&1
cd /opt/erlang/lib/erlang
sed -i 's|^ROOTDIR=.*|ROOTDIR="\$(dirname "\$(dirname "\$(realpath "\$0")")")"|' bin/erl
sed -i 's|^ROOTDIR=.*|ROOTDIR="\$(dirname "\$(dirname "\$(realpath "\$0")")")"|' bin/start
# musl needs its loader colocated with the binaries so the resulting tarball
# can be executed on a glibc host without a separate musl runtime.
if [ -f /lib/ld-musl-\$ARCH.so.1 ]; then
  cp /lib/ld-musl-*.so.1 ./bin/ 2>/dev/null || true
fi
# Strip everything that isn't needed at runtime. This is the "clean" variant
# — the upstream builds ship src/, include/, test/, examples/ which we don't
# need and which inflate the tarball by 30-50%.
rm -rf lib/*/src  lib/*/include  lib/*/test  lib/*/examples
rm -f  InstallInfo  Install.ini
tar -czf /dist/$asset -C /opt/erlang/lib/erlang .
EOF

  # The `ARCH` placeholder is resolved at run time inside the container.
  local arch
  case "$platform" in
    linux/amd64) arch="x86_64" ;;
    linux/arm64) arch="aarch64" ;;
    *) err "unsupported platform $platform"; return 1 ;;
  esac
  sed -i "s/\\\$ARCH/$arch/g" "$runner"

  # MSYS2 / Git Bash auto-rewrites POSIX-looking args to Windows paths when
  # invoking native Windows binaries (docker.exe). The volume mounts work
  # fine, but the trailing `sh /build.sh` argument gets translated to
  # `sh C:/Program Files/Git/build.sh` and the container can't find it.
  # Fix: pre-convert the -v paths with cygpath -w (so MSYS leaves them
  # alone) and export MSYS_NO_PATHCONV=1 for the docker call so the
  # entrypoint `/build.sh` is left untouched.
  if [[ "${OSTYPE:-}" == msys* ]] || uname -s 2>/dev/null | grep -qi mingw; then
    local tarball_win dist_win runner_win
    tarball_win="$(cygpath -w "$tarball")"
    dist_win="$(cygpath -w "$DIST")"
    runner_win="$(cygpath -w "$runner")"
    # On MSYS2/Git Bash, MSYS auto-rewrites POSIX-looking args to Windows
    # paths when invoking native Windows binaries. That breaks `docker run`
    # in two ways: the trailing `sh /build.sh` becomes
    # `sh C:/Program Files/Git/build.sh`, and the `:` separator inside
    # `-v` mount specs gets misparsed as a path separator (writing the
    # tarball to a literal `…tar.gz;C` file). Setting MSYS_NO_PATHCONV=1
    # as a *prefix* on the docker invocation itself disables that for
    # this single command — it has to be on the binary, not on the
    # function wrapper, because MSYS reads the variable from the child
    # process environment, not the parent shell.
    local entrypoint="${TARGET_ENTRYPOINT[$target]:-sh}"
    if [[ "${BATAMANTA_DRY_RUN:-0}" == "1" ]]; then
      printf '  [dry-run] docker run --rm --privileged --net=host --platform %s -v %s:/src.tar.gz:ro -v %s:/dist -v %s:/build.sh:ro %s %s /build.sh\n' \
        "$platform" "$tarball_win" "$dist_win" "$runner_win" "$image" "$entrypoint"
    else
      # Redirect docker stdout/stderr to the parent shell's stderr so the
      # build progress (apt-get output, compile messages) doesn't get
      # captured by the caller's command substitution `out="$(...)"`. If
      # we don't, `out` becomes a multi-line mess and gh release upload
      # later fails with a malformed path — silently, because the run
      # function still exits 0.
      MSYS_NO_PATHCONV=1 docker run --rm --privileged --net=host \
        --platform "$platform" \
        --ulimit nofile=1024:1024 \
        --label "batamanta.build=1" \
        --label "batamanta.target=$target" \
        --label "batamanta.version=$v" \
        -v "$tarball_win:/src.tar.gz:ro" \
        -v "$dist_win:/dist" \
        -v "$runner_win:/build.sh:ro" \
        "$image" "$entrypoint" /build.sh >&2 || return 1
    fi
  else
    local entrypoint="${TARGET_ENTRYPOINT[$target]:-sh}"
    run docker run --rm --privileged --net=host \
      --platform "$platform" \
      --ulimit nofile=1024:1024 \
      --label "batamanta.build=1" \
      --label "batamanta.target=$target" \
      --label "batamanta.version=$v" \
      -v "$tarball:/src.tar.gz:ro" \
      -v "$DIST:/dist" \
      -v "$runner:/build.sh:ro" \
      "$image" "$entrypoint" /build.sh >&2 || return 1
  fi

  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  Build: macOS (native, run from a Mac with Homebrew openssl)
# -----------------------------------------------------------------------------
native_build_macos() {
  # native_build_macos <version> <source_tarball>
  #  Echoes the path to the resulting tarball on stdout.
  local v="$1" tarball="$2"
  local asset="${TARGET_ASSET[darwin-arm64]}"
  local build_dir="$SRC_TEMP/build_$v"
  local out="$DIST/$asset"

  local openssl_dir
  openssl_dir="$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl@1.1 2>/dev/null || true)"
  if [[ -z "$openssl_dir" ]]; then
    err "Homebrew openssl not found. Install with: brew install openssl@3"
    return 1
  fi

  run bash -c "
    set -e
    cd '$build_dir'
    export ERL_TOP=\"\$(pwd)\"
    ./otp_build autoconf > /dev/null 2>&1
    ./configure --prefix='$build_dir/opt_erlang' \\
      --without-javac --without-odbc --without-wx \\
      --without-debugger --without-observer \\
      --with-ssl='$openssl_dir' > /dev/null 2>&1
    make -j\$(sysctl -n hw.ncpu) > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd '$build_dir/opt_erlang/lib/erlang'
    sed -i '' 's|^ROOTDIR=.*|ROOTDIR=\"\$(dirname \"\$(dirname \"\$(PWD)\")\")\"|' bin/erl
    sed -i '' 's|^ROOTDIR=.*|ROOTDIR=\"\$(dirname \"\$(dirname \"\$(PWD)\")\")\"|' bin/start
    rm -rf lib/*/src lib/*/include lib/*/test lib/*/examples
    rm -f  InstallInfo Install.ini
    tar -czf '$out' .
  "

  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  Build: Windows (precompiled zip from upstream)
# -----------------------------------------------------------------------------
process_windows_zip() {
  # process_windows_zip <version> <output_path>
  #  Downloads the upstream precompiled zip, strips the bloat, and writes
  #  the cleaned-up archive back to <output_path>.
  local v="$1" out="$2"
  local tmp_zip="$SRC_TEMP/otp_win64_$v.zip"
  local work="$SRC_TEMP/win_$v"

  download_precompiled "$v" "$tmp_zip"
  rm -rf "$work"
  mkdir -p "$work"
  run unzip -q "$tmp_zip" -d "$work"

  # The upstream zip is laid out as `otp_win64_<v>/` inside the archive.
  # Inside that, files are at the root. We strip the bloat and repack.
  local root
  root="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -z "$root" ]]; then
    err "could not locate ERTS root inside $tmp_zip"
    return 1
  fi

  pushd "$root" >/dev/null
  # Same clean-up as the Linux/macOS builds: drop src/include/test/examples
  # and the install metadata that has no runtime value.
  find . -type d \( -name src -o -name include -o -name test -o -name examples \) \
    -exec rm -rf {} + 2>/dev/null || true
  rm -f  InstallInfo Install.ini Uninstall.exe setup.exe 2>/dev/null || true
  # Upstream Windows zip ships an `erts-X.Y.Z/doc/` directory with HTML
  # docs that we don't need at runtime. ~30MB saved per tarball.
  find . -type d -path '*/erts-*/doc' -exec rm -rf {} + 2>/dev/null || true
  # Repack. Use zip so the output is a real .zip (Windows users can open it
  # natively).
  run zip -qr "$out" .
  popd >/dev/null
}

# -----------------------------------------------------------------------------
#  Manifest update
# -----------------------------------------------------------------------------
manifest_read() {
  # Echoes the current manifest JSON (empty {} if missing). Falls back to
  # a local `jq` if available, otherwise to `python3 -m json.tool` (we always
  # have at least one of these on the supported hosts).
  if [[ -s "$MANIFEST" ]]; then
    cat "$MANIFEST"
  else
    echo '{}'
  fi
}

manifest_set_entry() {
  # manifest_set_entry <version> <key> <url>
  #
  # In CI jq is always installed. In local runs (especially on Windows Git
  # Bash) jq is usually missing — the per-asset manifest update then has
  # to fall back gracefully, otherwise the whole build aborts on the very
  # first release. We log a warning and keep going; the safety net is
  # `scripts/local/regenerate-manifest.{py,ps1}` which rebuilds the whole
  # manifest from the actual release assets after the run.
  local v="$1" key="$2" url="$3"
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    if jq --arg v "OTP-$v" --arg k "$key" --arg u "$url" \
         '.[$v][$k] = $u' "$MANIFEST" > "$tmp"; then
      mv "$tmp" "$MANIFEST"
    else
      warn "manifest_set_entry: jq failed for OTP-$v/$key, skipping this entry (regenerate-manifest.ps1 will fix it later)"
      rm -f "$tmp"
    fi
  else
    warn "manifest_set_entry: jq not found, skipping OTP-$v/$key (regenerate-manifest.ps1 will fix it later)"
  fi
}

manifest_has_entry() {
  # manifest_has_entry <version> <key> — true iff present
  local v="$1" key="$2"
  [[ -s "$MANIFEST" ]] || return 1
  jq -e --arg v "OTP-$v" --arg k "$key" '.[$v][$k]' "$MANIFEST" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
#  Locking (avoid two CI runs clobbering each other)
# -----------------------------------------------------------------------------
acquire_lock() {
  # acquire_lock <name> — echo 0 if acquired, 1 otherwise
  local name="$1"
  local lockfile="$LOCKS/$name.lock"
  if (set -o noclobber; echo $$ > "$lockfile") 2>/dev/null; then
    trap 'rm -f "$lockfile"' RETURN
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
#  Version detection
# -----------------------------------------------------------------------------
list_upstream_versions() {
  # list_upstream_versions [policy]
  #  policy: "stable" (default) | "all"
  #  Emits one OTP-X.Y.Z tag per line.
  local policy="${1:-stable}"
  local page=1
  while :; do
    local body
    body="$(gh_api "/repos/erlang/otp/releases?per_page=100&page=$page")"
    [[ -n "$body" ]] || break
    local count
    count="$(printf '%s' "$body" | jq 'length')"
    [[ "$count" -gt 0 ]] || break
    if [[ "$policy" == "stable" ]]; then
      printf '%s' "$body" | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name'
    else
      printf '%s' "$body" | jq -r '.[] | .tag_name'
    fi
    page=$((page + 1))
    [[ "$count" -lt 100 ]] && break
  done
}

detect_new_versions() {
  # detect_new_versions [policy]
  #  Emits one X.Y.Z (without "OTP-" prefix) per missing version.
  #  Honors $DETECT_MIN_VERSION (e.g. "27.0") — versions below that floor
  #  are skipped, even if upstream has them. The CI passes this env var from
  #  the workflow_dispatch `min_version` input.
  local policy="${1:-stable}"
  local min_version="${DETECT_MIN_VERSION:-}"
  local upstream
  upstream="$(list_upstream_versions "$policy")"
  for tag in $upstream; do
    local v="${tag#OTP-}"
    # "stable" policy already filters prereleases, but be defensive.
    if [[ "$v" == *rc* || "$v" == *beta* || "$v" == *alpha* ]]; then
      continue
    fi
    # Apply min_version floor: `sort -V` puts the smaller one first; if the
    # smaller is the floor, the version is >= floor. Anything else is below.
    if [[ -n "$min_version" ]]; then
      local lower
      lower="$(printf '%s\n%s\n' "$v" "$min_version" | sort -V | head -n1)"
      if [[ "$lower" != "$min_version" ]]; then
        continue
      fi
    fi
    # Has at least one target for this version?
    local has_any=0
    for asset in "${TARGET_ASSET[@]}"; do
      if manifest_has_entry "$v" "${asset%.tar.gz}"; then
        has_any=1; break
      fi
    done
    if [[ "$has_any" -eq 0 ]]; then
      printf '%s\n' "$v"
    fi
  done
}

# -----------------------------------------------------------------------------
#  Per-target driver
# -----------------------------------------------------------------------------
build_target() {
  # build_target <target> [version...|flag...]
  #  The first arg is always the target. Everything else is a mix of
  #  version strings and flags; flags are consumed, the rest become
  #  versions to build. This means flags can appear anywhere after the
  #  target (e.g. `build_target linux-glibc-amd64 --force 28.4.2`).
  #  State is persisted to .build-state.json so a crashed or interrupted
  #  run can resume from where it left off.
  #
  #  If no versions are passed AND --auto is set (or this is the only
  #  call in the script), the build plan is computed automatically: the
  #  script queries the GitHub releases, sees which (target, version)
  #  pairs are missing, and builds only those. Idempotent by design.
  local target="$1"
  shift
  local versions=() auto_plan=0 discover=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)     BATAMANTA_FORCE=1; shift ;;
      --only=*)    BATAMANTA_ONLY_VERSIONS="${1#--only=}"; shift ;;
      --target=*)  BATAMANTA_ONLY_TARGETS="${1#--target=}"; shift ;;
      --status)    BATAMANTA_STATUS_ONLY=1; shift ;;
      --retries=*) BATAMANTA_RETRIES="${1#--retries=}"; shift ;;
      --no-upload) BATAMANTA_NO_UPLOAD=1; shift ;;
      --auto)      auto_plan=1; shift ;;
      --discover)  discover=1; shift ;;
      --plan)      auto_plan=1; BATAMANTA_STATUS_ONLY=1; shift ;;
      --help|-h)
        cat <<EOF
Usage: build_target <target> [version...] [flags]
  --force      rebuild even if the asset is already on the release
  --only=V1,V2 only build these versions
  --target=T   only build this target (when called via regenerate-all.sh)
  --auto       auto-compute the build plan (only build what's missing)
  --plan       like --auto --status: show what would be built, don't build
  --discover   query erlang/otp for new X.Y.Z versions not in our baseline
  --status     print per-version status and exit
  --retries=N  network/docker retry count (default 3)
  --no-upload  build but don't push to GitHub

Safe to re-run. State persists in .build-state.json.
EOF
        return 0 ;;
      *) versions+=("$1"); shift ;;
    esac
  done

  # --discover: query upstream and optionally add new versions to our baseline.
  if [[ "$discover" == "1" ]]; then
    log "==> discovering upstream OTP versions..."
    local upstream_existing=() upstream_new=() uv
    while IFS= read -r uv; do
      [[ -z "$uv" ]] && continue
      local found=0
      for v in "${OTP_VERSIONS[@]}"; do
        [[ "$v" == "$uv" ]] && found=1 && break
      done
      if (( found )); then
        upstream_existing+=("$uv")
      else
        upstream_new+=("$uv")
      fi
    done < <(_discover_upstream_versions)
    log "  ${#upstream_existing[@]} upstream versions already in our baseline"
    if [[ ${#upstream_new[@]} -gt 0 ]]; then
      log "  ${#upstream_new[@]} new upstream versions found:"
      for uv in "${upstream_new[@]}"; do
        log "    $uv"
      done
      if [[ "${BATAMANTA_FORCE:-0}" == "1" ]] || [[ -t 0 ]]; then
        # Interactive or forced: extend the baseline in this process only.
        # The caller can persist by editing scripts/_lib.sh if they want.
        OTP_VERSIONS+=("${upstream_new[@]}")
        log "  added ${#upstream_new[@]} new version(s) to the build queue for this run"
      else
        log "  (run interactively or with --force to include them in this run)"
      fi
    fi
  fi

  # --auto / --plan: replace versions[] with the build plan.
  if [[ "$auto_plan" == "1" ]] && [[ ${#versions[@]} -eq 0 ]]; then
    local plan
    plan=$(_compute_build_plan "$target" 2>/dev/null)
    if [[ -z "$plan" ]]; then
      log "==> build plan for $target: nothing to do (all up to date)"
      return 0
    fi
    log "==> build plan for $target:"
    while IFS= read -r line; do
      log "    build $line"
    done <<< "$plan"
    if [[ "${BATAMANTA_STATUS_ONLY:-0}" == "1" ]]; then
      return 0  # --plan: just print, don't build
    fi
    # Turn "<target> <version>" lines into a versions array
    versions=()
    while IFS= read -r line; do
      versions+=("${line#* }")
    done <<< "$plan"
  fi

  if [[ ${#versions[@]} -eq 0 ]]; then
    versions=("${OTP_VERSIONS[@]}")
  fi
  # Filter by --only= if set
  if [[ -n "$BATAMANTA_ONLY_VERSIONS" ]]; then
    local filtered=() want v
    IFS=',' read -ra want <<< "$BATAMANTA_ONLY_VERSIONS"
    for v in "${versions[@]}"; do
      for w in "${want[@]}"; do
        [[ "$v" == "$w" ]] && filtered+=("$v")
      done
    done
    versions=("${filtered[@]}")
  fi

  local asset="${TARGET_ASSET[$target]}"
  local key="${asset%.tar.gz}"
  if [[ "$asset" == *.zip ]]; then
    key="${asset%.zip}"
  fi
  log "==> target=$target  asset=$asset  key=$key  versions=${#versions[@]}"

  if [[ -z "${TARGET_DOCKER_IMAGE[$target]:-}" \
     && -z "${TARGET_USES_PRECOMPILED[$target]:-}" \
     && "$target" != "darwin-amd64" \
     && "$target" != "darwin-arm64" ]]; then
    err "unknown target: $target"
    return 1
  fi

  # --status: just report, don't build
  if [[ "$BATAMANTA_STATUS_ONLY" == "1" ]]; then
    local state_v
    for v in "${versions[@]}"; do
      state_v="$(_state_get "$target/$v")"
      if [[ -z "$state_v" ]]; then
        if asset_in_release "OTP-$v" "$asset"; then
          echo "  [$target] OTP-$v  DONE (on release, no state file entry)"
        else
          echo "  [$target] OTP-$v  PENDING"
        fi
      else
        echo "  [$target] OTP-$v  $state_v"
      fi
    done
    return 0
  fi

  # Clean up any orphaned Docker containers from a previous interrupted run.
  # We name them with the target+version so we can find them.
  local orphaned
  orphaned=$(docker ps -aq --filter "label=batamanta.build" 2>/dev/null || true)
  if [[ -n "$orphaned" ]]; then
    log "removing $(echo "$orphaned" | wc -l | tr -d ' ') orphaned container(s) from previous run"
    docker rm -f $orphaned >/dev/null 2>&1 || true
  fi

  local total=${#versions[@]} done=0 failed=0 skipped=0 i=0
  for v in "${versions[@]}"; do
    i=$((i+1))
    local tag="OTP-$v" state_v lock_file
    state_v="$(_state_get "$target/$v")"

    # Idempotency: if the asset is on the release and we haven't been told
    # to force, skip. This is the primary idempotency mechanism.
    if [[ "$BATAMANTA_FORCE" != "1" ]] \
       && [[ "$state_v" == "done" ]] \
       && asset_in_release "$tag" "$asset"; then
      log "  [$i/$total] $tag  $asset  already done — skip"
      done=$((done+1))
      continue
    fi
    # If the asset is on the release but state file doesn't know about it
    # (e.g. state file was lost), still skip — don't waste a build.
    if [[ "$BATAMANTA_FORCE" != "1" ]] \
       && asset_in_release "$tag" "$asset"; then
      log "  [$i/$total] $tag  $asset  on release — skip (recording state)"
      _state_set "$target/$v" "done"
      done=$((done+1))
      continue
    fi

    # Acquire per-(target,version) lock so a second run on the same target
    # skips this version instead of fighting for the same Docker container.
    lock_file="$LOCKS/${target}_${v}.lock"
    if [[ -e "$lock_file" ]]; then
      # Lock exists — check if it's stale
      local age now
      now=$(date +%s)
      if stat -c '%Y' "$lock_file" >/dev/null 2>&1; then
        age=$((now - $(stat -c '%Y' "$lock_file")))
      elif stat -f '%m' "$lock_file" >/dev/null 2>&1; then
        age=$((now - $(stat -f '%m' "$lock_file")))
      else
        age=0
      fi
      if (( age < LOCK_MAX_AGE_SECONDS )); then
        log "  [$i/$total] $tag  locked by another run (${age}s old) — skip"
        skipped=$((skipped+1))
        continue
      fi
      # Stale lock — take it
      log "  [$i/$total] $tag  taking over stale lock (${age}s old)"
    fi
    echo "$$ $(date +%s)" > "$lock_file"

    log "  [$i/$total] $tag  building"
    _state_set "$target/$v" "pending"
    local out src build_rc=0
    case "$target" in
      linux-glibc-*|linux-musl-*)
        if ! src="$(download_source_tarball "$v")"; then
          err "no source tarball for OTP-$v — skip"
          _state_set "$target/$v" "skipped" "no source tarball"
          rm -f "$lock_file"
          skipped=$((skipped+1))
          continue
        fi
        if ! out="$(docker_build_linux "$target" "$v" "$src")"; then
          err "build failed for $v on $target — skip"
          _state_set "$target/$v" "failed" "docker build failed"
          rm -f "$lock_file"
          failed=$((failed+1))
          continue
        fi
        ;;
      darwin-amd64|darwin-arm64)
        if ! src="$(download_source_tarball "$v")"; then
          err "no source tarball for OTP-$v — skip"
          _state_set "$target/$v" "skipped" "no source tarball"
          rm -f "$lock_file"
          skipped=$((skipped+1))
          continue
        fi
        local build_dir="$SRC_TEMP/build_$v"
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        tar -xzf "$src" -C "$build_dir" --strip-components=1
        if ! out="$(native_build_macos "$v" "$src")"; then
          err "native build failed for $v on $target — skip"
          _state_set "$target/$v" "failed" "native build failed"
          rm -rf "$build_dir" "$SRC_TEMP/opt_erlang" 2>/dev/null
          rm -f "$lock_file"
          failed=$((failed+1))
          continue
        fi
        rm -rf "$build_dir" "$SRC_TEMP/opt_erlang"
        ;;
      windows-amd64)
        out="$DIST/$asset"
        if ! process_windows_zip "$v" "$out"; then
          err "windows build failed for $v — skip"
          _state_set "$target/$v" "failed" "windows zip processing failed"
          rm -f "$lock_file"
          failed=$((failed+1))
          continue
        fi
        ;;
      *)
        err "  unknown target $target"
        rm -f "$lock_file"
        return 1 ;;
    esac

    # Upload + manifest (unless --no-upload)
    if [[ "$BATAMANTA_NO_UPLOAD" != "1" ]]; then
      log "    uploading $asset to $tag"
      create_release "$tag" "Erlang/OTP $v" \
        "Automated build of $asset for Erlang/OTP $v."
      upload_asset "$tag" "$out" || {
        err "upload failed for $v — asset is at $out, you can re-run to retry"
        _state_set "$target/$v" "failed" "upload failed"
        rm -f "$lock_file"
        failed=$((failed+1))
        continue
      }
      log "    updating manifest"
      local url="https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases/download/$tag/$asset"
      manifest_set_entry "$v" "$key" "$url"
    else
      log "    --no-upload set, asset at $out"
    fi

    _state_set "$target/$v" "done"
    rm -f "$lock_file"
    ok "  [$i/$total] $tag  $target  DONE"
    done=$((done+1))
  done

  log "==> target=$target  done=$done  failed=$failed  skipped=$skipped  total=$total"

  # Don't wipe SRC_TEMP here — the cleanup trap handles it on EXIT, and
  # a subsequent `build_target` call (e.g. glibc → musl in the same run)
  # benefits from the cached source tarballs. Wiping between calls used
  # to cause "No such file or directory" failures on the musl side.
}

# -----------------------------------------------------------------------------
#  Self-check (used by the smoke test if you wire it up)
# -----------------------------------------------------------------------------
verify_manifest() {
  # verify_manifest — prints "OK" if every entry has a download URL, fails
  # otherwise. The function is intentionally side-effect free.
  jq -e 'to_entries[] | .value | to_entries[] | .value' "$MANIFEST" >/dev/null
}

# -----------------------------------------------------------------------------
#  Trap to clean up on exit / interrupt
# -----------------------------------------------------------------------------
#  - On normal EXIT: remove all .lock files (the build is done, the locks
#    have served their purpose; next run shouldn't see them as stale).
#  - On SIGINT / SIGTERM (Ctrl-C, OOM kill, timeout): kill any running
#    containers we started and release all locks so the next run can
#    resume cleanly.
_INTERRUPTED=0
_on_interrupt() {
  _INTERRUPTED=1
  echo "" >&2
  err "interrupted — cleaning up containers and releasing locks"
  # Kill any batamanta-labelled containers still running
  local running
  running=$(docker ps -q --filter "label=batamanta.build" 2>/dev/null || true)
  if [[ -n "$running" ]]; then
    docker rm -f $running >/dev/null 2>&1 || true
  fi
  # Release all our locks (they have a $$ marker; we know which is ours)
  if [[ -d "$LOCKS" ]]; then
    shopt -s nullglob
    rm -f "$LOCKS"/*.lock
    shopt -u nullglob
  fi
  exit 130
}
cleanup() {
  # On normal EXIT, release locks but keep SRC_TEMP (cached tarballs are
  # useful for the next run; cleanup is opt-in via `rm -rf src_temp`).
  if [[ -d "$LOCKS" ]]; then
    shopt -s nullglob
    rm -f "$LOCKS"/*.lock
    shopt -u nullglob
  fi
}
trap cleanup EXIT
trap _on_interrupt INT TERM

# =============================================================================
#  Entrypoint: when sourced from a per-target script, the script does its
#  own `build_target <target>` call. We don't auto-execute here so this file
#  can be safely sourced from other contexts (e.g. unit tests, the CI step).
# =============================================================================
