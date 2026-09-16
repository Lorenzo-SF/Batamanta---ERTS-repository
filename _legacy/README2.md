# Deprecated Fish scripts

These three scripts are the **original Fish shell** implementations. They
were kept for reference but are **no longer the canonical way to build the
ERTS tarballs** for this repository.

## What replaces them

The new implementation lives in the parent directory and is written in
**Bash**, so it runs identically on Linux, macOS, and Windows (via Git
Bash / WSL) without any extra runtime dependency:

| Old (Fish)                | New (Bash)                          |
|---------------------------|-------------------------------------|
| `erts-x86_64.fish`         | `erts-linux-glibc-amd64.sh`         |
| `erts-aarch64.fish`        | `erts-linux-glibc-arm64.sh`         |
|                           | `erts-linux-musl-amd64.sh`          |
|                           | `erts-linux-musl-arm64.sh`          |
| `erts-darwin.fish`         | `erts-darwin-arm64.sh`              |
| (none)                     | `erts-windows-amd64.sh`             |
| (none)                     | `erts-windows-arm64.sh`             |

The new scripts share all of their logic in `_lib.sh` (a single Bash file
with helpers for downloading sources, building with Docker, extracting
the upstream precompiled Windows zip, updating the manifest, etc.), and
they all emit **the same tarball layout**, so the upstream `Batamanta`
Elixir library consumes them without caring which target they came from.

The auto-detection of new OTP versions lives in `../detect-versions.sh`,
and the CI is in `../../.github/workflows/erts.yml`.

## Why we kept them

Mostly for archaeology: if you need to see the original `gen_docker_cmd`
incantation (the one that manually mounts the source tarball, runs
`./otp_build autoconf && ./configure && make install`, etc.), the Fish
versions are the most readable place to look. The new `_lib.sh`
implementation does the same thing, but it's been DRY-ed up across the
seven target wrappers.

## If you really need to run one

You need Fish installed (not standard on Windows or most Linux distros):

```sh
sudo apt install fish   # Debian/Ubuntu
brew install fish        # macOS
```

Then:

```sh
fish deprecated/erts-x86_64.fish
```
