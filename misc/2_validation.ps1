#!/usr/bin/env pwsh
# (Converted from 2_validation.sh to PowerShell. Logic preserved.)

$CSV_PATH = "./repos.csv"
$BBS_BASE_URL = if ($env:BBS_BASE_URL) { $env:BBS_BASE_URL } else { "" }

# Parse args: -c <csv> -b <bbs_base_url>
for ($i=0; $i -lt $args.Count; $i++) {
  switch ($args[$i]) {
    '-c' { $i++; $CSV_PATH = $args[$i] }
    '-b' { $i++; $BBS_BASE_URL = $args[$i] }
    default {
      if ($args[$i] -like '-*') {
        Write-Error "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-b BBS_BASE_URL]"
        exit 1
      }
    }
  }
}

$COMMIT_CHECK = if ($env:COMMIT_CHECK) { $env:COMMIT_CHECK } else { 'true' }
$FAIL_ON_VALIDATION_FAILURES = if ($env:FAIL_ON_VALIDATION_FAILURES) { $env:FAIL_ON_VALIDATION_FAILURES } else { 'false' }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error "[ERROR] GitHub CLI (gh) is not installed. See https://cli.github.com/"
  exit 1
}

# GH auth
if ((-not [string]::IsNullOrEmpty($env:GH_PAT)) -and [string]::IsNullOrEmpty($env:GH_TOKEN)) {
  $env:GH_TOKEN = $env:GH_PAT
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Error "[ERROR] GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT)."
  exit 1
}

if ([string]::IsNullOrEmpty($BBS_BASE_URL)) {
  Write-Error "BBS_BASE_URL is required (pass -b or export BBS_BASE_URL)."
  exit 1
}
$BASE_URL = $BBS_BASE_URL.TrimEnd('/')
$LOG_FILE = "validation-log-$(Get-Date -Format yyyyMMdd).txt"

function Get-AuthHeader {
  if (-not [string]::IsNullOrEmpty($env:BBS_PAT)) {
    return @{ Authorization = "Bearer $($env:BBS_PAT)" }
  } elseif (($env:BBS_AUTH_TYPE -eq 'Basic') -and (-not [string]::IsNullOrEmpty($env:BBS_USERNAME)) -and (-not [string]::IsNullOrEmpty($env:BBS_PASSWORD))) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
    $b64 = [Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $b64" }
  } else {
    Write-Error "[ERROR] Provide Bitbucket credentials via BBS_PAT (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."
    exit 1
  }
}

function Curl-Json([string]$Url) {
  return Invoke-RestMethod -Headers (Get-AuthHeader) -Uri $Url -Method Get
}

function Get-Bbs-Branches([string]$projectKey, [string]$repoSlug) {
  $start = 0
  $branches = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $resp = Curl-Json "$BASE_URL/rest/api/1.0/projects/$projectKey/repos/$repoSlug/branches?limit=500&start=$start"
    if ($resp.values) {
      foreach ($b in $resp.values) {
        if ($b.displayId) { $branches.Add([string]$b.displayId) }
      }
    }
    if ($resp.isLastPage -eq $true) { break }
    $nextStart = $resp.nextPageStart
    if ($null -eq $nextStart -or $nextStart -eq '') { break }
    $start = [int]$nextStart
  }
  return $branches | Sort-Object -Unique
}

function UrlEncode([string]$s) {
  return [System.Uri]::EscapeDataString($s)
}

function Get-Bbs-Commits-Info([string]$projectKey, [string]$repoSlug, [string]$branch) {
  $total = 0
  $latest = ""
  $start = 0
  $limit = 1000
  $encBranch = UrlEncode $branch
  while ($true) {
    $resp = Curl-Json "$BASE_URL/rest/api/1.0/projects/$projectKey/repos/$repoSlug/commits?until=$encBranch&limit=$limit&start=$start"
    $cnt = if ($resp.values) { $resp.values.Count } else { 0 }
    if ([string]::IsNullOrEmpty($latest) -and $cnt -gt 0) {
      $latest = [string]$resp.values[0].id
    }
    $total += $cnt
    if ($resp.isLastPage -eq $true) { break }
    $nextStart = $resp.nextPageStart
    if ($null -eq $nextStart -or $nextStart -eq '') { break }
    $start = [int]$nextStart
  }
  return "$total,$latest"
}

function Gh-Repo-Exists([string]$org, [string]$repo) {
  & gh api -X GET "/repos/$org/$repo" *> $null
  return ($LASTEXITCODE -eq 0)
}

