#!/usr/bin/env bash
# =============================================================================
#  03-build.sh — Build orchestrator + target catalog.
# =============================================================================
#
#  `build_target <target>` is the single entry point. It:
#    1. Resolves the target's build method (docker / native / precompiled).
#    2. Computes the (target, version) build plan (00-utils / 01-detect).
#    3. Acquires a per-(target,version) lock so concurrent erts_gen runs
#       don't double-build.
#    4. Dispatches to 10-targets/<target>.sh's build_<target>() function.
#    5. Uploads the asset and updates .build-state.json.
# =============================================================================

# -----------------------------------------------------------------------------
#  Target catalog
# -----------------------------------------------------------------------------
#  Seven target_key values, one per (os, arch) combination we ship. Each
#  release tag (`OTP-X.Y.Z`) should eventually have one tarball/zip for
#  each of these seven. The script excludes darwin-amd64 from CI builds
#  (it requires a paid `macos-12` runner) and excludes windows-arm64 (no
#  upstream OTP prebuilds to mirror).
#
#  Asset name conventions (per the upstream mirror):
#    linux-{glibc,musl}-{amd64,arm64}.tar.gz
#    darwin-{amd64,arm64}.tar.gz
#    windows-amd64.zip
#
#  Public target lists for erts_gen filters:
declare -a ALL_TARGETS=(
  linux-glibc-amd64
  linux-glibc-arm64
  linux-musl-amd64
  linux-musl-arm64
  darwin-amd64
  darwin-arm64
  windows-amd64
)
declare -a ARM64_TARGETS=(
  linux-glibc-arm64
  linux-musl-arm64
  darwin-arm64
)
declare -a AMD64_TARGETS=(
  linux-glibc-amd64
  linux-musl-amd64
  darwin-amd64
  windows-amd64
)

# Per-target build parameters. Build scripts in 10-targets/*.sh read these.
declare -A TARGET_DOCKER_PLATFORM=(
  [linux-glibc-amd64]="linux/amd64"
  [linux-glibc-arm64]="linux/arm64"
  [linux-musl-amd64]="linux/amd64"
  [linux-musl-arm64]="linux/arm64"
)
declare -A TARGET_DOCKER_IMAGE=(
  [linux-glibc-amd64]="ubuntu:22.04"
  [linux-glibc-arm64]="ubuntu:22.04"
  [linux-musl-amd64]="alpine:3.19"
  [linux-musl-arm64]="alpine:3.19"
)
declare -A TARGET_ENTRYPOINT=(
  [linux-glibc-amd64]="bash"
  [linux-glibc-arm64]="bash"
  [linux-musl-amd64]="sh"
  [linux-musl-arm64]="sh"
)
declare -A TARGET_DEPS_CMD=(
  [linux-glibc-amd64]="apt-get update && apt-get install -y build-essential autoconf libncurses5-dev libssl-dev zlib1g-dev perl coreutils zstd"
  [linux-glibc-arm64]="apt-get update && apt-get install -y build-essential autoconf libncurses5-dev libssl-dev zlib1g-dev perl coreutils zstd"
  [linux-musl-amd64]="apk add --no-cache build-base autoconf ncurses-dev openssl-dev zlib-dev perl bash coreutils zstd"
  [linux-musl-arm64]="apk add --no-cache build-base autoconf ncurses-dev openssl-dev zlib-dev perl bash coreutils zstd"
)
declare -A TARGET_ASSET=(
  [linux-glibc-amd64]="linux-glibc-amd64.tar.gz"
  [linux-glibc-arm64]="linux-glibc-arm64.tar.gz"
  [linux-musl-amd64]="linux-musl-amd64.tar.gz"
  [linux-musl-arm64]="linux-musl-arm64.tar.gz"
  [darwin-amd64]="darwin-amd64.tar.gz"
  [darwin-arm64]="darwin-arm64.tar.gz"
  [windows-amd64]="windows-amd64.zip"
)
#  Whether the source we ship is the upstream precompiled zip (1) or a
#  locally built tree (0). Targets not listed here default to 0.
declare -A TARGET_USES_PRECOMPILED=(
  [windows-amd64]=1
)
#  Mapping from target key to the asset name in `erlang/otp` releases.
#  Only the targets that pull from upstream are listed here.
declare -A UPSTREAM_ASSET=(
  [windows-amd64]="otp_win64_VERSION.zip"
)

