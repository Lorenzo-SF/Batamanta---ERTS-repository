#!/usr/bin/env python3
# =============================================================================
#  regenerate-manifest.py
# =============================================================================
#
#  Reconstructs MANIFEST.json by walking every release in the upstream
#  `Lorenzo-SF/Batamanta---ERTS-repository` and reading the actual assets
#  that are attached. This is the "safety net" — if the CI ever ends up
#  with a manifest that doesn't match reality (e.g. a failed build left
#  dangling entries, or a manual run skipped the manifest-commit step),
#  running this script brings everything back in sync.
#
#  Naming convention (must match what the CI and the local scripts produce):
#    tag    = "OTP-<version>"                e.g. "OTP-28.4.2"
#    asset  = "<target_key>.<ext>"           e.g. "linux-glibc-amd64.tar.gz"
#    url    = "https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>"
#    entry  = MANIFEST["OTP-<version>"][<target_key>] = <url>
#
#  This script also filters out:
#    * Drafts / prereleases.
#    * Tags that don't match the `OTP-X.Y.Z` pattern.
#    * OTP versions below the `min_version` floor (default 27.0).
#    * Asset filenames that don't match any of the 4 supported target keys.
#      Legacy filenames from before the rename (e.g. `amd64-glibc.tar.gz`)
#      are intentionally ignored — they are cleaned out of the release
#      assets in a separate step, and the upstream MANIFEST only ever
#      references the new naming.
#  After writing MANIFEST.json the script commits + pushes it to the same
#  branch the user is currently on (typically `main`). Use `--no-push` to
#  just write the file locally and let you commit yourself.
#
#  Prereqs:
#    * `gh` CLI authenticated (or `GH_TOKEN` / `BATAMANTA_GITHUB_TOKEN`).
#    * Run from a git checkout of the erts repo (it reads/writes
#      MANIFEST.json from the working tree and uses `git` to commit).
#
#  Usage:
#    # Default — rebuild manifest, commit, push.
#    ./scripts/local/regenerate-manifest.py
#
#    # Custom floor (only keep entries for OTP >= 28.0):
#    ./scripts/local/regenerate-manifest.py --min-version 28.0
#
#    # Just write the file, don't commit/push:
#    ./scripts/local/regenerate-manifest.py --no-push
#
#    # Different repo (default: the canonical one):
#    ./scripts/local/regenerate-manifest.py --repo Lorenzo-SF/Batamanta---ERTS-repository
# =============================================================================

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Only the 4 targets that are actually published today:
#   * linux-glibc-amd64, linux-musl-amd64  (built in Docker, Linux/amd64)
#   * darwin-arm64                          (built on Mac arm64)
#   * windows-amd64                         (built on Windows natively)
# `linux-glibc-arm64`, `linux-musl-arm64` and `darwin-amd64` are intentionally
# NOT listed — there are no runners for them and the user has decided not to
# support them. Any release that still has a `arm64-glibc.tar.gz` or
# `arm64-musl.tar.gz` asset (legacy from before the rename) will simply be
# ignored here, and cleaned out of the release in a separate step.
TARGET_KEYS = {
    "linux-glibc-amd64",
    "linux-musl-amd64",
    "darwin-arm64",
    "windows-amd64",
}

ASSET_EXT_BY_TARGET = {
    "linux-glibc-amd64": ".tar.gz",
    "linux-musl-amd64":  ".tar.gz",
    "darwin-arm64":      ".tar.gz",
    "windows-amd64":     ".zip",
}

TAG_RE = re.compile(r"^OTP-(\d+\.\d+(?:\.\d+)?)$")
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)(?:\.(\d+))?$")


def log(msg: str) -> None:
    print(f"[regen-manifest] {msg}", file=sys.stderr, flush=True)


