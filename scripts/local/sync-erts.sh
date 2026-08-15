#!/usr/bin/env bash
# sync-erts.sh — single entry point to keep Lorenzo-SF/Batamanta---ERTS-repository
# in sync with erlang/otp.
#
# Two modes:
#
# 1. INTERACTIVE (default, no flags) — for running on your local machine:
#       ./scripts/local/sync-erts.sh
#    Asks whether to wipe every release ("borrón y cuenta nueva") or just
#    update what's missing, then detects the host OS/architecture and runs
#    the `regenerate-*` scripts from this directory that this host can
#    actually build:
#       Linux x86_64  -> regenerate-windows-amd64.sh + regenerate-linux-amd64.sh
#       Linux aarch64 -> regenerate-windows-amd64.sh + regenerate-linux-arm64.sh
#       macOS arm64   -> regenerate-darwin.sh         + regenerate-linux-arm64.sh
#       macOS x86_64  -> regenerate-darwin.sh (DARWIN_ARCH=amd64) + regenerate-linux-amd64.sh
#       Windows       -> regenerate-windows-amd64.sh
#    Finally rewrites MANIFEST.json from the live release set.
#
# 2. CI mode (flags) — the same code the workflow (.github/workflows/erts.yml)
#    runs. Idempotent: re-running picks up only the diff.
#       --releases-only                create missing empty releases
#       --version=V <target>           build+upload one (target, version) cell
#       --manifest-only                only rewrite MANIFEST.json
#       regenerate-from-zero           DESTRUCTIVE wipe (asks first when TTY)
#
# Auth: we intentionally DON'T do an upfront auth check. Detecting the
# difference between web OAuth and a fine-grained PAT is fragile, and the
# fine-grained PAT path is painful to keep working. Instead, every call to
# `gh release create` / `gh release upload` / `gh release delete` is wrapped
# in `gh_with_auth_hint` (in lib-sync.sh) which prints a single friendly hint
# on auth failures — just the four lines that fix it:
#
#     unset GH_TOKEN
#     unset GITHUB_TOKEN
#     gh auth logout
#     gh auth login
#
# Usage:
#   ./scripts/local/sync-erts.sh                       # interactive (wipe? + host targets)
#   ./scripts/local/sync-erts.sh --wipe                # interactive, force wipe
#   ./scripts/local/sync-erts.sh --no-wipe             # interactive, update only
#   ./scripts/local/sync-erts.sh 28.4.2                # interactive, only that version
#   ./scripts/local/sync-erts.sh linux-glibc-amd64     # interactive, only that target
#   ./scripts/local/sync-erts.sh --releases-only       # CI: create missing releases
#   ./scripts/local/sync-erts.sh --manifest-only       # CI: only rewrite MANIFEST.json
#   ./scripts/local/sync-erts.sh --version=28.4.2 --no-manifest linux-glibc-amd64  # CI cell
#   ./scripts/local/sync-erts.sh regenerate-from-zero  # DESTRUCTIVE (asks when TTY)

# Refuse to run on bash < 5 (macOS still ships 3.2 as /bin/bash). Sourced
# as the very first thing after the shebang so the failure is immediate.
. "$(dirname "${BASH_SOURCE[0]}")/../_bash_guard.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib-sync.sh
source "$SCRIPT_DIR/lib-sync.sh"

# ── Args ────────────────────────────────────────────────────────────────
ONLY_TARGETS=()
EXTRA_ARGS=()          # version strings passed through to the regenerate-* scripts
ONLY_VERSION=""
DO_WIPE=""             # "" = ask, "1" = wipe, "0" = update only
REGEN_FROM_ZERO=0
DO_BUILD=1
DO_MANIFEST=1
DO_RELEASE_SYNC=1
DO_TARGET_SYNC=1
CI_MODE=0              # set when any CI-only flag is present