function Get-Gh-Branches([string]$org, [string]$repo) {
  $json = & gh api "/repos/$org/$repo/branches" --paginate
  $arr = $json | ConvertFrom-Json
  $names = $arr | ForEach-Object { $_.name }
  return $names | Sort-Object -Unique
}

function Get-Gh-Commits-Info([string]$org, [string]$repo, [string]$branch) {
  $total = 0
  $latest = ""
  $page = 1
  $per = 100
  $encBranch = UrlEncode $branch
  while ($true) {
    $chunkJson = & gh api "/repos/$org/$repo/commits?sha=$encBranch&page=$page&per_page=$per"
    $chunk = $chunkJson | ConvertFrom-Json
    $count = if ($chunk) { $chunk.Count } else { 0 }
    if ($page -eq 1 -and $count -gt 0) {
      $latest = [string]$chunk[0].sha
    }
    $total += $count
    if ($count -lt $per) { break }
    $page++
  }
  return "$total,$latest"
}

function Status-Marker([string]$ok) {
  if ($ok -eq 'true') { return "✅ Matching" }
  return "❌ Not Matching"
}

Write-Host "=================================================="
Write-Host " Bitbucket ↔ GitHub Migration Validation (CLI) "
Write-Host "=================================================="
Write-Host "Using CSV: $CSV_PATH"
Write-Host "Using Bitbucket Base URL: $BASE_URL"

if (-not (Test-Path -LiteralPath $CSV_PATH)) {
  "[ERROR] CSV file not found: $CSV_PATH" | Tee-Object -FilePath $LOG_FILE -Append
  exit 1
}
if ((Get-Item -LiteralPath $CSV_PATH).Length -eq 0) {
  "[ERROR] CSV has no rows: $CSV_PATH" | Tee-Object -FilePath $LOG_FILE -Append
  exit 1
}

$header = (Get-Content -LiteralPath $CSV_PATH -TotalCount 1)
foreach ($col in @('project-key','project-name','repo','github_org','github_repo')) {
  if ($header -notmatch [Regex]::Escape($col)) {
    Write-Error "Missing required column: $col"
    exit 1
  }
}

$summary_csv = "validation-summary.csv"
"github_org,github_repo,bbs_project_key,bbs_repo,branch_count_bbs,branch_count_gh,branch_count_match,commits_match_all,shas_match_all,gh_notes" | Set-Content -LiteralPath $summary_csv
Write-Host "==> Starting validation..."

