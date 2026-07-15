#!/usr/bin/env pwsh
# (Converted from 0_prechecks.sh to PowerShell. Logic preserved.)

$CSV_PATH = "repos.csv"
$OUTPUT_PATH = ""
$PROJECT_KEYS_CSV = ""

# Preserve original behavior: strip quotes from default CSV_PATH before arg parsing
try {
  if (Test-Path -LiteralPath $CSV_PATH) {
    (Get-Content -LiteralPath $CSV_PATH -Raw) -replace '"', '' | Set-Content -LiteralPath $CSV_PATH -NoNewline
  }
} catch { }

# Parse args similar to getopts: -c <csv> -o <output> -p <KEY1,KEY2>
for ($i=0; $i -lt $args.Count; $i++) {
  switch ($args[$i]) {
    '-c' { $i++; if ($i -ge $args.Count) { Write-Error "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]"; exit 1 }
           $CSV_PATH = $args[$i] }
    '-o' { $i++; if ($i -ge $args.Count) { Write-Error "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]"; exit 1 }
           $OUTPUT_PATH = $args[$i] }
    '-p' { $i++; if ($i -ge $args.Count) { Write-Error "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]"; exit 1 }
           $PROJECT_KEYS_CSV = $args[$i] }
    default {
      if ($args[$i] -like '-*') {
        Write-Error "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]"
        exit 1
      }
    }
  }
}

if ([string]::IsNullOrEmpty($env:BBS_BASE_URL)) {
  Write-Error "[ERROR] BBS_BASE_URL env var is required."
  exit 1
}
$BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')

$LOG_FILE = "bbs-prechecks-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $color = switch ($Level) { 'OK' {'Green'} 'WARNING' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
  Write-Host "[$Level] $Message" -ForegroundColor $color
  Add-Content -LiteralPath $LOG_FILE -Value "[$Level] $Message"
}

function Get-AuthHeader {
  if (-not [string]::IsNullOrEmpty($env:BBS_PAT)) {
    return @{ Authorization = "Bearer $($env:BBS_PAT)" }
  } elseif (($env:BBS_AUTH_TYPE -eq 'Basic') -and (-not [string]::IsNullOrEmpty($env:BBS_USERNAME)) -and (-not [string]::IsNullOrEmpty($env:BBS_PASSWORD))) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
    $b64 = [Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $b64" }
  } else {
    Write-Error "[ERROR] Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."
    exit 1
  }
}

function Curl-Json([string]$Url) {
  $hdr = Get-AuthHeader
  return Invoke-RestMethod -Headers $hdr -Uri $Url -Method Get
}

function Get-BbsInstallPath {
  if ($env:BITBUCKET_HOME -and (Test-Path -LiteralPath $env:BITBUCKET_HOME -PathType Container)) {
    Write-Log "Bitbucket Server home found via BITBUCKET_HOME: $($env:BITBUCKET_HOME)" 'OK'
    return
  }
  foreach ($p in @('/var/atlassian/application-data/bitbucket','/opt/atlassian/bitbucket','C:\Atlassian\ApplicationData\Bitbucket','C:\Program Files\Atlassian\Bitbucket')) {
    if (Test-Path -LiteralPath $p -PathType Container) {
      $env:BITBUCKET_HOME = $p
      Write-Log "Bitbucket Server found at default location: $p" 'OK'
      return
    }
  }
  $launcher = Get-Command start-bitbucket.sh, start-bitbucket.bat, bitbucket -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($launcher) {
    $bbsHome = Split-Path -Parent (Split-Path -Parent $launcher.Source)
    if (-not $bbsHome) { $bbsHome = Split-Path -Parent $launcher.Source }
    $env:BITBUCKET_HOME = $bbsHome
    Write-Log "Bitbucket Server launcher found on PATH: $($launcher.Source) (home: $bbsHome)" 'OK'
    return
  }
  if (-not [Console]::IsInputRedirected) {
    $userPath = Read-Host "Bitbucket Server install not found (checked BITBUCKET_HOME, default dirs, PATH). Enter its path (blank to skip)"
    if ($userPath -and (Test-Path -LiteralPath $userPath -PathType Container)) {
      $env:BITBUCKET_HOME = $userPath
      Write-Log "Using Bitbucket Server path: $userPath" 'OK'
    } elseif ($userPath) {
      Write-Log "Path does not exist: $userPath. Continuing without a local Bitbucket Server path." 'WARNING'
    } else {
      Write-Log "No path provided. Continuing without a local Bitbucket Server path." 'WARNING'
    }
  } else {
    Write-Log "Bitbucket Server install not found locally. Continuing (remote/SSH migration does not require a local install)." 'WARNING'
  }
}
Get-BbsInstallPath