def err(msg: str) -> None:
    print(f"[regen-manifest] ERR  {msg}", file=sys.stderr, flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def gh_json(args: list[str]) -> object:
    """Run `gh <args> --json ...` and parse the JSON output. Retry once on
    transient auth errors so we don't bail out on the first hiccup."""
    p = run(["gh", *args])
    if p.returncode != 0:
        # One retry — sometimes `gh` returns a non-zero because of a
        # progress-bar write to stderr, not a real failure.
        log(f"  retrying after: {p.stderr.strip().splitlines()[-1] if p.stderr else 'unknown'}")
        p = run(["gh", *args])
    if p.returncode != 0:
        err(f"gh {args[0]} failed: {p.stderr.strip()}")
        raise SystemExit(2)
    return json.loads(p.stdout) if p.stdout.strip() else None


def list_releases(repo: str) -> list[dict]:
    log(f"listing releases in {repo}...")
    releases = []
    page = 1
    while True:
        batch = gh_json([
            "release", "list",
            "--repo", repo,
            "--limit", "100",
            "--json", "tagName,isDraft,isPrerelease",
            *([] if page == 1 else ["--page", str(page)]),
        ])
        if not batch:
            break
        releases.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    log(f"  found {len(releases)} releases total")
    return releases


def release_assets(repo: str, tag: str) -> list[dict]:
    """Return the list of assets attached to <tag> in <repo>."""
    payload = gh_json([
        "release", "view", tag,
        "--repo", repo,
        "--json", "assets",
    ])
    if not payload:
        return []
    return payload.get("assets", [])


def version_key(v: str) -> tuple[int, ...]:
    """Return a tuple suitable for sorting ('27.0' < '27.0.1' < '28.0')."""
    m = SEMVER_RE.match(v)
    if not m:
        return (0, 0, 0)
    return tuple(int(p) for p in m.groups() if p is not None)


def version_at_least(v: str, floor: str) -> bool:
    return version_key(v) >= version_key(floor)


def derive_target_key(asset_name: str) -> str | None:
    """Extract the target_key from an asset filename. Returns None if the
    filename doesn't match any known target+ext pattern. New naming only —
    legacy asset names like `amd64-glibc.tar.gz` are NOT mapped to anything
    here, they are filtered out in the main loop and cleaned out of the
    release assets in a separate step."""
    for tk, ext in ASSET_EXT_BY_TARGET.items():
        if asset_name == f"{tk}{ext}":
            return tk
    return None


def build_manifest(repo: str, owner: str, min_version: str) -> dict[str, dict[str, str]]:
    """Walk every release and assemble the MANIFEST dict."""
    out: dict[str, dict[str, str]] = {}
    releases = list_releases(repo)
    skipped = {"draft": 0, "prerelease": 0, "bad_tag": 0, "below_floor": 0, "no_assets": 0}

    for r in releases:
        tag = r["tagName"]
        if r.get("isDraft"):
            skipped["draft"] += 1
            continue
        if r.get("isPrerelease"):
            skipped["prerelease"] += 1
            continue

        m = TAG_RE.match(tag)
        if not m:
            skipped["bad_tag"] += 1
            continue
        version = m.group(1)
        if not version_at_least(version, min_version):
            skipped["below_floor"] += 1
            continue

        assets = release_assets(repo, tag)
        if not assets:
            skipped["no_assets"] += 1
            continue

        entry: dict[str, str] = {}
        for a in assets:
            tk = derive_target_key(a["name"])
            if tk is None:
                # Could be a non-target asset (e.g. legacy naming from
                # before the rename, a checksums file, a stray debug
                # upload). Skip silently.
                continue
            if tk in entry:
                # Defensive: with the new-only naming this can't happen,
                # but guards against future code drift.
                continue
            entry[tk] = (
                f"https://github.com/{owner}/{repo}/releases/download/{tag}/{a['name']}"
            )
        if entry:
            out[tag] = entry

    log(
        f"  manifest has {len(out)} OTP versions, "
        f"skipped: draft={skipped['draft']} prerelease={skipped['prerelease']} "
        f"bad_tag={skipped['bad_tag']} below_floor={skipped['below_floor']} "
        f"no_assets={skipped['no_assets']}"
    )
    return out


def write_manifest(manifest: dict, path: Path) -> None:
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    log(f"  wrote {path} ({path.stat().st_size} bytes)")


def _find_repo_root() -> Path:
    """Walk up from this script's parent looking for a .git directory.
    Falls back to the current working directory if no .git is found in the
    ancestor chain (e.g. running outside a git checkout)."""
    cur = Path(__file__).resolve().parent
    for _ in range(10):
        if (cur / ".git").exists():
            return cur
        parent = cur.parent
        if parent == cur:
            break  # reached filesystem root
        cur = parent
    return Path.cwd()


def maybe_commit_and_push(path: Path, do_push: bool) -> None:
    """If MANIFEST.json changed, commit and (optionally) push."""
    p = run(["git", "status", "--porcelain", "--", str(path)])
    if not p.stdout.strip():
        log("no manifest changes — nothing to commit")
        return

    p = run([
        "git", "-c", "user.name=github-actions[bot]",
        "-c", "user.email=github-actions[bot]@users.noreply.github.com",
        "commit", "-m", "chore(erts): regenerate MANIFEST.json [skip ci]",
        "--", str(path),
    ])
    if p.returncode != 0:
        err(f"git commit failed: {p.stderr.strip()}")
        raise SystemExit(3)
    log("committed MANIFEST.json")

    if not do_push:
        log("--no-push set — skipping push (you can push manually with `git push`)")
        return

    p = run(["git", "push"])
    if p.returncode != 0:
        err(f"git push failed: {p.stderr.strip()}")
        raise SystemExit(4)
    log("pushed")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="Lorenzo-SF/Batamanta---ERTS-repository",
                    help="GitHub owner/repo (default: %(default)s)")
    ap.add_argument("--owner", default=None,
                    help="GitHub owner (defaults to the owner part of --repo)")
    ap.add_argument("--min-version", default=os.environ.get("DETECT_MIN_VERSION", "27.0"),
                    help="Only include OTP versions >= this (default: 27.0, or $DETECT_MIN_VERSION)")
    ap.add_argument("--manifest", default=str(_find_repo_root() / "MANIFEST.json"),
                    help="Path to the manifest file (default: <repo-root>/MANIFEST.json)")
    ap.add_argument("--no-push", action="store_true",
                    help="Don't push after committing")
    args = ap.parse_args()

    owner = args.owner or args.repo.split("/", 1)[0]
    manifest_path = Path(args.manifest).resolve()
    if not manifest_path.exists():
        # Allow writing to a brand-new tree (the script doesn't require
        # the file to pre-exist).
        log(f"creating new {manifest_path}")
    else:
        log(f"will update existing {manifest_path}")

    manifest = build_manifest(args.repo, owner, args.min_version)
    write_manifest(manifest, manifest_path)

    if (manifest_path.parent / ".git").exists():
        maybe_commit_and_push(manifest_path, do_push=not args.no_push)
    else:
        log("not in a git checkout — skipping commit/push")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
