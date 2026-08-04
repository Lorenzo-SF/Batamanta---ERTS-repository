<p align="center">
  <img src="/Assets/batamantaman-sit.png" alt="Batamanta Elixir Man">
</p>

Welcome to the **Batamanta ERTS Repository**! This project serves as a
centralized, ready-to-use archive for pre-compiled Erlang Run-Time System
(ERTS) binaries.

If you want to skip the lengthy Erlang/OTP compilation process and get
straight to building your Elixir/Erlang applications, you are in the
right place.

> **⚠️ macOS users**: the build scripts require **bash 4+** (for associative
> arrays). macOS ships bash 3.2.57 as `/bin/bash`, which is from 2007. Install
> bash 5 via Homebrew and re-run with the new interpreter:
> ```bash
> brew install bash
> /opt/homebrew/bin/bash ./scripts/local/regenerate-darwin.sh
> ```
> The script will refuse to run on bash < 4 and tell you exactly what to do.

---

## 🎯 Supported Platforms & Architectures

We provide pre-compiled binaries for the following **7 targets**:

| Target | OS | Arch | How it's built |
|---|---|---|---|
| `linux-glibc-amd64` | Linux | x86_64 | Compiled from source in `ubuntu:22.04` Docker |
| `linux-glibc-arm64` | Linux | aarch64 | Compiled from source in `ubuntu:22.04` Docker |
| `linux-musl-amd64`  | Linux | x86_64 | Compiled from source in `alpine:3.19` Docker |
| `linux-musl-arm64`  | Linux | aarch64 | Compiled from source in `alpine:3.19` Docker |
| `darwin-amd64`      | macOS | x86_64 | Compiled natively on Mac (Intel or Rosetta) |
| `darwin-arm64`      | macOS | aarch64 | Compiled natively on Apple Silicon |
| `windows-amd64`     | Windows | x86_64 | Re-packaged from the official `erlang/otp` prebuilt zip |

Every tarball/zip has the **same internal layout** so the upstream
`batamanta` Elixir library can consume any target with the same code
path.

### Windows arm64 is **not** supported

The Erlang/OTP project does not publish precompiled arm64 Windows
binaries — only `otp_win64_*.zip` (x86_64). Until upstream changes
that, callers on Windows arm64 should use the `windows-amd64` build,
which runs on arm64 via the x86_64 emulation layer.

The upstream `batamanta` library reflects this by not having a
`:windows_arm64` target.

### OTP version floor: **27.0**

We only ship ERTS for OTP ≥ 27.0. The 25.x and 26.x series are EOL
upstream and were dropped from the pinned baseline when the repo was
rebuilt. The CI filter (`DETECT_MIN_VERSION=27.0`) and the pinned
array in `_lib.sh` enforce the same floor.

---

## 🚀 How the build pipeline works

```
scripts/_lib.sh                    ← one Bash file, all the logic
scripts/erts-linux-glibc-amd64.sh  ┐
scripts/erts-linux-glibc-arm64.sh  │
scripts/erts-linux-musl-amd64.sh   ├─ thin wrappers, each ~3 lines,
scripts/erts-linux-musl-arm64.sh   │  just `build_target <target>`
scripts/erts-darwin-amd64.sh       │
scripts/erts-darwin-arm64.sh       │
scripts/erts-windows-amd64.sh      ┘
scripts/detect-versions.sh         ← queries erlang/otp API, prints missing versions
scripts/local/                     ← the targets CI doesn't cover:
  regenerate-windows-amd64.sh        • Windows amd64 (your Windows + Git Bash)
  regenerate-linux-amd64.sh         • Linux amd64 (your Windows + Docker)
  regenerate-darwin.sh              • macOS arm64/amd64 (your Mac)
  regenerate-manifest.py            • safety net: rebuild MANIFEST.json
  README.md                          from actual release assets
.github/workflows/erts.yml         ← weekly schedule + manual trigger
```

All scripts are plain **Bash**, so they run identically on Linux, macOS,
and Windows (via Git Bash) without needing Fish or any other extra
runtime.

---

## 🛠️ Building locally

The CI handles the 4 Linux targets automatically. For the other 3
(Windows amd64 + the two macOS variants), use the scripts in
`scripts/local/`. See [scripts/local/README.md](scripts/local/README.md)
for full details.

Quick examples:

```sh
# Linux glibc amd64 (Docker, your Windows/macOS/Linux machine)
./scripts/local/regenerate-linux-amd64.sh 28.4.2

# Windows amd64 (Git Bash, your Windows machine)
./scripts/local/regenerate-windows-amd64.sh 28.4.2

# macOS arm64 (your Apple Silicon Mac)
./scripts/local/regenerate-darwin.sh 28.4.2

# macOS amd64 (Intel Mac, or Apple Silicon via Rosetta — slower)
DARWIN_ARCH=amd64 ./scripts/local/regenerate-darwin.sh 28.4.2
```

