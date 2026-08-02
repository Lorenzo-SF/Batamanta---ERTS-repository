<p align="center">
  <img src="/Assets/batamantaman-sit.png" alt="Batamanta Elixir Man">
</p>

Welcome to the **Batamanta ERTS Repository**! This project serves as a centralized, ready-to-use archive for pre-compiled Erlang Run-Time System (ERTS) binaries.

If you want to skip the lengthy Erlang/OTP compilation process and get straight to building your Elixir/Erlang applications, you are in the right place.

---

## 🎯 Supported Platforms & Architectures

We provide pre-compiled binaries for the following targets:

* **Linux (glibc):** `x86_64` & `aarch64` (Standard Ubuntu/Debian/etc.) — compiled from source with our custom build script
* **Linux (musl):**  `x86_64` & `aarch64` (Alpine and other musl-based distros) — compiled from source with our custom build script
* **macOS:**         `arm64` (Apple Silicon / M-series chips) — compiled natively from source
* **Windows:**       `x86_64` — re-packaged from the official `erlang/otp` prebuilt zip (faster & more reliable than cross-compiling in CI)
* **Windows:**       `arm64` — placeholder, see `erts-windows-arm64.sh` for status

Every tarball/zip has the **same internal layout** so the upstream `Batamanta` Elixir library can consume any target with the same code path.

---

## 🚀 How the build pipeline works

```
scripts/_lib.sh                    ← one Bash file, all the logic
scripts/erts-linux-glibc-amd64.sh  ┐
scripts/erts-linux-glibc-arm64.sh  │
scripts/erts-linux-musl-amd64.sh   ├─ thin wrappers, each ~3 lines,
scripts/erts-linux-musl-arm64.sh   │  just `build_target <target>`
scripts/erts-darwin-arm64.sh       │
scripts/erts-windows-amd64.sh      │
scripts/erts-windows-arm64.sh      ┘
scripts/detect-versions.sh         ← queries erlang/otp API, prints missing versions
.github/workflows/erts.yml         ← weekly schedule + manual trigger
```

All scripts are plain **Bash**, so they run identically on Linux, macOS, and
Windows (via Git Bash / WSL) without needing Fish or any other extra
runtime.

## 🛠️ Building locally

To build (or rebuild) a single target for a specific version:

```sh
# Linux glibc amd64
./scripts/erts-linux-glibc-amd64.sh 28.4.2

# Windows amd64
./scripts/erts-windows-amd64.sh 28.4.2

# Everything for every pinned version (long!)
./scripts/erts-linux-glibc-amd64.sh
./scripts/erts-linux-glibc-arm64.sh
./scripts/erts-linux-musl-amd64.sh
./scripts/erts-linux-musl-arm64.sh
./scripts/erts-darwin-arm64.sh       # must run on macOS
./scripts/erts-windows-amd64.sh
./scripts/erts-windows-arm64.sh
```

Useful environment variables:

| Variable                     | Effect                                                                 |
|------------------------------|------------------------------------------------------------------------|
| `BATAMANTA_DRY_RUN=1`        | Print what would run, don't actually do anything                       |
| `BATAMANTA_FORCE=1`          | Rebuild even if the release asset is already present                    |
| `BATAMANTA_GITHUB_TOKEN=...` | Use this token for the GitHub API (raises the 60/h anonymous rate cap) |

## 🤖 CI

`.github/workflows/erts.yml` runs:

* **Weekly** (Monday 06:00 UTC) — calls `detect-versions.sh`, then for every
  missing (target, version) pair runs the corresponding wrapper, uploads
  the tarball/zip to the GitHub Release, and updates `MANIFEST.json`.
* **Manually** via the Actions tab — pick a specific version and/or a
  subset of targets from the `workflow_dispatch` inputs.

The matrix covers all 7 targets. `darwin-arm64` runs on `macos-latest`;
the Linux ones use `ubuntu-latest` with the appropriate Docker image;
Windows uses `windows-latest`.

## 📦 Releases

**All binaries are hosted in GitHub Releases**, not in the git source tree
(to keep the repo small and fast to clone).

* **Download:** Go to the [Releases](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases) page and grab the archive for your target OS and architecture from your desired OTP version.
* **Extract:** Unzip the archive into your preferred directory (e.g. `~/.local/share/erts`).
* **Update PATH:** Add the extracted `bin` directory to your system's PATH.

*Note: Our builds inject dynamic path discovery (`ROOTDIR` magic), so the
ERTS will work seamlessly no matter where you extract it!*

**Example using Fish shell:**

```fish
# Extract the downloaded binary
mkdir -p ~/.local/share/erts/28.4
tar -xzf amd64-glibc.tar.gz -C ~/.local/share/erts/28.4

# Add it to your PATH
set -gx PATH ~/.local/share/erts/28.4/bin $PATH
```

## 🧹 What we strip from the upstream builds

The Linux and macOS builds are compiled from source, so we have full
control. We strip everything that isn't needed at runtime, which shrinks
the resulting tarball by **30-50%** compared to a stock `make install`:

```sh
# Inside _lib.sh::docker_build_linux / native_build_macos
rm -rf lib/*/src  lib/*/include  lib/*/test  lib/*/examples
rm -f  InstallInfo  Install.ini
```

The Windows build is downloaded from upstream's prebuilt `otp_win64_*.zip`
and we apply the same clean-up:

```sh
# Inside _lib.sh::process_windows_zip
find . -type d \( -name src -o -name include -o -name test -o -name examples \) -exec rm -rf {} +
find . -type d -path '*/erts-*/doc' -exec rm -rf {} +
rm -f  InstallInfo Install.ini Uninstall.exe setup.exe
```

This means the Windows tarball/zip you get here is also noticeably smaller
than the one Erlang ships from `erlang.org` (we save roughly 30-50 MB on
docs + examples).
