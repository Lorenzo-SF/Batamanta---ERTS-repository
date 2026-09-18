#!/usr/bin/env bash
# =============================================================================
#  04-manifest.sh — regenerate MANIFEST.json from the live GitHub release set.
# =============================================================================
#
#  Reads every OTP-* release via `gh release view --json assets`, maps the
#  asset filenames into the canonical manifest keys (linux-glibc-amd64, …),
#  and writes the sorted JSON to MANIFEST.json.
#
#  Validation: prefer jq (always installed in CI). If we fall back to
#  python3, gate it on a working interpreter — asdf's python3 shim fails
#  with exit 126 when there's no .tool-versions, which would otherwise be
#  misread as "JSON invalid".
# =============================================================================

list_assets_full_for() {
  # list_assets_full_for <tag> — one line per asset: "<name> <url>"
  # Uses the portable Erlang escript as a JSON parser (no jq dependency).
  local tag="$1"
  local escript="$REPO_ROOT/scripts/parse-release-assets.escript"
  local escript_runner
  escript_runner="$(command -v escript || true)"

  if [[ -n "$escript_runner" && -f "$escript" ]]; then
    gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null \
      | "$escript_runner" "$escript" 2>/dev/null | sort || true
  else
    # Fallback: pure-bash regex (handles only `name` + `url`).
    # `|| true`: an empty release (fresh tag, no assets yet) makes grep
    # exit 1, which under `set -o pipefail` + `set -e` would silently
    # kill the whole manifest regen. Empty input → empty output instead.
    #
    # URLs stay ABSOLUTE (https://github.com/...): batamanta's Fetcher
    # curls them verbatim, so stripping the domain would break every
    # download.
    gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null \
      | grep -oE '"name":"[^"]+"|"url":"https://github.com/[^"]+"' \
      | paste - - | sed 's/"name":"//;s/"[[:space:]]*"url":"/ /;s/"$//' | sort || true
  fi
}

list_assets_for() {
  list_assets_full_for "$1" | awk '{print $1}'
}

manifest_set_entry() {
  # manifest_set_entry <version> <key> <url>
  # In CI jq is always installed. In local runs (especially on Windows Git
  # Bash) jq is usually missing — the per-asset manifest update then has
  # to fall back gracefully, otherwise the whole build aborts on the very
  # first release. We log a warning and keep going; the safety net is
  # `scripts/parse-release-assets.escript` which rebuilds the whole
  # manifest from the actual release assets after the run.
  local v="$1" key="$2" url="$3"
  if cmd_exists jq; then
    local tmp
    tmp="$(mktemp)"
    if jq --arg v "OTP-$v" --arg k "$key" --arg u "$url" \
         '.[$v][$k] = $u' "$MANIFEST" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$MANIFEST"
    else
      warn "manifest_set_entry: jq failed for OTP-$v/$key (regen will fix it later)"
      rm -f "$tmp"
    fi
  elif cmd_exists python3 && python3 -c "exit(0)" 2>/dev/null; then
    # Real python3 (not a broken asdf shim)
    if ! python3 -c "
import json, sys
p = sys.argv[1]; v = 'OTP-' + sys.argv[2]; k = sys.argv[3]; u = sys.argv[4]
try: d = json.load(open(p))
except: d = {}
d.setdefault(v, {})[k] = u
with open(p, 'w') as f: json.dump(d, f, indent=2)
" "$MANIFEST" "$v" "$key" "$url" 2>/dev/null; then
      warn "manifest_set_entry: python failed (regen will fix it later)"
    fi
  else
    warn "manifest_set_entry: no jq / python3 available (regen will fix it later)"
  fi
}

manifest_read() {
  if [[ -s "$MANIFEST" ]]; then
    cat "$MANIFEST"
  else
    echo '{}'
  fi
}

manifest_has_entry() {
  # manifest_has_entry <version> <key>
  local v="$1" key="$2"
  [[ -s "$MANIFEST" ]] || return 1
  if cmd_exists jq; then
    jq -e --arg v "OTP-$v" --arg k "$key" '.[$v][$k] // false' "$MANIFEST" >/dev/null 2>&1
  else
    grep -q "\"$key\"" "$MANIFEST" || return 1
  fi
}

# -----------------------------------------------------------------------------
#  generate_manifest — the main entry point
# -----------------------------------------------------------------------------
generate_manifest() {
  log ">> generating MANIFEST.json"
  local manifest_file="$MANIFEST"
  local tmp="${manifest_file}.tmp.$$"

  local -a tags
  # Newest-first: matches the committed file's convention, so regens only
  # diff on real changes (added/removed assets), not on ordering.
  # (list_local_versions itself stays ascending — sync_releases feeds it
  # to `comm`, which requires both inputs in the same order.)
  mapfile -t tags < <(list_local_versions | sort -Vr)

  {
    echo "{"
    local first_tag=1
    for v in "${tags[@]}"; do
      local tag
      tag="$(version_to_tag "$v")"
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
        printf "}"
      fi
    done
    echo
    echo "}"
  } > "$tmp"

  # JSON validation — see header. Prefer jq; fall back to python3 only if
  # it's not just an asdf shim; never let a broken shim masquerade as
  # "JSON invalid".
  if cmd_exists jq; then
    if ! jq empty "$tmp" 2>/dev/null; then
      err "  generated manifest failed JSON validation (jq); aborting"
      rm -f "$tmp"
      exit 1
    fi
  elif cmd_exists python3 && python3 -c "exit(0)" 2>/dev/null; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" 2>/dev/null; then
      err "  generated manifest failed JSON validation (python3); aborting"
      rm -f "$tmp"
      exit 1
    fi
  else
    warn "  no jq / python3 available, skipping manifest validation (writer trusts its output)"
  fi

  mv "$tmp" "$manifest_file"
  ok "  wrote $manifest_file"
}

tag_to_version() { printf '%s' "${1#OTP-}"; }
version_to_tag() { printf 'OTP-%s' "$1"; }
version_ge() {
  # version_ge a b → true iff a >= b
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}
