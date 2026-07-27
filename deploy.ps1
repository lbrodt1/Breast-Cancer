#!/usr/bin/env pwsh
<#
  deploy.ps1 - standard release script          SCRIPT VERSION 2.0
  --------------------------------------------------------------------
  Bumps the version, writes a CHANGELOG entry, commits with the full entry
  in the commit body, and pushes.

  Works with NO configuration at all - it auto-detects your version file on
  every run. deploy.config.json is optional and only needed to pin settings
  (deploy URL, release branch, or a version file the detector misses).

      ./deploy.ps1                # interactive release
      ./deploy.ps1 -DryRun        # show the plan, change nothing
      ./deploy.ps1 -Doctor        # diagnose setup, change nothing
      ./deploy.ps1 -Init          # write a deploy.config.json (optional)
      ./deploy.ps1 -Version 1.1.0 -Message "Added export","Fixed picker" -Yes
      ./deploy.ps1 -NoPush        # commit locally only
      ./deploy.ps1 -NoVersion     # changelog + commit, no version bump

  Design rule: nothing is written to disk until the version and the changelog
  bullets are both collected and confirmed. Aborting can never leave the
  working tree half-modified.
#>

[CmdletBinding()]
param(
  [string]   $Version,
  [string[]] $Message,
  [switch]   $DryRun,
  [switch]   $NoPush,
  [switch]   $NoVersion,
  [switch]   $Init,
  [switch]   $Doctor,
  [switch]   $Bootstrap,
  [switch]   $FromDiff,
  [switch]   $Prompt,
  [switch]   $Netlify,
  [switch]   $Yes
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$SCRIPT_VERSION = "2.2"

# ---------- file helpers (UTF-8, no BOM, so emoji survive) ----------
$script:EncNoBom = New-Object System.Text.UTF8Encoding($false)
function ReadText([string]$p)  { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function WriteText([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $script:EncNoBom) }

function Say  ([string]$m, [string]$c = "Gray") { Write-Host $m -ForegroundColor $c }
function Ok   ([string]$m) { Write-Host $m -ForegroundColor Green }
function Warn ([string]$m) { Write-Host $m -ForegroundColor Yellow }
function Fail ([string]$m) { Write-Host "" ; Write-Host "STOPPED: $m" -ForegroundColor Red ; exit 1 }

$CONFIG_PATH = Join-Path $PSScriptRoot "deploy.config.json"

# =====================================================================
#  Version-file detection - shared by -Init, -Doctor, and normal runs
# =====================================================================
function Get-DetectedVersionFiles {
  $out = @()

  # Known manifest locations, in priority order. First hit wins.
  $candidates = @(
    @{ Path = "package.json";   Pattern = '"version"\s*:\s*"(\d+\.\d+\.\d+)"' },
    @{ Path = "pyproject.toml"; Pattern = 'version\s*=\s*"(\d+\.\d+\.\d+)"' },
    @{ Path = "Cargo.toml";     Pattern = 'version\s*=\s*"(\d+\.\d+\.\d+)"' },
    @{ Path = "VERSION";        Pattern = '(\d+\.\d+\.\d+)' },
    @{ Path = "version.txt";    Pattern = '(\d+\.\d+\.\d+)' }
  )
  foreach ($c in $candidates) {
    if (Test-Path $c.Path) {
      if ([regex]::IsMatch((ReadText $c.Path), $c.Pattern)) {
        $out += [pscustomobject]@{ path = $c.Path; pattern = $c.Pattern }
        return $out
      }
    }
  }

  # Single-file-app pattern: an APP_VERSION constant in top-level HTML/JS.
  # index.html is listed first so it becomes the source of truth.
  $appPat = 'APP_VERSION\s*=\s*"(\d+\.\d+\.\d+)"'
  $files = Get-ChildItem -Path $PSScriptRoot -File |
           Where-Object { $_.Extension -in @(".html", ".htm", ".js") } |
           Sort-Object { if ($_.Name -eq "index.html") { 0 } else { 1 } }, Name
  foreach ($f in $files) {
    if ([regex]::IsMatch((ReadText $f.FullName), $appPat)) {
      $out += [pscustomobject]@{ path = $f.Name; pattern = $appPat }
    }
  }
  return $out
}

# =====================================================================
#  -Doctor : report what the script sees, write nothing
# =====================================================================
if ($Doctor) {
  Say "== deploy.ps1 doctor ==" "Cyan"
  Say "script version : $SCRIPT_VERSION"
  Say "folder         : $PSScriptRoot"
  Say "git repo       : $(if (Test-Path '.git') { 'yes' } else { 'NO - not a git repo' })"
  Say "config file    : $(if (Test-Path $CONFIG_PATH) { 'deploy.config.json found' } else { 'none (optional - auto-detect will be used)' })"

  $d = @(Get-DetectedVersionFiles)
  if ($d.Count -eq 0) {
    Warn "version file   : none detected"
    Warn "                 -> add one to deploy.config.json, or use -NoVersion"
  } else {
    Say "version files  :"
    for ($i = 0; $i -lt $d.Count; $i++) {
      $vf = $d[$i]
      $m  = [regex]::Match((ReadText $vf.path), $vf.pattern)
      $v  = if ($m.Success) { "v" + $m.Groups[1].Value } else { "no match" }
      $role = if ($i -eq 0) { "  <- source of truth" } else { "" }
      Say "                 $($vf.path)  ($v)$role"
    }
  }

  $cl = "CHANGELOG.md"
  if (Test-Path $CONFIG_PATH) {
    try { $c = ReadText $CONFIG_PATH | ConvertFrom-Json; if ($c.changelogPath) { $cl = $c.changelogPath } } catch {}
  }
  if (Test-Path $cl) {
    $clTxt = ReadText $cl
    $first = [regex]::Match($clTxt, "(?m)^##\s+.*$")
    Say "changelog      : $cl found, newest entry = $(if ($first.Success) { $first.Value } else { 'no ## entries yet' })"
  } else {
    Say "changelog      : $cl does not exist yet - it will be created"
  }
  Say ""
  Ok "Doctor finished. Nothing was changed."
  exit 0
}

# =====================================================================
#  -Init : write an optional deploy.config.json
# =====================================================================
if ($Init) {
  Say "== Writing deploy.config.json ==" "Cyan"
  if ((Test-Path $CONFIG_PATH) -and -not $Yes) {
    if ((Read-Host "deploy.config.json already exists. Overwrite? (y/N)") -ne "y") { Fail "Left the existing config alone." }
  }
  $found = @(Get-DetectedVersionFiles)
  if ($found.Count -eq 0) { Warn "No version file detected - writing an empty versionFiles list." }
  else { Ok "Detected: $(($found | ForEach-Object { $_.path }) -join ', ')" }

  $name = if ($Yes) { Split-Path $PSScriptRoot -Leaf } else { Read-Host "Project name (for the changelog header)" }
  if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path $PSScriptRoot -Leaf }
  $url = if ($Yes) { "" } else { Read-Host "Live/deploy URL to print after a push (optional)" }
  $br  = if ($Yes) { "" } else { Read-Host "Release branch to expect, e.g. main (optional)" }

  $cfg = [ordered]@{
    projectName   = $name
    changelogPath = "CHANGELOG.md"
    versionFiles  = @($found)
    deployUrl     = $url
    branch        = $br
  }
  WriteText $CONFIG_PATH ($cfg | ConvertTo-Json -Depth 5)
  Ok "Wrote $CONFIG_PATH"
  exit 0
}

# =====================================================================
#  -Bootstrap : scaffold a brand-new project
#  Creates CHANGELOG.md, deploy.bat, deploy.config.json, .gitignore,
#  optionally netlify.toml, and makes sure index.html carries an
#  APP_VERSION constant the release script can stamp.
# =====================================================================
function Add-VersionConstant([string]$path, [string]$ver) {
  $html = ReadText $path
  if ([regex]::IsMatch($html, 'APP_VERSION\s*=\s*"\d+\.\d+\.\d+"')) {
    return "already had APP_VERSION"
  }
  $decl = 'const APP_VERSION="' + $ver + '";'

  $m = [regex]::Match($html, '<script\b[^>]*>')
  if ($m.Success) {
    $out = $html.Substring(0, $m.Index + $m.Length) + "`n" + $decl + $html.Substring($m.Index + $m.Length)
    WriteText $path $out
    return "inserted into the existing <script> block"
  }
  $b = [regex]::Match($html, '</body>', 'IgnoreCase')
  $block = "<script>" + $decl + "</script>`n"
  if ($b.Success) {
    $out = $html.Substring(0, $b.Index) + $block + $html.Substring($b.Index)
    WriteText $path $out
    return "added a <script> block before </body>"
  }
  WriteText $path ($html.TrimEnd("`n") + "`n" + $block)
  return "appended a <script> block"
}

if ($Bootstrap) {
  Say "== Bootstrapping a new project ==" "Cyan"
  $startVer = "1.0.0"

  $name = if ($Yes) { Split-Path $PSScriptRoot -Leaf } else { Read-Host "Project name" }
  if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path $PSScriptRoot -Leaf }
  $url  = if ($Yes) { "" } else { Read-Host "Live/deploy URL if you know it (optional)" }

  # --- git ---
  if (-not (Test-Path ".git")) {
    git init -q
    if ($LASTEXITCODE -eq 0) { Ok "git init" } else { Warn "git init failed - do it in VS Code" }
  } else { Say "git repo already present" "DarkGray" }

  # --- index.html ---
  if (-not (Test-Path "index.html")) {
    $starter = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>$name</title>
</head>
<body>
<h1>$name</h1>
<footer><small id="ver"></small></footer>
<script>
const APP_VERSION="$startVer";   // deploy.ps1 stamps this - leave the format alone
document.getElementById("ver").textContent = "v" + APP_VERSION;
</script>
</body>
</html>
"@
    WriteText "index.html" $starter
    Ok "created index.html with APP_VERSION=$startVer (and it renders the version in the footer)"
  } else {
    $how = Add-VersionConstant "index.html" $startVer
    Ok "index.html: $how"
  }

  # --- CHANGELOG.md ---
  if (-not (Test-Path "CHANGELOG.md")) {
    $today = Get-Date -Format "yyyy-MM-dd"
    WriteText "CHANGELOG.md" ("# Changelog`n`nAll notable changes to $name. Newest entries on top.`n`n## v$startVer - $today`n- Initial project setup`n")
    Ok "created CHANGELOG.md seeded at v$startVer"
  } else { Say "CHANGELOG.md already present - left alone" "DarkGray" }

  # --- deploy.bat ---
  if (-not (Test-Path "deploy.bat")) {
    WriteText "deploy.bat" ("@echo off`r`nREM Double-click to release. Arguments pass through, e.g. deploy.bat -DryRun`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0deploy.ps1`" %*`r`necho.`r`npause`r`n")
    Ok "created deploy.bat"
  } else { Say "deploy.bat already present" "DarkGray" }

  # --- deploy.config.json ---
  if (-not (Test-Path $CONFIG_PATH)) {
    $cfg = [ordered]@{
      projectName   = $name
      changelogPath = "CHANGELOG.md"
      versionFiles  = @([pscustomobject]@{ path = "index.html"; pattern = 'APP_VERSION\s*=\s*"(\d+\.\d+\.\d+)"' })
      deployUrl     = $url
      branch        = "main"
    }
    WriteText $CONFIG_PATH ($cfg | ConvertTo-Json -Depth 5)
    Ok "created deploy.config.json"
  } else { Say "deploy.config.json already present" "DarkGray" }

  # --- .gitignore ---
  if (-not (Test-Path ".gitignore")) {
    WriteText ".gitignore" ".claude/`ndeploy/`nnode_modules/`n.DS_Store`nThumbs.db`n"
    Ok "created .gitignore"
  }

  # --- netlify.toml ---
  if ($Netlify -and -not (Test-Path "netlify.toml")) {
    WriteText "netlify.toml" ("# Static single-file app, no build step.`n[build]`n  publish = `".`"`n  command = `"`"`n`n# Send unknown paths back to the app.`n[[redirects]]`n  from = `"/*`"`n  to = `"/index.html`"`n  status = 200`n")
    Ok "created netlify.toml"
  }

  Say ""
  Ok "Bootstrap complete."
  Say "Next:" "Cyan"
  Say "  1. build your app in index.html"
  Say "  2. ./deploy.ps1 -Doctor        (confirm it sees index.html at v$startVer)"
  Say "  3. ./deploy.ps1 -FromDiff      (draft the changelog from your actual edits)"
  exit 0
}

# =====================================================================
#  -FromDiff : draft changelog bullets from the real working-tree changes,
#  then open them in an editor for you to rewrite in plain language.
#  The diff supplies facts; you supply the wording.
# =====================================================================
function Get-DiffDraft {
  $info = @()

  $numstat = @(git diff HEAD --numstat 2>$null | Where-Object { $_ })
  $untracked = @(git ls-files --others --exclude-standard 2>$null | Where-Object { $_ })

  if ($numstat.Count -eq 0 -and $untracked.Count -eq 0) { return $null }

  $info += "# Detected changes since the last commit:"
  foreach ($row in $numstat) {
    $c = $row -split "`t"
    if ($c.Count -ge 3) { $info += ("#   {0,-34} +{1} -{2}" -f $c[2], $c[0], $c[1]) }
  }
  foreach ($u in $untracked) { $info += ("#   {0,-34} (new file)" -f $u) }

  # Look for added/removed top-level functions in the diff body.
  $diff = @(git diff HEAD 2>$null)
  $fnRe = '^\s*(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\('
  $addedFns = @(); $removedFns = @()
  foreach ($l in $diff) {
    if ($l.StartsWith("+") -and -not $l.StartsWith("+++")) {
      $m = [regex]::Match($l.Substring(1), $fnRe); if ($m.Success) { $addedFns += $m.Groups[1].Value }
    } elseif ($l.StartsWith("-") -and -not $l.StartsWith("---")) {
      $m = [regex]::Match($l.Substring(1), $fnRe); if ($m.Success) { $removedFns += $m.Groups[1].Value }
    }
  }
  $newFns  = @($addedFns   | Where-Object { $removedFns -notcontains $_ } | Select-Object -Unique)
  $goneFns = @($removedFns | Where-Object { $addedFns   -notcontains $_ } | Select-Object -Unique)
  if ($newFns.Count)  { $info += "#   new functions: $($newFns -join ', ')" }
  if ($goneFns.Count) { $info += "#   removed functions: $($goneFns -join ', ')" }

  # Version-bump-only change is worth calling out.
  $verOnly = ($numstat.Count -eq 1) -and ($numstat[0] -match 'index\.html')
  if ($verOnly) { $info += "#   (only index.html changed)" }

  return $info
}

function Open-InEditor([string]$path) {
  $cmd = if ($env:VISUAL) { $env:VISUAL }
         elseif ($env:EDITOR) { $env:EDITOR }
         elseif (Get-Command code -ErrorAction SilentlyContinue) { "code --wait" }
         else { "notepad" }
  $parts = $cmd.Split(' ')
  $exe   = $parts[0]
  $extra = if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() }
  try {
    Start-Process -FilePath $exe -ArgumentList (@($extra) + @($path)) -Wait -NoNewWindow
    return $true
  } catch {
    Warn "Couldn't open an editor ($exe). Falling back to typing bullets here."
    return $false
  }
}

function Get-BulletsFromDiff {
  $draft = Get-DiffDraft
  if (-not $draft) {
    Warn "No uncommitted changes found - nothing to draft from."
    return @()
  }

  Say ""
  Say "---- what changed ----" "Cyan"
  foreach ($l in $draft) { Say ($l -replace '^#\s?', '') "DarkGray" }
  Say "----------------------" "Cyan"

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("changelog-draft-" + [guid]::NewGuid().ToString("N") + ".md")
  $template = @()
  $template += "# One changelog bullet per line, in plain language a user would understand."
  $template += "# Lines starting with # are ignored. Save and close this file when done."
  $template += "#"
  $template += $draft
  $template += "#"
  $template += ""
  WriteText $tmp (($template -join "`n") + "`n")

  Say ""
  Say "Opening an editor so you can write the bullets..." "Cyan"
  if (Open-InEditor $tmp) {
    $saved = @((ReadText $tmp) -split "`r?`n" | Where-Object { $_ -and -not $_.TrimStart().StartsWith("#") })
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return @($saved | ForEach-Object { $t = $_.Trim(); if ($t.StartsWith("- ")) { $t } else { "- $t" } })
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return @()
}

# =====================================================================
#  Read the newest entry from CHANGELOG.md.
#  This is what makes the "Claude wrote the entry" workflow possible: if the
#  top entry is newer than what has been released, the script uses its version
#  and its bullets and never asks a question.
# =====================================================================
function Get-TopChangelogEntry([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $lines = ((ReadText $path) -replace "`r`n", "`n").Split("`n")
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith("## ")) { $start = $i; break } }
  if ($start -lt 0) { return $null }

  $m = [regex]::Match($lines[$start], '^##\s+v?(\d+\.\d+\.\d+)\b')
  $ver = if ($m.Success) { $m.Groups[1].Value } else { $null }

  $bullets = @()
  for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith("## ")) { break }
    $t = $lines[$i].Trim()
    if ($t.StartsWith("-")) { $bullets += $t }
  }
  if ($bullets.Count -eq 0) { return $null }
  return [pscustomobject]@{ version = $ver; bullets = $bullets; heading = $lines[$start] }
}

# =====================================================================
#  Settings: config file if present, otherwise auto-detect
# =====================================================================
$projectName   = Split-Path $PSScriptRoot -Leaf
$changelogPath = "CHANGELOG.md"
$versionFiles  = @()
$deployUrl     = ""
$wantBranch    = ""
$usingConfig   = $false

if (Test-Path $CONFIG_PATH) {
  try { $cfg = ReadText $CONFIG_PATH | ConvertFrom-Json }
  catch { Fail "deploy.config.json isn't valid JSON: $($_.Exception.Message)" }
  $usingConfig = $true
  if ($cfg.projectName)   { $projectName   = $cfg.projectName }
  if ($cfg.changelogPath) { $changelogPath = $cfg.changelogPath }
  if ($cfg.deployUrl)     { $deployUrl     = $cfg.deployUrl }
  if ($cfg.branch)        { $wantBranch    = $cfg.branch }
  $versionFiles = @(@($cfg.versionFiles) | Where-Object { $_ -and $_.path -and $_.pattern })
}

if ($versionFiles.Count -eq 0 -and -not $NoVersion) {
  $versionFiles = @(Get-DetectedVersionFiles)
  if ($versionFiles.Count -gt 0) {
    Say "Auto-detected version file: $(($versionFiles | ForEach-Object { $_.path }) -join ', ')" "DarkGray"
  }
}

Say "== $projectName deploy (script v$SCRIPT_VERSION) ==" "Cyan"
if (-not $usingConfig) { Say "No deploy.config.json - using auto-detect. Run -Init to pin settings." "DarkGray" }
if ($DryRun) { Warn "DRY RUN - nothing will be written, committed, or pushed." }

# =====================================================================
#  Pre-flight - all checks before any file is touched
# =====================================================================
if (-not (Test-Path ".git")) { Fail "This isn't a git repo. Use Source Control -> 'Publish to GitHub' first." }

$lock = Join-Path ".git" "index.lock"
if (Test-Path $lock) { Warn "Clearing a leftover git lock from an interrupted commit."; Remove-Item $lock -Force }

if ([string]::IsNullOrWhiteSpace((git config user.email 2>$null))) {
  Say ""; Warn "Git needs your name and email (one-time setup)."
  git config --global user.name  (Read-Host "  Your name")
  git config --global user.email (Read-Host "  Your email")
  Ok "Saved."
}

$branch = (git rev-parse --abbrev-ref HEAD 2>$null)
if ($branch -eq "HEAD") { Fail "Detached HEAD - check out a branch before releasing." }
if ($wantBranch -and $branch -ne $wantBranch) {
  Warn "You're on '$branch' but the config expects '$wantBranch'."
  if (-not $Yes -and (Read-Host "Continue anyway? (y/N)") -ne "y") { Fail "Nothing changed." }
}
Say "Branch: $branch"

# =====================================================================
#  Current + new version (no writes yet)
# =====================================================================
$current = $null
$newVer  = $null
$usedChangelog = $false   # true when CHANGELOG.md already contains the entry to ship
$skipStamp     = $false   # true when index.html is already at the target version

# Is there an entry at the top of CHANGELOG.md that hasn't shipped yet?
$top = $null
if (-not $Prompt -and -not $FromDiff -and -not $Message) {
  $top = Get-TopChangelogEntry $changelogPath
  if ($top -and $top.version) {
    $clDirty = @(git diff HEAD --name-only -- $changelogPath 2>$null | Where-Object { $_ }).Count -gt 0
    $appVer  = $null
    if ($versionFiles.Count -gt 0 -and (Test-Path $versionFiles[0].path)) {
      $mm = [regex]::Match((ReadText $versionFiles[0].path), $versionFiles[0].pattern)
      if ($mm.Success) { $appVer = $mm.Groups[1].Value }
    }
    if ($clDirty -or ($appVer -and $top.version -ne $appVer)) {
      $usedChangelog = $true
      $newVer = $top.version
      $skipStamp = ($appVer -eq $top.version)
      $lines = @($top.bullets)
      Say ""
      Ok "Using the entry already written in $changelogPath - no questions needed."
      Say "  $($top.heading)" "DarkGray"
      foreach ($b in $lines) { Say "  $b" "DarkGray" }
      if ($skipStamp) { Say "  ($($versionFiles[0].path) is already at v$newVer)" "DarkGray" }
    }
  }
}

if (-not $NoVersion -and -not $usedChangelog) {
  if ($versionFiles.Count -eq 0) {
    Warn "No version file found or configured - continuing without a version bump."
    Warn "Run './deploy.ps1 -Doctor' to see what was checked."
    $NoVersion = $true
  } else {
    $src = $versionFiles[0]
    if (-not (Test-Path $src.path)) { Fail "Version file '$($src.path)' not found." }
    $m = [regex]::Match((ReadText $src.path), $src.pattern)
    if (-not $m.Success) { Fail "No version matching /$($src.pattern)/ in $($src.path)." }
    $current = $m.Groups[1].Value

    $p = $current.Split('.')
    $autoNext = "{0}.{1}.{2}" -f $p[0], $p[1], ([int]$p[2] + 1)

    Say ""
    Say "Current version: v$current  (from $($src.path))" "Cyan"
    if ($Version) { $newVer = $Version.Trim().TrimStart('v') }
    else {
      $bump = Read-Host "New version (Enter to auto-bump to v$autoNext, or type e.g. 1.1.0)"
      $newVer = if ([string]::IsNullOrWhiteSpace($bump)) { $autoNext } else { $bump.Trim().TrimStart('v') }
    }
    if ($newVer -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must look like 1.2.3 - got '$newVer'." }
    if ($newVer -eq $current) { Fail "v$newVer is already the current version." }
    if ((Test-Path $changelogPath) -and
        [regex]::IsMatch((ReadText $changelogPath), "(?m)^##\s+v?$([regex]::Escape($newVer))\b")) {
      Fail "v$newVer already has a CHANGELOG entry. Pick a different version."
    }
  }
}

$label = if ($NoVersion) { "this change" } else { "v$newVer" }

# =====================================================================
#  Changelog bullets (still no writes - this ordering is the key fix)
# =====================================================================
if (-not $usedChangelog) { $lines = @() }
if ($usedChangelog) {
  # bullets already came from CHANGELOG.md
}
elseif ($FromDiff -and -not $Message) {
  $lines = @(Get-BulletsFromDiff)
  if ($lines.Count -eq 0) { Fail "No bullets written - nothing was modified." }
}
elseif ($Message) {
  $lines = @($Message | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
    $t = $_.Trim(); if ($t.StartsWith("- ")) { $t } else { "- $t" } })
} else {
  Say ""
  Say "What changed in $label ? One bullet per line. Blank line to finish:" "Cyan"
  while ($true) {
    $l = Read-Host " -"
    if ([string]::IsNullOrWhiteSpace($l)) { break }
    $lines += "- $($l.Trim())"
  }
}
if ($lines.Count -eq 0) { Fail "No changelog entry given - stopping so the changelog never falls behind. (Nothing was modified.)" }

# =====================================================================
#  Commit message: subject + every bullet as the body
# =====================================================================
$firstBullet = $lines[0].Substring(2)
$subject = if ($NoVersion) { $firstBullet } else { "v${newVer}: $firstBullet" }
if ($subject.Length -gt 72) { $subject = $subject.Substring(0, 69) + "..." }
$commitMsg = $subject + "`n`n" + ($lines -join "`n") + "`n"

# =====================================================================
#  New changelog content, built in memory.
#  Inserts before the first '## ' heading, appends if there is none,
#  and never discards existing content.
# =====================================================================
$today = Get-Date -Format "yyyy-MM-dd"
$entryHeading = if ($NoVersion) { "## $today" } else { "## v$newVer - $today" }
$entry = $entryHeading + "`n" + ($lines -join "`n") + "`n"

$newChangelog = $null
if ($usedChangelog) {
  # nothing to build - the entry is already in the file
}
elseif (Test-Path $changelogPath) {
  $existing = (ReadText $changelogPath) -replace "`r`n", "`n"
  $clLines  = $existing.Split("`n")
  $insertAt = -1
  for ($i = 0; $i -lt $clLines.Count; $i++) { if ($clLines[$i].StartsWith("## ")) { $insertAt = $i; break } }
  if ($insertAt -lt 0) {
    $newChangelog = $existing.TrimEnd("`n") + "`n`n" + $entry
  } else {
    $head = if ($insertAt -gt 0) { ($clLines[0..($insertAt - 1)] -join "`n").TrimEnd("`n") } else { "" }
    $tail = ($clLines[$insertAt..($clLines.Count - 1)] -join "`n").TrimStart("`n")
    $newChangelog = if ($head) { "$head`n`n$entry`n$tail" } else { "$entry`n$tail" }
  }
} else {
  $newChangelog = "# Changelog`n`nAll notable changes to $projectName. Newest entries on top.`n`n$entry"
}

# =====================================================================
#  Plan + confirm
# =====================================================================
Say ""
Say "---- plan ----" "Cyan"
if (-not $NoVersion) {
  Say "Version:   v$current  ->  v$newVer"
  foreach ($vf in $versionFiles) {
    Say "  stamp    $($vf.path)$(if (Test-Path $vf.path) { '' } else { '  (MISSING - will be skipped)' })"
  }
} else { Say "Version:   unchanged" }
if ($usedChangelog) { Say "Changelog: $changelogPath  (entry already written - $($lines.Count) bullet$(if($lines.Count -ne 1){'s'}))" }
else { Say "Changelog: $changelogPath  (+$($lines.Count) bullet$(if($lines.Count -ne 1){'s'}))" }
Say "Commit:    $subject"
foreach ($l in $lines) { Say "           $l" "DarkGray" }
Say "Push:      $(if ($NoPush) { 'no (-NoPush)' } else { "yes -> origin/$branch" })"
Say "--------------" "Cyan"

if ($DryRun) { Say ""; Ok "Dry run complete - nothing was changed."; exit 0 }
if (-not $Yes -and (Read-Host "`nProceed? (Y/n)") -eq "n") { Fail "Cancelled. Nothing was modified." }

# =====================================================================
#  WRITE PHASE
# =====================================================================
$touched = @()
function Rollback {
  if ($touched.Count -eq 0) { return }
  Warn ""; Warn "Rolling back: $($touched -join ', ')"
  foreach ($f in $touched) {
    git checkout -- $f 2>$null
    if ($LASTEXITCODE -ne 0) { Warn "  couldn't restore $f - check it by hand" }
  }
}

try {
  if (-not $NoVersion -and -not $skipStamp) {
    foreach ($vf in $versionFiles) {
      if (-not (Test-Path $vf.path)) { Warn "Skipping missing file $($vf.path)"; continue }
      $c  = ReadText $vf.path
      $ms = [regex]::Matches($c, $vf.pattern)
      if ($ms.Count -eq 0) { Warn "No version match in $($vf.path) - skipped"; continue }
      # Replace only the captured digits, walking backwards so offsets stay valid.
      for ($i = $ms.Count - 1; $i -ge 0; $i--) {
        $g = $ms[$i].Groups[1]
        $c = $c.Remove($g.Index, $g.Length).Insert($g.Index, $newVer)
      }
      WriteText $vf.path $c
      $touched += $vf.path
      Ok "  stamped v$newVer in $($vf.path)"
    }
  }

  if ($usedChangelog) {
    Say "  $changelogPath already contains the entry - left as written" "DarkGray"
  } else {
    WriteText $changelogPath $newChangelog
    $touched += $changelogPath
    Ok "  wrote $changelogPath"
  }

  # Commit via a temp file so quotes/emoji in bullets can never break the message.
  $msgFile = [System.IO.Path]::GetTempFileName()
  try {
    WriteText $msgFile $commitMsg
    git add -A
    if ($LASTEXITCODE -ne 0) { throw "git add failed" }
    git commit -F $msgFile
    if ($LASTEXITCODE -ne 0) { throw "git commit failed - see the message above" }
  } finally { Remove-Item $msgFile -Force -ErrorAction SilentlyContinue }
  Ok "Committed: $subject"
}
catch {
  Warn "Release failed: $($_.Exception.Message)"
  if ($Yes -or (Read-Host "Undo the version/changelog edits? (Y/n)") -ne "n") { Rollback }
  Fail "Nothing was pushed."
}

# =====================================================================
#  Push
# =====================================================================
if ($NoPush) { Say ""; Ok "$label committed locally. Push when ready:  git push"; exit 0 }

if (-not ((git remote) -contains "origin")) {
  Say ""; Warn "$label is committed locally, but there's no 'origin' remote."
  Warn "Finish 'Publish to GitHub' in VS Code, then run:  git push -u origin HEAD"
  exit 1
}

git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Say "No upstream for '$branch' - pushing with -u."; git push -u origin HEAD }
else { git push }

if ($LASTEXITCODE -ne 0) {
  Say ""; Warn "The commit is saved, but the push didn't complete."
  Warn "If the remote is ahead, run:  git pull --rebase   then:  git push"
  exit 1
}

Say ""
Ok "Pushed $label."
if ($deployUrl) { Ok "Live in ~30 seconds: $deployUrl" }
