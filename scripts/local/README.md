# `scripts/local/` — manual ERTS regeneration

The CI workflow (`.github/workflows/erts.yml`) covers the 4 Linux targets
on every push to `main` and on a weekly schedule. The remaining 3
targets (Windows amd64 + the two macOS variants) require a runner that
isn't part of GitHub's free plan, so they live in **this directory** and
run on your local machine when you need them.

## Why split this way?

| Target | CI? | Where it runs instead |
|---|---|---|
| `linux-glibc-amd64` | ✅ (free) | — |
| `linux-musl-amd64` | ✅ (free) | — |
| `linux-glibc-arm64` | ✅ (free) | — |
| `linux-musl-arm64` | ✅ (free) | — |
| `windows-amd64` | ❌ | `regenerate-windows-amd64.sh` on your Windows + Git Bash |
| `darwin-amd64` | ❌ | `regenerate-darwin.sh` on a Mac (Intel) |
| `darwin-arm64` | ❌ | `regenerate-darwin.sh` on a Mac (Apple Silicon) |

Windows arm64 is **not supported** — the upstream `erlang/otp` project
doesn't publish precompiled arm64 Windows binaries. If you need ERTS on
Windows arm64, use the `windows-amd64` build (it runs on Windows arm64
via the x86_64 emulation layer). See the top-level `README.md` for the
full rationale.

## What each script does

| Script | What it does | Host | Time per version |
|---|---|---|---|
| `regenerate-windows-amd64.sh` | Downloads the official `otp_win64_*.zip` from `erlang/otp` and re-packages it with our cleanup. | Windows + Git Bash | ~1 min |
| `regenerate-linux-amd64.sh` | Builds the 2 Linux x86_64 tarballs via Docker (glibc + musl). | Windows/macOS/Linux + Docker | ~5-10 min each |
| `regenerate-darwin.sh` | Builds the macOS tarball natively (arm64 by default, amd64 with `DARWIN_ARCH=amd64`). | macOS | ~5-10 min |
| `regenerate-manifest.py` | Reconstructs `MANIFEST.json` from the actual assets in every release, then commits + pushes. | Any host with `gh` | <1 min |

All four scripts share `_lib.sh` with the CI, so the resulting tarballs
are **byte-identical** to what the CI would produce.

## Typical workflow

```sh
# 1. Update your local checkout of the erts repo
cd ~/recursos/proyectos/zaguan/batamanta-erts-repo
git pull

# 2. Build whatever targets your machine can handle
./scripts/local/regenerate-windows-amd64.sh   # Windows + Git Bash
./scripts/local/regenerate-linux-amd64.sh    # Windows/macOS/Linux + Docker
# (run on your Mac) ./scripts/local/regenerate-darwin.sh

# 3. Sync the manifest so the batamanta library sees the new assets
./scripts/local/regenerate-manifest.py
```

The last step is the safety net — it walks every release in the repo,
reads the actual attached assets, and rebuilds `MANIFEST.json` from
scratch. It also filters out drafts, prereleases, and any OTP version
below the floor (`27.0` by default — bump with `--min-version` if
needed).

## Auth

All three build scripts need to call the GitHub API to create / upload
releases. They pick up the token in this order:

1. `$BATAMANTA_GITHUB_TOKEN` (used by the bash scripts via curl)
2. `$GH_TOKEN` (used by the `gh` CLI directly)
3. Whatever `gh auth login` has cached in the keyring

If you authenticated `gh` already, you're good. If not:

```sh
export GH_TOKEN="github_pat_xxxxxxxxxxxxxxxxxxxx"
```

## Environment variables

All scripts honour the same variables as the CI builds:

| Variable | Effect |
|---|---|
| `BATAMANTA_DRY_RUN=1` | Print what would run, don't actually do anything |
| `BATAMANTA_FORCE=1` | Rebuild even if the release asset is already present |
| `DETECT_MIN_VERSION=28.0` | (manifest script only) only keep OTP versions ≥ 28.0 |
| `DARWIN_ARCH=amd64` | (darwin script only) build the Intel variant instead of the default arm64 |

## When to run these

The CI handles the 4 Linux targets automatically — every push to `main`
that touches `MANIFEST.json` triggers a re-detection, and the weekly
Monday-06:00-UTC schedule catches new OTP releases.

You need to run a local script when:

* A new OTP version is released and you want the Windows or macOS
  tarball before the next weekly CI run.
* A CI build failed for a Linux target and you want to fix it from
  your local Docker (faster iteration than rerunning the workflow).
* You're prepping a release of the upstream `batamanta` library and
  need all 7 targets coherent in `MANIFEST.json` before you cut it.

## Troubleshooting

**`docker: command not found` on Windows** — Install Docker Desktop
(https://www.docker.com/products/docker-desktop/) and make sure the WSL2
backend is enabled.

**`gh: HTTP 403: Resource not accessible by personal access token`** —
Your token doesn't have the `Contents: Read and write` scope (or the
fine-grained equivalent). Re-issue the token with the right scopes, or
ask whoever owns the repo to grant you a collaborator seat with write
access.

**`darwin-amd64: must run on Intel Mac`** — You're on an Apple Silicon
Mac and passed `DARWIN_ARCH=amd64`. Either switch to a real Intel Mac
or use a Docker-based cross-compile (not currently supported — let us
know if you need it).

**`OTP-XX.Y.Z: not found in erlang/otp releases`** — Either the version
isn't released yet (you're jumping the gun) or `list_upstream_versions`
hit a rate limit. Wait a few minutes and retry.