# Preflight auth test
try {
  $null = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$BASE_URL/rest/api/1.0/projects?limit=1" -Method Get
} catch {
  $code = 0
  if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
  switch ($code) {
    { $_ -in 401,403 } { Write-Log "Bitbucket auth failed (HTTP $code). Verify BBS_PAT / credentials and permissions." 'ERROR' }
    404               { Write-Log "Bitbucket endpoint not found (HTTP 404). Verify BBS_BASE_URL: $BASE_URL" 'ERROR' }
    0                 { Write-Log "Network/DNS/TLS issue reaching Bitbucket. Verify connectivity to $BASE_URL." 'ERROR' }
    default           { Write-Log "Bitbucket preflight failed (HTTP $code) for $BASE_URL." 'ERROR' }
  }
  exit 1
}

$timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
$OUTPUT_CSV = if ([string]::IsNullOrEmpty($OUTPUT_PATH)) { "bbs_pr_validation_output-$timestamp.csv" } else { $OUTPUT_PATH }

$PROJECT_KEYS = @()
if (-not [string]::IsNullOrEmpty($PROJECT_KEYS_CSV)) {
  $PROJECT_KEYS = $PROJECT_KEYS_CSV.Split(',')
}

function Discover-Projects {
  $start = 0
  $results = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $resp = Curl-Json "$BASE_URL/rest/api/1.0/projects?limit=100&start=$start"
    if ($resp.values) {
      foreach ($v in $resp.values) { if ($v.key) { $results.Add([string]$v.key) } }
    }
    if ($resp.isLastPage -eq $true) { break }
    $nextStart = $resp.nextPageStart
    if ($null -eq $nextStart -or $nextStart -eq '') { break }
    $start = [int]$nextStart
  }
  return $results
}

function Discover-Repos-For-Project([string]$projectKey) {
  $start = 0
  while ($true) {
    $resp = Curl-Json "$BASE_URL/rest/api/1.0/projects/$projectKey/repos?limit=100&start=$start"
    if ($resp.values) {
      foreach ($r in $resp.values) {
        $pname = $r.project.name
        $slug = $r.slug
        $archived = $r.archived
        "$pname,$slug,$archived"
      }
    }
    if ($resp.isLastPage -eq $true) { break }
    $nextStart = $resp.nextPageStart
    if ($null -eq $nextStart -or $nextStart -eq '') { break }
    $start = [int]$nextStart
  }
}

function Get-Open-Pr-Count([string]$projectKey, [string]$repoSlug) {
  $start = 0
  $total = 0
  while ($true) {
    try {
      $resp = Curl-Json "$BASE_URL/rest/api/1.0/projects/$projectKey/repos/$repoSlug/pull-requests?state=OPEN&limit=100&start=$start"
    } catch {
      return "ERROR"
    }
    if ($resp.values) { $total += @($resp.values).Count }
    if ($resp.isLastPage -eq $true) { break }
    $nextStart = $resp.nextPageStart
    if ($null -eq $nextStart -or $nextStart -eq '') { break }
    $start = [int]$nextStart
  }
  return $total
}

Write-Host ""
Write-Host " Bitbucket Pipeline Readiness Check (Open PRs only) "
Write-Host "===================================================="

$rows_tmp = [System.IO.Path]::GetTempFileName()

if ((Test-Path -LiteralPath $CSV_PATH) -and ((Get-Item -LiteralPath $CSV_PATH).Length -gt 0)) {
  $header = (Get-Content -LiteralPath $CSV_PATH -TotalCount 1)
  if (($header -match 'project-key') -and ($header -match ',repo')) {
    Get-Content -LiteralPath $CSV_PATH | Select-Object -Skip 1 | Set-Content -LiteralPath $rows_tmp
  } else {
    Write-Host "[ERROR] CSV missing minimum columns: project-key,repo"
    Write-Host "[INFO] Falling back to auto-discovery."
  }
}

