#!/usr/bin/env bash
# =============================================================================
#  10-targets/_helpers.sh — shared build functions for every target.
# =============================================================================
#
#  Source each file in 10-targets/<target>.sh to register a `build_<target>()`
#  function. They in turn call the helpers in this file. We keep them all in
#  one place because most of the dispatch logic (docker mount + msys/git-bash
#  path handling, msys2 path quirks, etc.) is shared between the Linux
#  targets; splitting these into per-target files would duplicate ~200 lines
#  of hairy integration logic four times over.
#
#  Per-target build functions:
#    * docker_build_linux  <target> <version> <source_tarball>
#    * native_build_macos  <target> <version>     (DARWIN_ARCH env-controlled)
#    * process_windows_zip <target> <version>
# =============================================================================

# -----------------------------------------------------------------------------
#  docker_build_linux — used by all 4 linux-{glibc,musl}-{amd64,arm64}
# -----------------------------------------------------------------------------
docker_build_linux() {
  # docker_build_linux <target> <version> <source_tarball>
  #  Echoes the path to the resulting tarball on stdout.
  local target="$1" v="$2" tarball="$3"
  local platform="${TARGET_DOCKER_PLATFORM[$target]:-}"
  local image="${TARGET_DOCKER_IMAGE[$target]:-}"
  local deps_cmd="${TARGET_DEPS_CMD[$target]:-}"
  local asset="${TARGET_ASSET[$target]:-}"

  local runner="$SRC_TEMP/build_runner_${asset}.sh"
  local out="$DIST/$asset"

  mkdir -p "$SRC_TEMP"
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
# Strip everything that isn't needed at runtime. The lib/*/include dir is
# KEPT — hex deps compile .erl with `-include_lib("app/include/*.hrl")` and
# batamanta compiles the release with this ERTS as ROOTDIR.
rm -rf lib/*/src  lib/*/test  lib/*/examples
rm -f  InstallInfo  Install.ini
tar -czf /dist/$asset -C /opt/erlang/lib/erlang .
EOF

  # Resolve the ARCH placeholder at run time inside the container.
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
  if [[ "${OSTYPE:-}" == msys* ]] || uname -s 2>/dev/null | grep -qi mingw; then
    local tarball_win dist_win runner_win
    tarball_win="$(cygpath -w "$tarball")"
    dist_win="$(cygpath -w "$DIST")"
    runner_win="$(cygpath -w "$runner")"
    local entrypoint="${TARGET_ENTRYPOINT[$target]:-sh}"
    if [[ "${BATAMANTA_DRY_RUN:-0}" == "1" ]]; then
      printf '  [dry-run] docker run --rm --privileged --net=host --platform %s -v %s:/src.tar.gz:ro -v %s:/dist -v %s:/build.sh:ro %s %s /build.sh\n' \
        "$platform" "$tarball_win" "$dist_win" "$runner_win" "$image" "$entrypoint"
    else
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
#  native_build_macos — used by darwin-arm64 (and darwin-amd64 if/when a paid
#  macos-12 runner is available). DARWIN_ARCH controls which arch the build
#  is for; default 'arm64'.
# -----------------------------------------------------------------------------
native_build_macos() {
  # native_build_macos <target> <version>
  #  Echoes the path to the resulting tarball on stdout.
  local target="$1" v="$2"
  local arch="${DARWIN_ARCH:-arm64}"
  local asset="${TARGET_ASSET[$target]:-}"
  local tarball out
  tarball="$(download_source_tarball "$v")" || return 1
  out="$DIST/$asset"

  local build_dir="$SRC_TEMP/otp_src_${v}_build"
  rm -rf "$build_dir" "$out"
  mkdir -p "$build_dir"
  tar -xzf "$tarball" -C "$build_dir" --strip-components=1 \
    || { err "extract failed for $tarball"; return 1; }
  (
    cd "$build_dir"
    export MAKEFLAGS="-j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    ./otp_build autoconf >/dev/null
    ./configure --prefix=/opt/erlang \
      --without-javac --without-odbc --without-wx \
      --without-debugger --without-observer \
      --with-ssl=/opt/homebrew/opt/openssl@3 >/dev/null \
      || ./configure --prefix=/opt/erlang \
         --without-javac --without-odbc --without-wx \
         --without-debugger --without-observer \
         --with-ssl=/usr/local/opt/openssl@3 >/dev/null \
      || ./configure --prefix=/opt/erlang \
         --without-javac --without-odbc --without-wx \
         --without-debugger --without-observer \
         --without-ssl >/dev/null \
      || { err "configure failed for OTP $v on darwin-$arch"; return 1; }
    make $MAKEFLAGS > /dev/null 2>&1 || { err "make failed"; return 1; }
    make install > /dev/null 2>&1 || { err "make install failed"; return 1; }
    cd /opt/erlang/lib/erlang
    sed -i '' 's|^ROOTDIR=.*|ROOTDIR="$(dirname "$(dirname "$(realpath "$0")")")"|' bin/erl
    sed -i '' 's|^ROOTDIR=.*|ROOTDIR="$(dirname "$(dirname "$(realpath "$0")")")"|' bin/start
    rm -rf lib/*/src lib/*/test lib/*/examples
    rm -f  InstallInfo Install.ini
    # Use COPYFILE_DISABLE to skip macOS xattrs/ACLs/resource-fork metadata;
    # otherwise the tarball size doesn't match what `gh release upload` reports
    # as Content-Length and GitHub returns 403 "Bad Content-Length".
    COPYFILE_DISABLE=1 tar -czf "$out" -C /opt/erlang/lib/erlang .
  ) || return 1

  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  process_windows_zip — used by windows-amd64. We don't compile from source