# -----------------------------------------------------------------------------
#  Pinned baseline versions
# -----------------------------------------------------------------------------
#  This list is the project's "we promise to ship these" baseline. New
#  upstream versions discovered by erts_gen auto extend this in-memory
#  but the on-disk commit of OTP_VERSIONS happens in _lib.sh /
#  regenerate-*.sh.
declare -a OTP_VERSIONS=(
  27.0 27.0.1
  27.1 27.1.1 27.1.2 27.1.3
  27.2 27.2.1 27.2.2 27.2.3 27.2.4
  27.3 27.3.1 27.3.2 27.3.3 27.3.4
  28.0 28.0.1 28.0.2 28.0.3 28.0.4
  28.1 28.1.1
  28.2 28.3 28.3.1 28.3.2 28.3.3
  28.4 28.4.1 28.4.2 28.4.3
  28.5
  29.0 29.0.1 29.0.2 29.0.3 29.0.4 29.0.5 29.0.6 29.0.7 29.0.8 29.0.9
  29.1 29.1.1 29.1.2 29.1.3 29.1.4 29.1.5 29.1.6 29.1.7 29.1.8 29.1.9
)

# -----------------------------------------------------------------------------
#  Cleanup: stale locks + traps
# -----------------------------------------------------------------------------
_clean_stale_locks

_on_interrupt() {
  trap '' INT TERM
  err "interrupted"
  exit 130
}
trap _on_interrupt INT TERM