if (-not (Test-Path -LiteralPath $rows_tmp) -or ((Get-Item -LiteralPath $rows_tmp).Length -eq 0)) {
  Write-Host "[INFO] Auto-discovering projects & repos..."
  $projects = Discover-Projects
  foreach ($pk in $projects) {
    if ($PROJECT_KEYS.Count -gt 0) {
      $match = $false
      foreach ($filter in $PROJECT_KEYS) { if ($pk -eq $filter) { $match = $true } }
      if ($match -eq $false) { continue }
    }

    $lines = Discover-Repos-For-Project $pk
    foreach ($ln in $lines) {
      $parts = $ln.Split(',')
      $pname = $parts[0]
      $rslug = $parts[1]
      $archived = if ($parts.Count -ge 3) { $parts[2] } else { '' }
      "$pk,$pname,$rslug,$archived" | Add-Content -LiteralPath $rows_tmp
    }
  }
}

$ready_tmp = [System.IO.Path]::GetTempFileName()
$results_tmp = [System.IO.Path]::GetTempFileName()
"project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate" | Set-Content -LiteralPath $results_tmp

$total_open_prs = 0
$prCheckFailed = $false
foreach ($line in (Get-Content -LiteralPath $rows_tmp)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line.Split(',')
  $projKey = $parts[0]
  $projName = if ($parts.Count -ge 2) { $parts[1] } else { '' }
  $repoSlug = if ($parts.Count -ge 3) { $parts[2] } else { '' }
  $isArchived = if ($parts.Count -ge 4) { $parts[3] } else { '' }

  $prResult = Get-Open-Pr-Count $projKey $repoSlug
  if ($prResult -eq "ERROR") {
    $prCheckFailed = $true
    Write-Host "[ERROR] $projKey/${repoSlug}: failed to query open PRs (API error)"
    "$projKey,$projName,$repoSlug,$(if([string]::IsNullOrEmpty($isArchived)){'false'}else{$isArchived}),ERROR,API_FAILURE,false" | Add-Content -LiteralPath $results_tmp
    continue
  }
  $openPrs = [int]$prResult
  $total_open_prs += $openPrs

  $warns = ""
  if ($openPrs -gt 0) {
    $warns = "OPEN_PRS"
    Write-Host "[WARNING] $projKey/$repoSlug PRs(Open): $openPrs"
  } else {
    Write-Host "[OK] $projKey/$repoSlug PRs(Open): $openPrs"
    "$projKey/$repoSlug" | Add-Content -LiteralPath $ready_tmp
  }

  $ready = $false
  if ([string]::IsNullOrEmpty($warns)) { $ready = $true }

  "$projKey,$projName,$repoSlug,$(if([string]::IsNullOrEmpty($isArchived)){'false'}else{$isArchived}),$openPrs,$warns,$ready" | Add-Content -LiteralPath $results_tmp
}

Move-Item -Force -LiteralPath $results_tmp -Destination $OUTPUT_CSV
Write-Host "[INFO] Wrote precheck CSV: $OUTPUT_CSV"

if ((Test-Path -LiteralPath $ready_tmp) -and ((Get-Item -LiteralPath $ready_tmp).Length -gt 0)) {
  Write-Host ""
  Write-Host "[READY] Repos ready to migrate (no open PRs)✅:"
  foreach ($r in (Get-Content -LiteralPath $ready_tmp)) {
    if (-not [string]::IsNullOrWhiteSpace($r)) { Write-Host " - $r" }
  }
} else {
  Write-Host ""
  Write-Host "[READY] No repos are currently without open PRs."
}

$total_repos = (Get-Content -LiteralPath $rows_tmp).Count
Write-Host ""
Write-Host "[SUMMARY] Total repos: $total_repos"
Write-Host "Open PRs total: $total_open_prs"
Write-Host "======================Completed============================="

$hasActiveItems = $total_open_prs -gt 0
if ($prCheckFailed -and -not $hasActiveItems) {
  Write-Host "`nValidation checks could not be completed due to API failures. Please review errors before proceeding.`n" -ForegroundColor Red
} elseif ($prCheckFailed -and $hasActiveItems) {
  Write-Host "`nOpen pull requests detected, but some validation checks failed. Review warnings and errors before proceeding.`n" -ForegroundColor Yellow
} elseif (-not $prCheckFailed -and $hasActiveItems) {
  Write-Host "`nOpen pull requests found. Continue with migration if you have reviewed and are comfortable proceeding.`n" -ForegroundColor Yellow
} else {
  Write-Host "`nNo open pull requests detected. You can proceed with migration.`n" -ForegroundColor Green
}