$lines = Get-Content -LiteralPath $CSV_PATH | Select-Object -Skip 1
foreach ($line in $lines) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line.Split(',')

  $bbsProjectKey = if ($parts.Count -ge 1) { $parts[0] } else { '' }
  $bbsProjectName = if ($parts.Count -ge 2) { $parts[1] } else { '' }
  $bbsRepoSlug = if ($parts.Count -ge 3) { $parts[2] } else { '' }

  $ghOrg = if ($parts.Count -ge 4) { $parts[3] } else { '' }
  $ghRepo = if ($parts.Count -ge 5) { $parts[4] } else { '' }

  $header_line = "[$(Get-Date)] Processing: $bbsProjectKey/$bbsRepoSlug -> $ghOrg/$ghRepo"
  $header_line | Tee-Object -FilePath $LOG_FILE -Append

  # Optional snapshot (ignore failures)
  & gh repo view "$ghOrg/$ghRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate *> $null

  $ghExists = 'yes'
  if (-not (Gh-Repo-Exists $ghOrg $ghRepo)) {
    $msg = "[$(Get-Date)] GitHub repo not found or inaccessible: $ghOrg/$ghRepo. Treating GH side as empty."
    $msg | Tee-Object -FilePath $LOG_FILE -Append
    $ghExists = 'no'
  }

  $bbsBranches = @(Get-Bbs-Branches $bbsProjectKey $bbsRepoSlug)
  $ghBranches = @()
  if ($ghExists -eq 'yes') { $ghBranches = @(Get-Gh-Branches $ghOrg $ghRepo) }

  $bbsBranchCount = $bbsBranches.Count
  $ghBranchCount = $ghBranches.Count
  $branchCountOk = 'false'
  if ($bbsBranchCount -eq $ghBranchCount) { $branchCountOk = 'true' }

  ("[$(Get-Date)] Branch Count: BBS=$bbsBranchCount GitHub=$ghBranchCount $(Status-Marker $branchCountOk)") | Tee-Object -FilePath $LOG_FILE -Append

  $missingInGH = (Compare-Object -ReferenceObject ($bbsBranches | Sort-Object) -DifferenceObject ($ghBranches | Sort-Object) -PassThru | Where-Object { $_ -in $bbsBranches })
  $missingInBBS = (Compare-Object -ReferenceObject ($bbsBranches | Sort-Object) -DifferenceObject ($ghBranches | Sort-Object) -PassThru | Where-Object { $_ -in $ghBranches })

  if ($missingInGH) {
    ("[$(Get-Date)] Branches missing in GitHub: $((@($missingInGH) -join ', ')),") | Tee-Object -FilePath $LOG_FILE -Append
  }
  if ($missingInBBS) {
    ("[$(Get-Date)] Branches missing in Bitbucket: $((@($missingInBBS) -join ', ')),") | Tee-Object -FilePath $LOG_FILE -Append
  }

  $commitsMatchAll = 'false'
  $shasMatchAll = 'false'

  if ($COMMIT_CHECK -ne 'true') {
    $commitsMatchAll = 'true'
    $shasMatchAll = 'true'
    ("[$(Get-Date)] COMMIT_CHECK=false - skipping per-branch commit/SHA comparison") | Tee-Object -FilePath $LOG_FILE -Append
  } elseif ($ghExists -eq 'yes') {
    $ghDefault = ""
    try { $ghDefault = (& gh api "/repos/$ghOrg/$ghRepo" --jq '.default_branch' 2>$null | Out-String).Trim() } catch { $ghDefault = "" }
    $bbsDefault = ""
    try { $bbsDefault = [string](Curl-Json "$BASE_URL/rest/api/1.0/projects/$bbsProjectKey/repos/$bbsRepoSlug/branches/default").displayId } catch { $bbsDefault = "" }

    $validation_branch = ""
    if ($ghDefault -and (($ghBranches -contains $ghDefault) -or ($bbsBranches -contains $ghDefault))) {
      $validation_branch = $ghDefault
    } elseif ($bbsDefault -and (($ghBranches -contains $bbsDefault) -or ($bbsBranches -contains $bbsDefault))) {
      $validation_branch = $bbsDefault
    }

    $branchesToCheck = New-Object System.Collections.Generic.List[string]
    if ($bbsBranchCount -gt 10 -or $ghBranchCount -gt 10) {
      if ($validation_branch) { $branchesToCheck.Add($validation_branch) }
      foreach ($b in $ghBranches) {
        if ($b -eq $validation_branch) { continue }
        $branchesToCheck.Add($b)
        if ($branchesToCheck.Count -ge 10) { break }
      }
      ("[$(Get-Date)] Repo has >10 branches. Commit/SHA check limited to first $($branchesToCheck.Count) branches (default branch first).") | Tee-Object -FilePath $LOG_FILE -Append
    } elseif ($validation_branch) {
      $branchesToCheck.Add($validation_branch)
      ("[$(Get-Date)] Repo has <=10 branches. Commit/SHA check limited to default branch: '$validation_branch'.") | Tee-Object -FilePath $LOG_FILE -Append
    } else {
      ("[$(Get-Date)] Could not determine a default branch for commit/SHA check.") | Tee-Object -FilePath $LOG_FILE -Append
    }

    if ($branchesToCheck.Count -gt 0) {
      $commitsMatchAll = 'true'
      $shasMatchAll = 'true'
      foreach ($br in $branchesToCheck) {
        if ($ghBranches -notcontains $br) {
          ("[$(Get-Date)] Branch '$br': missing in GitHub branches list $(Status-Marker 'false')") | Tee-Object -FilePath $LOG_FILE -Append
          $commitsMatchAll = 'false'; $shasMatchAll = 'false'; continue
        }
        if ($bbsBranches -notcontains $br) {
          ("[$(Get-Date)] Branch '$br': missing in Bitbucket branches list $(Status-Marker 'false')") | Tee-Object -FilePath $LOG_FILE -Append
          $commitsMatchAll = 'false'; $shasMatchAll = 'false'; continue
        }
        $ghInfo = Get-Gh-Commits-Info $ghOrg $ghRepo $br
        $bbsInfo = Get-Bbs-Commits-Info $bbsProjectKey $bbsRepoSlug $br

        $ghCount = $ghInfo.Split(',')[0]
        $ghSha = $ghInfo.Split(',')[1]
        $bbsCount = $bbsInfo.Split(',')[0]
        $bbsSha = $bbsInfo.Split(',')[1]

        $countOk = 'false'
        if ($ghCount -eq $bbsCount) { $countOk = 'true' }
        $shaOk = 'false'
        if ($ghSha -eq $bbsSha) { $shaOk = 'true' }

        if ($countOk -eq 'false') { $commitsMatchAll = 'false' }
        if ($shaOk -eq 'false') { $shasMatchAll = 'false' }

        ("[$(Get-Date)] Branch '$br': BBS Commits=$bbsCount GitHub Commits=$ghCount $(Status-Marker $countOk)") | Tee-Object -FilePath $LOG_FILE -Append
        ("[$(Get-Date)] Branch '$br': BBS SHA=$bbsSha GitHub SHA=$ghSha $(Status-Marker $shaOk)") | Tee-Object -FilePath $LOG_FILE -Append
      }
    }
  }

  $gh_notes = ""
  if ($ghExists -eq 'no') {
    $gh_notes = "repo not found or no access"
  } elseif ($ghBranchCount -eq 0 -and $bbsBranchCount -gt 0) {
    $gh_notes = "no branches on GH"
  }

  ("[$(Get-Date)] Validation complete for $ghOrg/$ghRepo") | Tee-Object -FilePath $LOG_FILE -Append
  "$ghOrg,$ghRepo,$bbsProjectKey,$bbsRepoSlug,$bbsBranchCount,$ghBranchCount,$branchCountOk,$commitsMatchAll,$shasMatchAll,$gh_notes" | Add-Content -LiteralPath $summary_csv
}