cleanup() {
  # Release every lock we still hold, in case the trap fires before
  # the explicit rm in with_lock. .locks/*.lock files older than
  # LOCK_MAX_AGE_SECONDS are cleared by _clean_stale_locks on the next
  # invocation anyway, so this is purely cosmetic.
  local lock
  shopt -s nullglob
  for lock in "$LOCKS"/*.lock; do
    rm -f "$lock"
  done
  shopt -u nullglob
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
#  Download helpers
# -----------------------------------------------------------------------------
_curl_with_backoff() {
  # _curl_with_backoff <url> <output> [max_attempts]
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
    if [[ ! -s "$out" ]]; then
      warn "no upstream source tarball for OTP-$v — skipping"
      return 1
    fi
    err "download failed for OTP-$v after $BATAMANTA_RETRIES attempts"
    return 1
  fi
  printf '%s\n' "$out"
}

download_precompiled() {
  # download_precompiled <target> <version>
  #  Echoes the path to the downloaded precompiled zip (Windows today).
  local target="$1" v="$2"
  local upstream="${UPSTREAM_ASSET[$target]}"
  upstream="${upstream//VERSION/$v}"
  local out="$SRC_TEMP/$upstream"
  if [[ -s "$out" ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  log "downloading $upstream"
  _curl_with_backoff \
    "https://github.com/erlang/otp/releases/download/OTP-$v/$upstream" \
    "$out" "$BATAMANTA_RETRIES" || return 1
  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  Locking — one build per (target, version)
# -----------------------------------------------------------------------------
with_lock() {
  # with_lock <target> <version> <fn>
  #  Acquire an exclusive file lock for the (target, version) cell before
  #  running the build function. If the lock is held elsewhere, poll for
  #  ~10s; if it's still held, skip (assume another erts_gen is working on
  #  this cell).
  local target="$1" v="$2" fn="$3"
  local lock_dir="$LOCKS"
  mkdir -p "$lock_dir"
  local lock_file="$lock_dir/${target}-${v}.lock"
  local acquired=0 tries=0
  while (( tries < 10 )); do
    if ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
      acquired=1; break
    fi
    sleep 1
    tries=$((tries+1))
  done
  if (( acquired == 0 )); then
    warn "$target/$v is locked by another process — skipping"
    return 0
  fi
  "$fn"
  local rc=$?
  rm -f "$lock_file"
  return $rc
}

# -----------------------------------------------------------------------------
#  Per-target dispatcher
# -----------------------------------------------------------------------------
#  Each entry in 10-targets/<target>.sh sources back to register a
#  build_<target>() function that build_target below calls. The dispatch
#  is purely by name; missing targets fail loud.
build_target() {
  # build_target <target> [version...] [flags]
  local target="$1"
  if [[ -z "${TARGET_ASSET[$target]:-}" ]]; then
    err "unknown target: '$target'"
    err "valid: linux-glibc-{amd64,arm64} linux-musl-{amd64,arm64} darwin-{amd64,arm64} windows-amd64"
    return 2
  fi
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

  # --discover: extend OTP_VERSIONS in-memory with whatever new the
  # upstream shipped since the last commit of this file. Interactive /
  # --force runs extend; pure CI keeps the pinned baseline so the build
  # is reproducible.
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
      return 0
    fi
    versions=()
    while IFS= read -r line; do
      versions+=("${line#* }")
    done <<< "$plan"
  fi

  if [[ ${#versions[@]} == 0 ]]; then
    versions=("${OTP_VERSIONS[@]}")
  fi
  # Filter by --only= if set
  if [[ -n "$BATAMANTA_ONLY_VERSIONS" ]]; then
    local filtered=() wanted
    local IFS=','
    for wanted in $BATAMANTA_ONLY_VERSIONS; do
      for v in "${versions[@]}"; do
        [[ "$v" == "$wanted" ]] && filtered+=("$v")
      done
    done
    versions=("${filtered[@]}")
  fi

  local v done=0 failed=0 skipped=0 total=${#versions[@]}
  log "==> $target: ${total} version(s) in queue"
  if (( total == 0 )); then
    log "    (nothing matched the filter; check --only= and the build plan)"
    return 0
  fi
  for v in "${versions[@]}"; do
    [[ -z "$v" ]] && continue
    with_lock "$target" "$v" _build_cell "$target" "$v" \
      && done=$((done+1)) \
      || { rc=$?; if (( rc == 2 )); then skipped=$((skipped+1)); else failed=$((failed+1)); fi; }
  done
  log "==> $target: done=$done failed=$failed skipped=$skipped total=$total"
}

_build_cell() {
  # _build_cell <target> <version>
  #  The per-(target,version) build body, called under a lock by build_target.
  #  We use ${1:-} defaults to avoid crashing when build_target is called
  #  with empty positional args under `set -u` (line 373 used to crash
  #  with "$1: unbound variable" when --auto path called into here).
  local target="${1:-}" v="${2:-}"
  local asset=""
  if [[ -n "$target" ]]; then asset="${TARGET_ASSET[$target]:-}"; fi
  local tag="OTP-$v"

  if [[ -z "${BATAMANTA_FORCE:-}" ]] \
     && [[ "$(_state_get "$target/$v")" == "done" ]] \
     && asset_in_release "$tag" "$asset"; then
    log "    $target/$v already done — skipping"
    return 2
  fi

  local build_fn="build_${target//-/_}"
  if ! declare -F "$build_fn" >/dev/null 2>&1; then
    err "    no 10-targets/$target.sh registration: build function '$build_fn' missing"
    err "    (did you forget to `source 10-targets/$target.sh`?)"
    return 1
  fi

  _state_set "$target/$v" "pending"
  if "$build_fn" "$v"; then
    _state_set "$target/$v" "done"
    return 0
  else
    _state_set "$target/$v" "failed" "build_${target//-/_} $v"
    return 1
  fi
}
