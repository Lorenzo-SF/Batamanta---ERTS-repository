#!/usr/bin/env bash
# lib-sync.sh — helpers for sync-erts.sh.
# Pure bash + gh CLI; no jq/python dependency.
#
# This file is sourced from sync-erts.sh. Do not run it directly.

# Refuse to run on bash < 5 (macOS still ships 3.2 as /bin/bash). Sourced
# as the very first thing after the shebang so the failure is immediate.
. "$(dirname "${BASH_SOURCE[0]}")/../_bash_guard.sh"

REPO="${REPO:-Lorenzo-SF/Batamanta---ERTS-repository}"
MIN_OTP_VERSION="${MIN_OTP_VERSION:-27.0}"
# Set by sync-erts.sh to honour the --no-build / --no-upload flags.
#   SYNC_BUILD  = 0  -> only upload assets that already exist locally
#                        (don't trigger a native build for missing files)
#   SYNC_UPLOAD = 0  -> build + keep the file in dist/, but don't push
#                        to the GitHub release (useful when build host
#                        is different from upload host)
# Defaults to 1/1 so calling these functions directly still does both.
SYNC_BUILD="${SYNC_BUILD:-1}"
SYNC_UPLOAD="${SYNC_UPLOAD:-1}"

# ── Targets ──────────────────────────────────────────────────────────────
# Three parallel arrays, indexed the same way. The i-th entry is the
# (target_key, asset_filename, build_script) for target i.
ALL_TARGETS=(
  windows-amd64
  darwin-arm64
  linux-glibc-amd64
  linux-glibc-arm64
  linux-musl-amd64
  linux-musl-arm64
)
declare -A TARGET_ASSET=(
  [windows-amd64]="windows-amd64.zip"
  [darwin-arm64]="darwin-arm64.tar.gz"
  [linux-glibc-amd64]="linux-glibc-amd64.tar.gz"
  [linux-glibc-arm64]="linux-glibc-arm64.tar.gz"
  [linux-musl-amd64]="linux-musl-amd64.tar.gz"
  [linux-musl-arm64]="linux-musl-arm64.tar.gz"
)
declare -A TARGET_SCRIPT=(
  [windows-amd64]="scripts/erts-windows-amd64.sh"
  [darwin-arm64]="scripts/erts-darwin-arm64.sh"
  [linux-glibc-amd64]="scripts/erts-linux-glibc-amd64.sh"
  [linux-glibc-arm64]="scripts/erts-linux-glibc-arm64.sh"
  [linux-musl-amd64]="scripts/erts-linux-musl-amd64.sh"
  [linux-musl-arm64]="scripts/erts-linux-musl-arm64.sh"
)
declare -A TARGET_RUNNER=(
  [windows-amd64]="windows-latest"
  [darwin-arm64]="macos-latest"
  [linux-glibc-amd64]="ubuntu-latest"
  [linux-glibc-arm64]="ubuntu-latest"
  [linux-musl-amd64]="ubuntu-latest"
  [linux-musl-arm64]="ubuntu-latest"
)

# ── Output helpers ───────────────────────────────────────────────────────
log()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# ── GitHub auth ──────────────────────────────────────────────────────────
# We intentionally DON'T have an upfront auth check. Detecting the difference
# between web-based OAuth and a fine-grained PAT (and knowing whether the
# PAT has the right scopes) is fragile and changes with `gh` versions, so
# we just let operations fail naturally and surface a friendly hint when
# they hit an auth error. The hint is the ONLY thing the user sees — they
# decide how to fix it (usually: drop the fine-grained token, do web-based
# `gh auth login`).
#
# Usage:
#   gh_with_auth_hint gh release create OTP-29.0.4 ...
#   gh_with_auth_hint gh release upload OTP-29.0.4 some.tar.gz --clobber
#
# On auth-related failure (HTTP 401, 403, "Bad credentials", "Resource not
# accessible by personal access token"), prints the hint and returns the
# original exit code. On other failures, just returns the original exit code
# with a one-line summary. On success, returns 0.
gh_with_auth_hint() {
  local errfile
  errfile="$(mktemp)"
  if "$@" 2>"$errfile"; then
    rm -f "$errfile"
    return 0
  fi
  local rc=$?
  local errmsg
  errmsg="$(cat "$errfile")"
  rm -f "$errfile"

  # Auth-related failure patterns we recognise. `gh` wraps API errors as
  # `gh: HTTP 403: Resource not accessible by personal access token` (or
  # `gh: Not Found` for 404, etc.) and a few variants of "Bad credentials"
  # for 401. Be generous so a slightly different phrasing still matches.
  local authish=0
  if [[ "$errmsg" == *"HTTP 401"* ]] \
     || [[ "$errmsg" == *"HTTP 403"* ]] \
     || [[ "$errmsg" == *"Bad credentials"* ]] \
     || [[ "$errmsg" == *"Resource not accessible"* ]] \
     || [[ "$errmsg" == *"requires authentication"* ]] \
     || [[ "$errmsg" == *"Not authenticated"* ]]; then
    authish=1
  fi

  if (( authish )); then
    err ""
    err "Parece un problema de auth al ejecutar: $*"
    err ""
    err "  Si GH_TOKEN / GITHUB_TOKEN están definidos pero no funcionan, prueba"
    err "  con el login web-based de gh (más simple que un fine-grained token):"
    err ""
    err "    unset GH_TOKEN"
    err "    unset GITHUB_TOKEN"
    err "    gh auth logout"
    err "    gh auth login"
    err ""
    err "Detalle del error original:"
    err "  $errmsg"
  else
    err "  command failed (rc=$rc): $*"
    err "  $errmsg"
  fi
  return $rc
}