After running any of these, sync the manifest:

```sh
./scripts/local/regenerate-manifest.py
```

That script walks every release in this repo, reads the actual attached
assets, and rebuilds `MANIFEST.json` so the upstream `batamanta` library
sees everything consistently.

Useful environment variables:

| Variable                     | Effect                                                                 |
|------------------------------|------------------------------------------------------------------------|
| `BATAMANTA_DRY_RUN=1`        | Print what would run, don't actually do anything                       |
| `BATAMANTA_FORCE=1`          | Rebuild even if the release asset is already present                    |
| `BATAMANTA_GITHUB_TOKEN=...` | Use this token for the GitHub API (raises the 60/h anonymous rate cap) |
| `DETECT_MIN_VERSION=28.0`    | (manifest regen only) only keep OTP versions ≥ 28.0                    |
| `DARWIN_ARCH=amd64`          | (darwin script only) build the Intel variant instead of arm64           |

---

## 🤖 CI

`.github/workflows/erts.yml` runs:

* **Weekly** (Monday 06:00 UTC) — calls `detect-versions.sh`, then for
  every missing (target, version) pair runs the corresponding wrapper,
  uploads the tarball/zip to the GitHub Release, and updates
  `MANIFEST.json`.
* **On push to `main`** when `MANIFEST.json`, `scripts/**`, or
  `erts.yml` change.
* **On pull requests to `main`** — only the cheap `lint` job, no builds.
* **Manually** via the Actions tab — pick a specific version and/or a
  subset of targets from the `workflow_dispatch` inputs.

The matrix covers the **4 Linux targets** (the 3 that need macOS or
Windows runners are not in the free matrix — see
`scripts/local/README.md` for the manual workflow).

Available `workflow_dispatch` inputs:

| Input                  | Default                                                  | Effect                                                                |
|------------------------|----------------------------------------------------------|-----------------------------------------------------------------------|
| `version`              | (empty — auto-detect)                                    | Build a single OTP version, e.g. `28.4.2`                             |
| `targets`              | `linux-glibc-amd64 linux-musl-amd64 linux-glibc-arm64 linux-musl-arm64` | Space- or comma-separated subset of the 7 supported targets |
| `regenerate_from_zero` | `false`                                                  | Delete every release and `MANIFEST.json`, then rebuild from scratch   |
| `min_version`          | `27.0`                                                   | Only build OTP versions ≥ this                                        |

---

## 📦 Releases

**All binaries are hosted in GitHub Releases**, not in the git source
tree (to keep the repo small and fast to clone).

* **Download:** Go to the
  [Releases](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases)
  page and grab the archive for your target OS and architecture from
  your desired OTP version.
* **Extract:** Unzip the archive into your preferred directory (e.g.
  `~/.local/share/erts`).
* **Update PATH:** Add the extracted `bin` directory to your system's
  PATH.

*Note: Our builds inject dynamic path discovery (`ROOTDIR` magic), so
the ERTS will work seamlessly no matter where you extract it!*

**Example (bash/zsh):**

```sh
# Extract the downloaded binary
mkdir -p ~/.local/share/erts/28.4
tar -xzf linux-glibc-amd64.tar.gz -C ~/.local/share/erts/28.4

# Add it to your PATH
export PATH=~/.local/share/erts/28.4/bin:$PATH
```

**Example (PowerShell):**

```powershell
# Extract
Expand-Archive windows-amd64.zip -DestinationPath $env:LOCALAPPDATA\erts\28.4

# Add to PATH (this session only)
$env:Path = "$env:LOCALAPPDATA\erts\28.4\bin;$env:Path"
```

---

## 🧹 What we strip from the upstream builds

The Linux and macOS builds are compiled from source, so we have full
control. We strip everything that isn't needed at runtime, which
shrinks the resulting tarball by **30-50%** compared to a stock
`make install`:

```sh
# Inside _lib.sh::docker_build_linux / native_build_macos
rm -rf lib/*/src  lib/*/include  lib/*/test  lib/*/examples
rm -f  InstallInfo  Install.ini
```

The Windows build is downloaded from upstream's prebuilt
`otp_win64_*.zip` and we apply the same clean-up:

```sh
# Inside _lib.sh::process_windows_zip
find . -type d \( -name src -o -name include -o -name test -o -name examples \) -exec rm -rf {} +
find . -type d -path '*/erts-*/doc' -exec rm -rf {} +
rm -f  InstallInfo Install.ini Uninstall.exe setup.exe
```

This means the Windows zip you get here is also noticeably smaller
than the one Erlang ships from `erlang.org` (we save roughly 30-50 MB
on docs + examples).