usage() {
  cat <<EOF
Usage: $0 [options] [target...|version...]

Interactive (default):
  $0                     ask wipe?, then build what this host can (regenerate-*)
  $0 --wipe              borrón y cuenta nueva (no ask)
  $0 --no-wipe           update only — build what's missing (no ask)
  $0 28.4.2              only that OTP version
  $0 linux-glibc-amd64   only that target

Targets (any combination):
  windows-amd64
  darwin-arm64
  linux-glibc-amd64
  linux-glibc-arm64
  linux-musl-amd64
  linux-musl-arm64

CI options (used by .github/workflows/erts.yml):
  --no-build        Don't build any assets; only upload what's already in dist/.
  --no-upload       Build any missing assets but don't push them to GitHub.
  --manifest-only   Only rewrite MANIFEST.json; skip release sync and asset sync.
  --no-manifest     Don't rewrite MANIFEST.json; only do release + asset sync.
  --releases-only   Only sync releases; skip asset sync and manifest.
  --assets-only     Only do the per-target asset sync; skip release sync + manifest.
  --version=V       Restrict the per-target sync to a single OTP version.
  regenerate-from-zero
                    DESTRUCTIVE. Delete every release in the repo (asks first
                    when stdin is a TTY), then exit — CI then rebuilds.

Environment:
  REPO                 full "owner/name" of the erts repo (default Lorenzo-SF/Batamanta---ERTS-repository)
  MIN_OTP_VERSION      minimum OTP version to consider (default 27.0)
  GH_TOKEN / GITHUB_TOKEN   must grant Contents: write on the repo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --wipe)    DO_WIPE=1; shift ;;
    --no-wipe) DO_WIPE=0; shift ;;
    --no-build) DO_BUILD=0; SYNC_BUILD=0; CI_MODE=1; shift ;;
    --no-upload) DO_BUILD=1; SYNC_BUILD=1; SYNC_UPLOAD=0; CI_MODE=1; shift ;;
    --manifest-only) DO_TARGET_SYNC=0; DO_RELEASE_SYNC=0; DO_MANIFEST=1; CI_MODE=1; shift ;;
    --no-manifest) DO_MANIFEST=0; CI_MODE=1; shift ;;
    --releases-only) DO_TARGET_SYNC=0; DO_MANIFEST=0; DO_RELEASE_SYNC=1; CI_MODE=1; shift ;;
    --assets-only) DO_RELEASE_SYNC=0; DO_MANIFEST=0; DO_TARGET_SYNC=1; CI_MODE=1; shift ;;
    --version=*) ONLY_VERSION="${1#--version=}"; CI_MODE=1; shift ;;
    regenerate-from-zero) REGEN_FROM_ZERO=1; shift ;;
    -*) err "unknown flag: $1"; usage; exit 2 ;;
    *)
      # Target name or OTP version string?
      ok=0
      for t in "${ALL_TARGETS[@]}"; do
        [[ "$1" == "$t" ]] && ok=1 && break
      done
      if (( ok )); then
        ONLY_TARGETS+=("$1")
      elif [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        EXTRA_ARGS+=("$1")
      else
        err "unknown argument: $1"
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────
# wipe_releases — delete every release in the repo (tags included) and
# reset MANIFEST.json to {}. Used by regenerate-from-zero and the
# interactive wipe path.
wipe_releases() {
  local tag
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    log "  deleting $tag"
    gh_with_auth_hint gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag || true
  done < <(gh release list --repo "$REPO" --limit 200 --json tagName 2>/dev/null |
    grep -oE '"tagName":"OTP-[^"]+"' |
    sed 's/^"tagName":"//;s/"$//')
  printf '{}\n' > "$REPO_ROOT/MANIFEST.json"
  ok "  wiped; MANIFEST.json reset"
}

# script_covers_any <script> <target...> — true if the regenerate-* script
# builds at least one of the requested targets.
script_covers_any() {
  local s="$1"; shift
  local joined=" $* "
  case "$s" in
    regenerate-windows-amd64.sh) [[ "$joined" == *" windows-amd64 "* ]] ;;
    regenerate-linux-amd64.sh)   [[ "$joined" == *" linux-glibc-amd64 "* || "$joined" == *" linux-musl-amd64 "* ]] ;;
    regenerate-linux-arm64.sh)   [[ "$joined" == *" linux-glibc-arm64 "* || "$joined" == *" linux-musl-arm64 "* ]] ;;
    regenerate-darwin.sh)        [[ "$joined" == *" darwin-arm64 "* || "$joined" == *" darwin-amd64 "* ]] ;;
    *) return 1 ;;
  esac
}