# ── JSON helpers (jq-free) ──────────────────────────────────────────────
# All GH API output comes through `gh api ...` or `gh ... --json ... | jq -r ...`.
# We use `gh --template` or simple text extraction where possible, and
# hand-parse JSON in pure bash only for the manifest.

# Extract a top-level string array of values at a key.
# e.g. gh_list_json_field ".[].tagName" reads `.[].tagName`.
gh_list_field() {
  local filter="$1"
  local cmd="$2"
  # Use `gh api ... -q ".[] | .tagName"` style: gh api supports -q for
  # the `--jq` flag, so we can keep the call site simple.
  shift 2
  gh api -q "$filter" "$@" 2>/dev/null
}

# ── Version helpers ──────────────────────────────────────────────────────
tag_to_version() { printf '%s' "${1#OTP-}"; }
version_to_tag() { printf 'OTP-%s' "$1"; }

# `version_ge A B` returns 0 (true) if A >= B in semver-ish sense.
version_ge() {
  [[ "$1" == "$2" ]] && return 0
  local higher
  higher="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
  [[ "$higher" == "$1" ]]
}

# ── Discovery: erlang/otp releases vs local releases ─────────────────────
# List stable OTP versions on erlang/otp (>= MIN_OTP_VERSION), sorted -V.
list_erlang_versions() {
  gh api -q '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    "/repos/erlang/otp/releases?per_page=100" 2>/dev/null |
    sed 's/^OTP-//' |
    while read -r v; do
      [[ -z "$v" ]] && continue
      if version_ge "$v" "$MIN_OTP_VERSION"; then
        printf '%s\n' "$v"
      fi
    done | sort -V
}

# List every OTP version that already has a release in our repo, sorted
# newest first (sort -Vr). Keeping newest-first makes the MANIFEST.json
# easier to skim by humans when there's a new release at the top.
list_local_versions() {
  gh release list --repo "$REPO" --limit 200 --json tagName 2>/dev/null |
    grep -oE '"tagName":"OTP-[^"]+"' |
    sed 's/^"tagName":"OTP-//;s/"$//' |
    sort -Vr
}