("[$(Get-Date)] All validations from CSV completed") | Tee-Object -FilePath $LOG_FILE -Append

$md = "validation_summary_$(Get-Date -Format yyyyMMdd).md"
$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add("| GitHub Repo | BBS Repo | Branch Count (BBS/GH) | Branch Count Match | All Commit Counts Match | All Latest SHAs Match | Notes |")
$mdLines.Add("|---|---|---:|---|---|---|---|")

foreach ($row in (Get-Content -LiteralPath $summary_csv | Select-Object -Skip 1)) {
  if ([string]::IsNullOrWhiteSpace($row)) { continue }
  $c = $row.Split(',')
  $ghOrg = $c[0]; $ghRepo = $c[1]
  $bbsKey = $c[2]; $bbsRepo = $c[3]
  $bcB = $c[4]; $ghC = $c[5]
  $bcOk = $c[6]; $ccOk = $c[7]; $shaOk = $c[8]
  $notes = if ($c.Count -ge 10) { $c[9] } else { '' }

  if ([string]::IsNullOrEmpty($ghOrg) -and [string]::IsNullOrEmpty($ghRepo)) { continue }

  $mdLines.Add(("| {0}/{1} | {2}/{3} | {4}/{5} | {6} | {7} | {8} | {9} |" -f $ghOrg,$ghRepo,$bbsKey,$bbsRepo,$bcB,$ghC,
    $(if($bcOk -eq 'true'){'✅'}else{'❌'}),
    $(if($ccOk -eq 'true'){'✅'}else{'❌'}),
    $(if($shaOk -eq 'true'){'✅'}else{'❌'}),
    $notes))
}

$mdLines | Set-Content -LiteralPath $md
Write-Host "=======================Summary==========================="
Get-Content -LiteralPath $md
Write-Host "======================Completed==========================="

$rows = Get-Content -LiteralPath $summary_csv | Select-Object -Skip 1 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$total_validated = @($rows).Count
$passed = 0
$discrepancies = New-Object System.Collections.Generic.List[string]
foreach ($row in $rows) {
  $c = $row.Split(',')
  if ($c[6] -eq 'true' -and $c[7] -eq 'true' -and $c[8] -eq 'true') {
    $passed++
  } else {
    $notes = if ($c.Count -ge 10) { $c[9] } else { '' }
    $discrepancies.Add("$($c[0])/$($c[1]) ($notes)")
  }
}
$failed = $total_validated - $passed

if ($total_validated -eq 0) {
  Write-Host "::notice::No repositories were validated."
} elseif ($failed -eq 0) {
  Write-Host "::notice::All $total_validated repositories validated successfully (branches, commits and SHAs match)"
} elseif ($passed -eq 0) {
  Write-Host "::error::All $total_validated repositories have validation discrepancies"
  foreach ($d in $discrepancies) { Write-Host "::error::Validation discrepancy: $d" }
} else {
  Write-Host "::warning::Validation completed with discrepancies: $passed matched, $failed with issues (of $total_validated)"
  foreach ($d in $discrepancies) { Write-Host "::warning::Validation discrepancy: $d" }
}

if ($FAIL_ON_VALIDATION_FAILURES -eq 'true' -and $failed -gt 0) {
  Write-Host "::error::FAIL_ON_VALIDATION_FAILURES=true and $failed repository(ies) failed validation."
  exit 1
}
exit 0