#  on Windows; instead we download the upstream precompiled zip, strip the
#  docs/test/src trees, fix the ROOTDIR sed lines, and re-zip.
# -----------------------------------------------------------------------------
process_windows_zip() {
  # process_windows_zip <target> <version>
  local target="$1" v="$2"
  local asset="${TARGET_ASSET[$target]:-}"
  local out="$DIST/$asset"
  local zip
  zip="$(download_precompiled "$target" "$v")" || return 1

  local extract_dir="$SRC_TEMP/win_$v"
  rm -rf "$extract_dir" "$out"
  mkdir -p "$extract_dir"
  unzip -q "$zip" -d "$extract_dir" || { err "unzip failed for $zip"; return 1; }

  # The upstream zip layout is `otp_win64_<v>` (one folder at root). If
  # we find that folder, cd into it; otherwise assume the extract is flat.
  if [[ -d "$extract_dir/otp_win64_$v" ]]; then
    extract_dir="$extract_dir/otp_win64_$v"
  fi

  (
    cd "$extract_dir"
    # Fix the ROOTDIR sed lines so the resulting tree can be embedded as
    # the release's ERTS without an absolute path baked in.
    if [[ -f bin/erl ]]; then
      sed -i 's|set ROOTDIR=.*|set ROOTDIR=%~dp0\\..\\|' bin/erl.bat 2>/dev/null || true
      sed -i 's|ROOTDIR=.*|ROOTDIR="$(cd "$(dirname "$0")/.." && pwd)"|' bin/erl 2>/dev/null || true
    fi
    rm -rf src test examples 2>/dev/null || true
    # Repackage. zip on macOS is the system BSD zip; on Linux it's the
    # Info-ZIP one. Both accept -r -q. Output written under $DIST.
    (cd "$extract_dir" && zip -r -q "$out" .) || { err "zip failed"; return 1; }
  ) || return 1

  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
#  Cell upload (used by all per-target build_*() functions)
# -----------------------------------------------------------------------------
upload_cell() {
  # upload_cell <target> <version> <asset_path>
  #  Registers an empty release if missing, uploads the asset, and writes
  #  a single manifest entry. Caller is build_target().
  local target="$1" v="$2" asset_path="$3"
  if [[ "${BATAMANTA_NO_UPLOAD:-0}" == "1" ]]; then
    log "    --no-upload: $asset_path built but not pushed"
    return 0
  fi
  local tag="OTP-$v"
  local title="Erlang/OTP $v"
  local notes="Automated build of $(basename "$asset_path") for Erlang/OTP $v ($target)."
  create_release "$tag" "$title" "$notes" || return 1
  upload_asset "$tag" "$asset_path" || return 1
  local key="${asset_path##*/}"
  key="${key%.tar.gz}"
  key="${key%.zip}"
  # Mirror key naming: 'linux-glibc-amd64.tar.gz' -> 'linux-glibc-amd64'
  local url="https://github.com/$REPO/releases/download/$tag/$(basename "$asset_path")"
  manifest_set_entry "$v" "$key" "$url"
}
