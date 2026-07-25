#!/usr/bin/env pwsh
# Recovery Tracker - deploy script
# Bumps the app version, updates CHANGELOG.md, commits, and pushes (Netlify auto-publishes).
# Run from the VS Code terminal:  ./deploy.ps1     or double-click deploy.bat

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
$encNoBom = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM (keeps emojis intact)
function ReadText($p){ return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function WriteText($p,$t){ [System.IO.File]::WriteAllText($p, $t, $encNoBom) }

Write-Host "== Recovery Tracker deploy ==" -ForegroundColor Cyan

# --- must be a git repo ---
if (-not (Test-Path ".git")) {
  Write-Host "No Git repo here yet. In VS Code use Source Control -> 'Publish to GitHub' first." -ForegroundColor Red
  exit 1
}

# --- clear a stale lock from a hung commit ---
if (Test-Path ".git\index.lock") {
  Write-Host "Found a leftover git lock from an interrupted commit - clearing it." -ForegroundColor Yellow
  Remove-Item ".git\index.lock" -Force
}

# --- make sure git knows who you are (first-time commits fail without this) ---
$email = (git config user.email 2>$null)
if ([string]::IsNullOrWhiteSpace($email)) {
  Write-Host "`nGit needs your name and email (one-time setup)." -ForegroundColor Yellow
  $gn = Read-Host "  Your name"
  $ge = Read-Host "  Your email"
  git config --global user.name  $gn
  git config --global user.email $ge
  Write-Host "Saved. Thanks." -ForegroundColor Green
}

# --- read current version from index.html ---
$indexPath = Join-Path $PSScriptRoot "index.html"
if (-not (Test-Path $indexPath)) { Write-Host "index.html not found next to this script." -ForegroundColor Red; exit 1 }
$html = ReadText $indexPath
$m = [regex]::Match($html, 'APP_VERSION="(\d+)\.(\d+)\.(\d+)"')
if (-not $m.Success) { Write-Host "Couldn't find APP_VERSION in index.html." -ForegroundColor Red; exit 1 }
$maj=[int]$m.Groups[1].Value; $min=[int]$m.Groups[2].Value; $pat=[int]$m.Groups[3].Value
$current="$maj.$min.$pat"; $autoNext="$maj.$min.$($pat+1)"

Write-Host "`nCurrent app version: v$current" -ForegroundColor Cyan
$bump = Read-Host "New version (Enter to auto-bump to v$autoNext, or type e.g. 1.1.0)"
if ([string]::IsNullOrWhiteSpace($bump)) { $new = $autoNext } else { $new = $bump.Trim().TrimStart('v') }
if ($new -notmatch '^\d+\.\d+\.\d+$') { Write-Host "Version must look like 1.2.3 - stopping." -ForegroundColor Red; exit 1 }

# --- write the new version into the HTML file(s) ---
foreach ($f in @("index.html","mom-recovery-app.html")) {
  $fp = Join-Path $PSScriptRoot $f
  if (Test-Path $fp) {
    $c = ReadText $fp
    $c = [regex]::Replace($c, 'APP_VERSION="\d+\.\d+\.\d+"', ('APP_VERSION="' + $new + '"'))
    WriteText $fp $c
  }
}
Write-Host "App version set to v$new" -ForegroundColor Green

# --- collect changelog bullets ---
$today = Get-Date -Format "yyyy-MM-dd"
Write-Host "`nWhat changed in v$new? Enter one bullet per line. Blank line to finish:" -ForegroundColor Cyan
$lines = @()
while ($true) { $l = Read-Host " -"; if ([string]::IsNullOrWhiteSpace($l)) { break }; $lines += "- $l" }
if ($lines.Count -eq 0) {
  Write-Host "No changelog entry given - stopping so the changelog never falls behind." -ForegroundColor Red
  exit 1
}

# --- prepend the entry to CHANGELOG.md ---
$nl = "`r`n"
$entry  = "## v$new - $today" + $nl + ($lines -join $nl) + $nl + $nl
$header = "# Changelog" + $nl + $nl + "All notable changes to Recovery Tracker. Newest entries on top." + $nl + $nl
$clPath = Join-Path $PSScriptRoot "CHANGELOG.md"
if (Test-Path $clPath) {
  $existing = ReadText $clPath
  $idx = $existing.IndexOf("## ")
  if ($idx -ge 0) { $body = $existing.Substring($idx) } else { $body = "" }
  WriteText $clPath ($header + $entry + $body)
} else {
  WriteText $clPath ($header + $entry)
}
Write-Host "CHANGELOG.md updated." -ForegroundColor Green

# --- commit ---
$firstBullet = ($lines[0]).Substring(2)
git add -A
git commit -m "v$new`: $firstBullet"
if ($LASTEXITCODE -ne 0) { Write-Host "Commit failed - see the message above." -ForegroundColor Red; exit 1 }
Write-Host "Committed v$new." -ForegroundColor Green

# --- push (only if a GitHub remote is set up) ---
$remotes = (git remote)
if ($remotes -contains "origin") {
  git push
  if ($LASTEXITCODE -ne 0) {
    Write-Host "`nCommit is saved, but the push didn't complete." -ForegroundColor Yellow
    Write-Host "If this is your first push, run once:  git push -u origin HEAD" -ForegroundColor Yellow
    exit 1
  }
  Write-Host "`nPushed v$new. Netlify will publish in ~30 seconds:" -ForegroundColor Green
  Write-Host "  https://mom-s-recovery-cd-9169b52809.netlify.app" -ForegroundColor Green
} else {
  Write-Host "`nv$new is committed locally, but there is no GitHub remote yet, so nothing was pushed." -ForegroundColor Yellow
  Write-Host "Finish 'Publish to GitHub' in VS Code (or add a remote), then run this again to publish." -ForegroundColor Yellow
}
