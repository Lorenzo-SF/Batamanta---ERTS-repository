#!/usr/bin/env pwsh
# =============================================================================
#  regenerate-manifest.ps1
# =============================================================================
#
#  PowerShell equivalent of regenerate-manifest.py for hosts that don't
#  have Python installed. Walks every release in the upstream
#  `Lorenzo-SF/Batamanta---ERTS-repository` and rebuilds MANIFEST.json
#  from the actual assets attached to each release.
#
#  Behavior:
#    * Lists releases via `gh api /repos/{owner}/{repo}/releases?per_page=100`
#    * For each non-draft, non-prerelease, OTP-X.Y.Z-shaped release,
#      lists its assets and matches them against the 7 supported
#      target keys.
#    * Skips versions below the floor (default 27.0, override with
#      --min-version).
#    * Writes MANIFEST.json and, if --no-push is not set, commits +
#      pushes the change.
#
#  Usage:
#    ./scripts/local/regenerate-manifest.ps1
#    ./scripts/local/regenerate-manifest.ps1 -MinVersion 28.0
#    ./scripts/local/regenerate-manifest.ps1 -NoPush
#    ./scripts/local/regenerate-manifest.ps1 -Owner Lorenzo-SF -Repo Batamanta---ERTS-repository
# =============================================================================

[CmdletBinding()]
param(
  [string]$Owner = "Lorenzo-SF",
  [string]$Repo = "Batamanta---ERTS-repository",
  [string]$MinVersion = $(if ($env:DETECT_MIN_VERSION) { $env:DETECT_MIN_VERSION } else { "27.0" }),
  [string]$ManifestPath = "",
  [switch]$NoPush
)

# Default MANIFEST path: walk up from $PSScriptRoot until we find a .git
# directory, and write MANIFEST.json there. Falls back to the current
# working directory if no .git is found in the ancestor chain.
if (-not $ManifestPath) {
  if ($PSScriptRoot) {
    $cur = (Resolve-Path $PSScriptRoot).Path
    $found = $false
    for ($i = 0; $i -lt 10; $i++) {
      if (Test-Path (Join-Path $cur ".git")) { $found = $true; break }
      $parent = Split-Path $cur -Parent
      if ($parent -eq $cur) { break }  # reached filesystem root
      $cur = $parent
    }
    if ($found) { $ManifestPath = Join-Path $cur "MANIFEST.json" }
    else { $ManifestPath = "MANIFEST.json" }
  } else {
    $ManifestPath = "MANIFEST.json"
  }
}

$ErrorActionPreference = 'Stop'

# Only the 4 targets that are actually published today:
#   * linux-glibc-amd64, linux-musl-amd64  (built in Docker, Linux/amd64)
#   * darwin-arm64                          (built on Mac arm64)
#   * windows-amd64                         (built on Windows natively)
# `linux-glibc-arm64`, `linux-musl-arm64` and `darwin-amd64` are intentionally
# NOT listed — there are no runners for them and the user has decided not to
# support them. Any release that still has a `arm64-glibc.tar.gz` or
# `arm64-musl.tar.gz` asset (legacy from before the rename) will simply be
# ignored here, and cleaned out of the release in a separate step.
$TARGET_KEYS = @(
  "linux-glibc-amd64",
  "linux-musl-amd64",
  "darwin-arm64",
  "windows-amd64"
)
$ASSET_EXT_BY_TARGET = @{
  "linux-glibc-amd64" = ".tar.gz"
  "linux-musl-amd64"  = ".tar.gz"
  "darwin-arm64"       = ".tar.gz"
  "windows-amd64"      = ".zip"
}

function Log([string]$msg) { Write-Host "[regen-manifest] $msg" -ForegroundColor Cyan }
function Warn([string]$msg) { Write-Host "[regen-manifest] WARN  $msg" -ForegroundColor Yellow }

function SemverKey([string]$v) {
  # Return a sortable semver-ish key. "27.0" -> "027.000.000", "28.4.2" -> "028.004.002".
  $parts = $v.Split('.')
  $padded = @()
  for ($i = 0; $i -lt 3; $i++) {
    $segment = if ($i -lt $parts.Length) { $parts[$i] } else { "0" }
    $padded += $segment.PadLeft(3, '0')
  }
  return $padded -join '.'
}