# ── Sync releases: create any missing from the erlang/otp release set ───
# Strict version format: X.Y.Z (e.g. "29.0.4"). Rejects X.Y, X.Y.Z.W, RC tags
# (those end in `-rc1` etc), 4+-part versions, and anything else that
# doesn't look like a stable OTP release. This is defensive: the erlang/otp
# repo occasionally has tags like OTP-27.3.4.1 or OTP-28.5.0.5 from
# forks/automation that we don't want to mirror.
sync_releases() {
  log ">> syncing releases against erlang/otp (min=$MIN_OTP_VERSION)..."
  local -a official local_v
  mapfile -t official < <(list_erlang_versions)
  mapfile -t local_v < <(list_local_versions)

  for v in "${official[@]}"; do
    # Strict format check: X.Y or X.Y.Z, all digits. Rejects X.Y.Z.W
    # (e.g. 27.3.4.1) and tags with -rc/-beta suffixes.
    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      continue
    fi
    local tag
    tag="$(version_to_tag "$v")"
    local found=0
    for l in "${local_v[@]}"; do
      [[ "$l" == "$v" ]] && found=1 && break
    done
    if (( !found )); then
      log "  creating release $tag (empty)"
      gh_with_auth_hint gh release create "$tag" --repo "$REPO" \
        --title "Erlang/OTP $v" \
        --notes "Automated ERTS mirror for Erlang/OTP $v.

This release is part of the [Batamanta](https://github.com/Lorenzo-SF/Batamanta) ERTS prebuilt bundle — visit that repo for the source, MANIFEST, and the batamanta Elixir library." \
        || err "  FAILED to create $tag (continuing with the rest)"
    fi
  done
  ok "  releases synced"
}

# ── Per-release: list asset (name, url) pairs ─────────────────────────
# Echo one line per asset in the form "<name> <url>", sorted by name.
# Uses the portable Erlang escript as a JSON parser (no jq dependency).
list_assets_full_for() {
  local tag="$1"
  local escript="$REPO_ROOT/scripts/local/parse-release-assets.escript"
  local escript_runner
  escript_runner="$(command -v escript || true)"

  if [[ -n "$escript_runner" && -f "$escript" ]]; then
    gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null |
      "$escript_runner" "$escript" 2>/dev/null | sort
  else
    # Fallback: pure-bash regex (handles only `name` + `browser_download_url`).
    gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null |
      grep -oE '"name":"[^"]+"|"browser_download_url":"[^"]+"' |
      paste - - | sed 's/"name":"//;s/"[[:space:]]*"browser_download_url":"/ /;s/"$//' | sort
  fi
}

# ── Per-release: list asset names only ───────────────────────────────────
# Convenience wrapper: same data, only the name column.
list_assets_for() {
  list_assets_full_for "$1" | awk '{print $1}'
}

# ── Per-target: list local releases missing the target's asset ─────────
# For a given target, echo every local release tag that does NOT yet have
# the corresponding asset uploaded. Idempotent: re-running gives nothing.
list_missing_for() {
  local target="$1"
  local asset="${TARGET_ASSET[$target]}"
  local tag
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    if ! list_assets_for "$tag" | grep -qxF "$asset"; then
      printf '%s\n' "$tag"
    fi
  done < <(list_local_versions)
}

# ── Local asset path for a (target, version) pair ───────────────────────
# Convention: dist/<target>/<version>/<asset>
local_asset_path() {
  local target="$1" version="$2"
  local asset="${TARGET_ASSET[$target]}"
  printf '%s/dist/%s/%s/%s\n' "$REPO_ROOT" "$target" "$version" "$asset"
}

# ── Build a single (target, version) asset locally ──────────────────────
# Calls the per-target build script. Sets the right env (GH_TOKEN, no dry-run).
build_asset() {
  local target="$1" version="$2"
  local script="${TARGET_SCRIPT[$target]}"
  if [[ ! -f "$REPO_ROOT/$script" ]]; then
    err "  build script not found: $script"
    return 1
  fi
  (
    cd "$REPO_ROOT"
    export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    export BATAMANTA_GITHUB_TOKEN="${BATAMANTA_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
    export BATAMANTA_DRY_RUN=0
    bash "./$script" "$version"
  )
}

# ── Upload a single asset to its release ───────────────────────────────
upload_asset() {
  local target="$1" version="$2"
  local asset="${TARGET_ASSET[$target]}"
  local file
  file="$(local_asset_path "$target" "$version")"
  local tag
  tag="$(version_to_tag "$version")"
  if [[ ! -f "$file" ]]; then
    err "  upload: file not found: $file"
    return 1
  fi
  log "  uploading $asset ($version, $(du -h "$file" | cut -f1)) -> $tag"
  gh_with_auth_hint gh release upload "$tag" "$file" --repo "$REPO" --clobber
}

# ── Per-target sync: build+upload everything missing for one target ─────
sync_target() {
  local target="$1"
  local asset="${TARGET_ASSET[$target]}"
  log ">> syncing target $target (asset=$asset)"

  local tag version file
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    version="$(tag_to_version "$tag")"
    file="$(local_asset_path "$target" "$version")"
    if [[ ! -f "$file" ]]; then
      if (( SYNC_BUILD == 0 )); then
        err "  $target $version: local file missing and --no-build is set; skipping"
        continue
      fi
      log "  building $target $version"
      build_asset "$target" "$version" || {
        err "  build failed for $target $version; skipping"
        continue
      }
    fi
    if (( SYNC_UPLOAD == 0 )); then
      ok "  $target $version: local file present, --no-upload is set; skipping upload"
      continue
    fi
    upload_asset "$target" "$version" || err "  upload failed for $tag"
  done < <(list_missing_for "$target")
}

# ── Per-(target, version) sync: for one cell of the CI matrix ──────────
# Same logic as sync_target but restricted to a single (target, version) pair.
# No-ops if the release already has the asset (i.e. someone — us in a
# previous run, or the user manually — already uploaded it). Idempotent.
sync_target_version() {
  local target="$1" version="$2"
  local tag
  tag="$(version_to_tag "$version")"
  local asset="${TARGET_ASSET[$target]}"
  local file
  file="$(local_asset_path "$target" "$version")"

  log ">> syncing $target $version (asset=$asset)"

  # If the release doesn't even exist locally, we can't upload. The caller
  # is expected to have run --releases-only first (the workflow does this
  # in a separate `sync-releases` job).
  if ! list_local_versions | grep -qxF "$version"; then
    err "  release $tag doesn't exist in $REPO; run sync-erts.sh --releases-only first"
    return 1
  fi

  # Already on the release? nothing to do.
  if list_assets_for "$tag" | grep -qxF "$asset"; then
    ok "  $tag already has $asset; skipping"
    return 0
  fi

  # Build if we don't have the local file.
  if [[ ! -f "$file" ]]; then
    if (( SYNC_BUILD == 0 )); then
      err "  $target $version: local file missing and --no-build is set; skipping"
      return 1
    fi
    log "  building $target $version"
    build_asset "$target" "$version" || {
      err "  build failed for $target $version"
      return 1
    }
  fi

  upload_asset "$target" "$version" || {
    err "  upload failed for $tag"
    return 1
  }
}

# (sync_target_version above does NOT honour --no-upload on purpose:
# the CI matrix cell that calls it is responsible for both build and
# upload of its (target, version) pair, so we'd never want to skip the
# upload there. If you need "build only" semantics for one specific
# version, use the per-target script directly: erts-<target>.sh <v>.)

# ── Generate MANIFEST.json from the live release set ────────────────────
# Walks every local release, lists its assets, and writes a manifest keyed
# by OTP version. Uses `list_assets_for` which already returns the parsed
# `name` (and `url` is in the second column, separated by space).
generate_manifest() {
  log ">> generating MANIFEST.json"
  local manifest_file="$REPO_ROOT/MANIFEST.json"
  local tmp="${manifest_file}.tmp.$$"

  local -a tags
  mapfile -t tags < <(list_local_versions)

  {
    echo "{"
    local first_tag=1
    for v in "${tags[@]}"; do
      local tag
      tag="$(version_to_tag "$v")"
      # list_assets_full_for prints `name url` per line. We capture the
      # full output (sorted by name) and parse it. Empty releases get
      # `{}` so the manifest reflects every local release, not just
      # the ones that already have assets.
      local pairs
      pairs="$(list_assets_full_for "$tag")"

      if (( first_tag )); then first_tag=0; else echo ","; fi
      printf '  "%s": {' "$tag"
      if [[ -n "$pairs" ]]; then
        echo
        local first_asset=1
        while read -r name url; do
          [[ -z "$name" ]] && continue
          # Strip the file extension to get the manifest key:
          #   windows-amd64.zip        -> windows-amd64
          #   linux-glibc-amd64.tar.gz -> linux-glibc-amd64
          local key
          case "$name" in
            *.zip)    key="${name%.zip}" ;;
            *.tar.gz) key="${name%.tar.gz}" ;;
            *)        key="$name" ;;
          esac
          if (( first_asset )); then first_asset=0; else echo ","; fi
          printf '    "%s": "%s"' "$key" "$url"
        done <<< "$pairs"
        printf "\n  }"
      else
        # Empty release: just close the brace inline.
        printf "}"
      fi
    done
    echo
    echo "}"
  } > "$tmp"

  # JSON-validate if we have python3 (CI / macOS). If not (some Windows
  # hosts), we still trust the writer and move on.
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import json,sys; json.load(open('$tmp'))" 2>/dev/null; then
      err "  generated manifest failed JSON validation; aborting"
      exit 1
    fi
  fi

  mv "$tmp" "$manifest_file"
  ok "  wrote $manifest_file"
}
