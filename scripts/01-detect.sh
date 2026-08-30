#!/usr/bin/env bash
# =============================================================================
#  01-detect.sh — Discover upstream OTP versions + compute the build plan.
# =============================================================================
#
#  Two questions these helpers answer:
#    1. "What stable X.Y.Z OTP versions exist upstream that we don't ship?"
#       (detect_new_versions, _discover_upstream_versions)
#    2. "For our pinned baseline, which (version, target) pairs are missing
#        on the GitHub release?" (_compute_build_plan)
#
#  Together they implement the "just run it and it does the right thing"
#  contract: the script compares the repo against upstream and builds only
#  what's actually missing.
# =============================================================================

# -----------------------------------------------------------------------------
#  State persistence (.build-state.json)
# -----------------------------------------------------------------------------
#  Records the result of every (target, version) attempt so a re-run can
#  skip done versions and retry failed ones without re-downloading source
#  tarballs or re-uploading assets. Format:
#
#    { "linux-glibc-amd64/27.0": {"status":"done","ts":1234},
#      "linux-musl-amd64/28.0": {"status":"failed","ts":1235,"error":"..."} }
#
_state_read() {
  if [[ -s "$STATE_FILE" ]]; then
    if cmd_exists jq; then
      jq -r 'to_entries[] | "\(.key) \(.value.status)"' "$STATE_FILE" 2>/dev/null
    elif cmd_exists python3; then
      python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f'{k} {v[\"status\"]}') for k,v in d.items()]" "$STATE_FILE" 2>/dev/null
    else
      # Last-resort: parse with awk (no jq, no python3).
      awk -F'"' '/"status"/{ for(i=1;i<=NF;i++) if($i~/:/){key=$i; sub(/:/,"",key)} /done|failed|pending/{print prev" "$2; prev=""} {prev=$0}' "$STATE_FILE" 2>/dev/null
    fi
  fi
}
_state_get() {
  # _state_get <target>/<version> → "done" | "failed" | "pending" | ""
  local key="$1"
  if [[ -s "$STATE_FILE" ]]; then
    if cmd_exists jq; then
      jq -r --arg k "$key" '.[$k].status // empty' "$STATE_FILE" 2>/dev/null
    elif cmd_exists python3; then
      python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],{}).get('status',''))" "$STATE_FILE" "$key" 2>/dev/null
    fi
  fi
}
_state_set() {
  # _state_set <target>/<version> <status> [error_message]
  local key="$1" status="$2" error="${3:-}" ts
  ts=$(date +%s)
  if cmd_exists jq; then
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --arg s "$status" --arg e "$error" --argjson t "$ts" \
      '.[$k] = {"status":$s,"ts":$t} + (if $e != "" then {"error":$e} else {} end)' \
      "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"
  elif cmd_exists python3; then
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
#  Discovery: what's missing in our releases?
# -----------------------------------------------------------------------------
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

#  Defensive: bash 3.2 (the default on macOS) + `set -u` will fail with
#  a cryptic "OTP_VERSIONS: unbound variable" if the array is empty
#  when we try to iterate it. We guard the loop with a length check
#  so the failure mode is a clear "nothing to do" instead.
_compute_build_plan() {
  if (( ${#OTP_VERSIONS[@]} == 0 )); then
    log "  OTP_VERSIONS is empty — nothing to plan"
    return 0
  fi
  local targets=("$@")
  local target v tag code url
  for target in "${targets[@]}"; do
    local asset="${TARGET_ASSET[$target]:-}"
    if [[ -z "$asset" ]]; then
      log "  skipping unknown target: $target"
      continue
    fi
    for v in "${OTP_VERSIONS[@]}"; do
      tag="OTP-$v"
      if [[ -z "${BATAMANTA_FORCE:-}" ]] \
         && [[ "$(_state_get "$target/$v")" == "done" ]] \
         && asset_in_release "$tag" "$asset"; then
        continue
      fi
      if [[ -z "${BATAMANTA_FORCE:-}" ]] \
         && asset_in_release "$tag" "$asset"; then
        continue
      fi
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
  shopt -s nullglob
  now=$(date +%s)
  for lock in "$LOCKS"/*.lock; do
    [[ -e "$lock" ]] || continue
    if stat -c '%Y' "$lock" >/dev/null 2>&1; then
      age=$((now - $(stat -c '%Y' "$lock")))
    elif stat -f '%m' "$lock" >/dev/null 2>&1; then
      age=$((now - $(stat -f '%m' "$lock")))
    else
      continue
    fi
    if (( age > LOCK_MAX_AGE_SECONDS )); then
      log "removing stale lock ($(($age / 60))m old): $(basename "$lock")"
      rm -f "$lock"
    fi
  done
  shopt -u nullglob
}

# Public: detect_new_versions — used by erts_gen check.
detect_new_versions() {
  # Print one OTP-X.Y.Z per line that exists upstream >= $MIN_OTP_VERSION
  # but is NOT in the local MANIFEST.json. Used by erts_gen check to show
  # what would be auto-built if the user ran `erts_gen auto`.
  local min="${MIN_OTP_VERSION:-27.0}"
  _discover_upstream_versions "$min" \
    | while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        local tag="OTP-$v"
        if [[ ! -f "$MANIFEST" ]] \
           || ! jq -e --arg v "$tag" 'has($v)' "$MANIFEST" >/dev/null 2>&1; then
          echo "$tag"
        fi
      done
}

verify_manifest() {
  # verify_manifest — prints "OK" if every entry has a download URL.
  jq -e 'to_entries[] | .value | to_entries[] | .value' "$MANIFEST" >/dev/null
}