# run_interactive_build — detect host OS/arch, pick the regenerate-* scripts
# this host can run, execute them (passing EXTRA_ARGS / ONLY_TARGETS through).
run_interactive_build() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  local -a scripts=()

  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64)   scripts=(regenerate-windows-amd64.sh regenerate-linux-amd64.sh) ;;
        aarch64|arm64)  scripts=(regenerate-windows-amd64.sh regenerate-linux-arm64.sh) ;;
        *) err "Linux arch no soportado por sync-erts.sh: $arch"; exit 2 ;;
      esac ;;
    Darwin)
      case "$arch" in
        arm64)  scripts=(regenerate-darwin.sh regenerate-linux-arm64.sh) ;;
        x86_64) export DARWIN_ARCH=amd64
                scripts=(regenerate-darwin.sh regenerate-linux-amd64.sh) ;;
        *) err "macOS arch no soportado por sync-erts.sh: $arch"; exit 2 ;;
      esac ;;
    MINGW*|MSYS*|CYGWIN*)
      scripts=(regenerate-windows-amd64.sh) ;;
    *)
      err "SO no soportado por sync-erts.sh: $os"
      err "  Linux/macOS: genera los targets de tu arquitectura."
      err "  Windows: usa regenerate-windows-amd64.sh directamente."
      exit 2 ;;
  esac

  # Narrow to the explicitly requested targets, if any.
  if [[ ${#ONLY_TARGETS[@]} -gt 0 ]]; then
    local -a filtered=()
    for s in "${scripts[@]}"; do
      if script_covers_any "$s" "${ONLY_TARGETS[@]}"; then
        filtered+=("$s")
      fi
    done
    scripts=("${filtered[@]}")
    if [[ ${#scripts[@]} -eq 0 ]]; then
      err "ninguno de los targets pedidos se puede generar en este host ($os/$arch)"
      exit 2
    fi
  fi

  log ">> host=$os/$arch — scripts: ${scripts[*]}"
  for s in "${scripts[@]}"; do
    log "==> ejecutando $s ${EXTRA_ARGS[*]}"
    bash "$SCRIPT_DIR/$s" "${EXTRA_ARGS[@]}" || err "  $s falló (rc=$?) — continúo con el siguiente"
  done
}

# ── regenerate-from-zero ─────────────────────────────────────────────────
# DESTRUCTIVE: delete every release (asks first when stdin is a TTY), then
# either continue with the host build (local) or exit for CI to rebuild.
if (( REGEN_FROM_ZERO )); then
  log ">> regenerate-from-zero: deleting every release in $REPO..."
  if [[ -t 0 ]]; then
    printf '\033[33m⚠  Esto borra TODOS los releases de %s. ¿Continuar? [y/N] \033[0m' "$REPO"
    read -r _ans
    if [[ "${_ans,,}" != "y" && "${_ans,,}" != "yes" ]]; then
      err "cancelado"
      exit 1
    fi
  fi
  wipe_releases
  if [[ -t 0 ]]; then
    # Local interactive wipe: continue straight into the host build.
    run_interactive_build
    generate_manifest
    ok ">> done (borrón y cuenta nueva completado)"
  else
    # CI: just wipe; the workflow's own jobs rebuild from scratch.
    ok "  wiped; now run the workflow to rebuild from scratch"
  fi
  exit 0
fi

# ── Interactive mode (no CI flags) ──────────────────────────────────────
if (( ! CI_MODE )); then
  local_wipe=0
  if [[ "$DO_WIPE" == "1" ]]; then
    local_wipe=1
  elif [[ "$DO_WIPE" == "0" ]]; then
    local_wipe=0
  elif [[ -t 0 ]]; then
    printf '\033[33m⚠  ¿Borrar TODOS los releases de %s (borrón y cuenta nueva)? [y/N] \033[0m' "$REPO"
    read -r _ans
    [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]] && local_wipe=1
  else
    log "stdin no es un TTY — modo actualización (no wipe)"
  fi

  if (( local_wipe )); then
    wipe_releases
  else
    log ">> modo actualización: solo se construirá lo que falte"
  fi

  # Keep the release mirror in sync with erlang/otp (creates empty releases
  # for new stable versions; no-op for versions that already exist).
  if (( DO_RELEASE_SYNC )); then
    sync_releases
  fi

  run_interactive_build
  generate_manifest
  ok ">> done"
  exit 0
fi

# ── CI mode ─────────────────────────────────────────────────────────────
# Default to all targets if none specified.
if [[ ${#ONLY_TARGETS[@]} -eq 0 ]]; then
  ONLY_TARGETS=("${ALL_TARGETS[@]}")
fi

# ── 1. Sync releases against erlang/otp ────────────────────────────────
if (( DO_RELEASE_SYNC )); then
  sync_releases
fi

# ── 2. Per-target asset sync ────────────────────────────────────────────
if (( DO_TARGET_SYNC )); then
  for t in "${ONLY_TARGETS[@]}"; do
    if [[ -n "$ONLY_VERSION" ]]; then
      sync_target_version "$t" "$ONLY_VERSION"
    elif (( DO_BUILD )); then
      sync_target "$t"
    else
      log ">> uploading existing assets for $t (no-build mode)"
      local_tag=""
      local_version=""
      local_file=""
      while read -r local_tag; do
        [[ -z "$local_tag" ]] && continue
        local_version="$(tag_to_version "$local_tag")"
        local_file="$(local_asset_path "$t" "$local_version")"
        if [[ -f "$local_file" ]]; then
          upload_asset "$t" "$local_version" || err "  upload failed for $local_tag"
        fi
      done < <(list_missing_for "$t")
    fi
  done
fi

# ── 3. Manifest (independent of any target) ────────────────────────────
if (( DO_MANIFEST )); then
  generate_manifest
fi

ok ">> done"