function VersionAtLeast([string]$v, [string]$floor) {
  return (SemverKey $v).CompareTo((SemverKey $floor)) -ge 0
}

function DeriveTargetKey([string]$assetName) {
  # New naming only: <target><ext>, e.g. linux-glibc-amd64.tar.gz.
  # Legacy names like `amd64-glibc.tar.gz` are NOT mapped to anything
  # here — they are filtered out in the main loop, and cleaned out of
  # the release assets in a separate step.
  foreach ($tk in $TARGET_KEYS) {
    $ext = $ASSET_EXT_BY_TARGET[$tk]
    if ($assetName -eq "$tk$ext") { return $tk }
  }
  return $null
}

Log "Listing releases in $Owner/$Repo ..."

# Paginate via gh api
$releases = @()
$page = 1
while ($true) {
  $batch = gh api "/repos/$Owner/$Repo/releases?per_page=100&page=$page" 2>&1 | ConvertFrom-Json
  if ($null -eq $batch -or @($batch).Count -eq 0) { break }
  $releases += $batch
  if (@($batch).Count -lt 100) { break }
  $page++
}
Log "  Found $($releases.Count) releases total"

$manifest = [ordered]@{}
$skipped = @{ draft=0; prerelease=0; badTag=0; belowFloor=0; noAssets=0; unknownAsset=0 }
$kept = 0

foreach ($r in $releases) {
  if ($r.draft) { $skipped.draft++; continue }
  if ($r.prerelease) { $skipped.prerelease++; continue }
  if ($r.tag_name -notmatch '^OTP-(\d+\.\d+(?:\.\d+)?)$') { $skipped.badTag++; continue }
  $version = $Matches[1]
  if (-not (VersionAtLeast $version $MinVersion)) { $skipped.belowFloor++; continue }

  $entry = [ordered]@{}
  foreach ($a in $r.assets) {
    $tk = DeriveTargetKey $a.name
    if ($null -eq $tk) { $skipped.unknownAsset++; continue }
    if ($entry.Contains($tk)) { continue }  # safety: only the first match wins
    $entry[$tk] = "https://github.com/$Owner/$Repo/releases/download/$($r.tag_name)/$($a.name)"
  }
  if ($entry.Count -eq 0) { $skipped.noAssets++; continue }

  $manifest[$r.tag_name] = $entry
  $kept++
}

Log ("  Kept {0} OTP versions. Skipped: draft={1} prerelease={2} badTag={3} belowFloor={4} noAssets={5} unknownAsset={6}" -f `
  $kept, $skipped.draft, $skipped.prerelease, $skipped.badTag, $skipped.belowFloor, $skipped.noAssets, $skipped.unknownAsset)

# Write manifest (sorted by version, descending)
$sortedKeys = @($manifest.Keys | Sort-Object -Descending { (SemverKey ($_ -replace '^OTP-','')) })
$sortedManifest = [ordered]@{}
foreach ($k in $sortedKeys) { $sortedManifest[$k] = $manifest[$k] }

$json = $sortedManifest | ConvertTo-Json -Depth 5
$resolvedPath = (Resolve-Path $ManifestPath -ErrorAction SilentlyContinue).Path
if (-not $resolvedPath) { $resolvedPath = $ManifestPath }
$json | Out-File -FilePath $resolvedPath -Encoding utf8 -NoNewline
Log "  Wrote $resolvedPath ($((Get-Item $resolvedPath).Length) bytes)"

if (Test-Path -Path '.git' -PathType Container) {
  $status = git status --porcelain -- $ManifestPath 2>&1
  if ([string]::IsNullOrWhiteSpace($status)) {
    Log "No manifest changes — nothing to commit"
  } elseif ($NoPush) {
    git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" commit -m "chore(erts): regenerate MANIFEST.json [skip ci]" -- $ManifestPath
    Log "Committed. --no-push set, skipping push (do it manually with `git push`)."
  } else {
    git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" commit -m "chore(erts): regenerate MANIFEST.json [skip ci]" -- $ManifestPath
    $pushResult = git push 2>&1
    if ($LASTEXITCODE -ne 0) {
      Warn "git push failed: $pushResult"
    } else {
      Log "Committed and pushed"
    }
  }
} else {
  Log "Not in a git checkout — skipping commit/push"
}
