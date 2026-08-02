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
LOG_PREFIX="[batamanta-erts]"

mkdir -p "$SRC_TEMP" "$DIST" "$LOCKS"

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
  28.2 28.3 28.4
)

# -----------------------------------------------------------------------------
#  Logging & dry-run
# -----------------------------------------------------------------------------
log()   { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
warn()  { printf '%s \033[33mWARN\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; }
err()   { printf '%s \033[31mERR\033[0m  %s\n' "$LOG_PREFIX" "$*" >&2; }
ok()    { printf '%s \033[32mOK\033[0m\n'   "$LOG_PREFIX" "$*" >&2; }

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
  gh release create "$tag" --title "$title" --notes "$notes"
}

upload_asset() {
  # upload_asset <tag> <asset_path>
  local tag="$1" path="$2"
  gh release upload "$tag" "$path" --clobber
}

# -----------------------------------------------------------------------------
#  Source-tarball download
# -----------------------------------------------------------------------------
download_source_tarball() {
  # download_source_tarball <version>
  #  Echoes the path to the downloaded source tarball.
  #  Reuses a cached copy if present.
  local v="$1"
  local out="$SRC_TEMP/otp_src_$v.tar.gz"
  if [[ -s "$out" ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  log "downloading otp_src_$v.tar.gz"
  curl -fLsL --retry 5 \
    "https://github.com/erlang/otp/releases/download/OTP-$v/otp_src_$v.tar.gz" \
    -o "$out"
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
  log "downloading precompiled otp_win64_$v.zip from erlang/otp"
  curl -fLsL --retry 5 \
    "https://github.com/erlang/otp/releases/download/OTP-$v/otp_win64_$v.zip" \
    -o "$out"
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
if [[ -f /lib/ld-musl-\$ARCH.so.1 ]]; then
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

  run docker run --rm --privileged --net=host \
    --platform "$platform" \
    --ulimit nofile=1024:1024 \
    -v "$tarball:/src.tar.gz:ro" \
    -v "$DIST:/dist" \
    -v "$runner:/build.sh:ro" \
    "$image" sh /build.sh

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
  local v="$1" key="$2" url="$3"
  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq --arg v "OTP-$v" --arg k "$key" --arg u "$url" \
       '.[$v][$k] = $u' "$MANIFEST" > "$tmp"
    mv "$tmp" "$MANIFEST"
  else
    err "jq is required for manifest updates (apt install jq / brew install jq)"
    return 1
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
  # build_target <target> [version...]
  #  For each (target, version) pair, build if missing, then upload + update
  #  the manifest. Skips silently when the release asset is already present
  #  (unless BATAMANTA_FORCE=1).
  local target="$1"
  shift
  local versions=("$@")
  if [[ ${#versions[@]} -eq 0 ]]; then
    versions=("${OTP_VERSIONS[@]}")
  fi

  local asset="${TARGET_ASSET[$target]}"
  local key="${asset%.tar.gz}"
  if [[ "$asset" == *.zip ]]; then
    key="${asset%.zip}"
  fi
  log "==> target=$target  asset=$asset  key=$key"

  if [[ -z "${TARGET_DOCKER_IMAGE[$target]:-}" \
     && -z "${TARGET_USES_PRECOMPILED[$target]:-}" \
     && "$target" != "darwin-amd64" \
     && "$target" != "darwin-arm64" ]]; then
    err "unknown target: $target"
    return 1
  fi

  for v in "${versions[@]}"; do
    local tag="OTP-$v"
    if ! release_exists "$tag"; then
      : # We'll create the release on first upload; nothing to do here.
    fi
    if [[ "${BATAMANTA_FORCE:-0}" != "1" ]] \
       && asset_in_release "$tag" "$asset"; then
      log "  $asset already on $tag — skip"
      continue
    fi

    log "  building $v for $target"
    local out
    case "$target" in
      linux-glibc-*|linux-musl-*)
        local src
        src="$(download_source_tarball "$v")"
        out="$(docker_build_linux "$target" "$v" "$src")"
        ;;
      darwin-amd64|darwin-arm64)
        local src
        src="$(download_source_tarball "$v")"
        local build_dir="$SRC_TEMP/build_$v"
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        tar -xzf "$src" -C "$build_dir" --strip-components=1
        out="$(native_build_macos "$v" "$src")"
        rm -rf "$build_dir" "$SRC_TEMP/opt_erlang"
        ;;
      windows-amd64)
        out="$DIST/$asset"
        process_windows_zip "$v" "$out"
        ;;
      *)
        err "  unknown target $target"; return 1 ;;
    esac

    log "  uploading $asset to $tag"
    create_release "$tag" "Erlang/OTP $v" \
      "Automated build of $asset for Erlang/OTP $v."
    run upload_asset "$tag" "$out"

    log "  updating manifest"
    local url="https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases/download/$tag/$asset"
    manifest_set_entry "$v" "$key" "$url"
    ok "$v / $target"
  done

  rm -rf "$SRC_TEMP"
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
#  Trap to clean up on exit
# -----------------------------------------------------------------------------
cleanup() {
  rm -rf "$SRC_TEMP" 2>/dev/null || true
  rm -rf "$LOCKS"     2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
#  Entrypoint: when sourced from a per-target script, the script does its
#  own `build_target <target>` call. We don't auto-execute here so this file
#  can be safely sourced from other contexts (e.g. unit tests, the CI step).
# =============================================================================
