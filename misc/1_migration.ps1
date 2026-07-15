#!/usr/bin/env pwsh
# (Converted from 1_migration.sh to PowerShell. Logic preserved.)

$VERBOSE = if ($env:VERBOSE) { $env:VERBOSE } else { "0" }

# CLI args defaults
$MAX_CONCURRENT = 3
$CSV_PATH = "repos.csv"
$OUTPUT_PATH = ""
$TARGET_API_URL = if ($env:TARGET_API_URL) { $env:TARGET_API_URL } else { "https://api.github.com" }

function LogV([string]$msg) {
  if ($VERBOSE -eq '1') { Write-Host "[DEBUG] $msg" }
}

# Parse args (supports bash-style --flags)
for ($i=0; $i -lt $args.Count; $i++) {
  $a = $args[$i]
  switch ($a) {
    '--max-concurrent' { $i++; $MAX_CONCURRENT = [int]$args[$i] }
    '--csv' { $i++; $CSV_PATH = $args[$i] }
    '--output' { $i++; $OUTPUT_PATH = $args[$i] }
    '--target-api-url' { $i++; $TARGET_API_URL = $args[$i] }
    '--github-api-url' { $i++; $TARGET_API_URL = $args[$i] }
    default {
      if ($a -like '-*') {
        Write-Host "`e[31m[ERROR] Unknown option: $a`e[0m"
        exit 1
      } else {
        Write-Host "`e[31m[ERROR] Unexpected positional arg: $a`e[0m"
        exit 1
      }
    }
  }
}

# Validate settings
if (-not ($MAX_CONCURRENT -is [int])) {
  Write-Host "`e[31m[ERROR] --max-concurrent must be an integer`e[0m"
  exit 1
}
if ($MAX_CONCURRENT -gt 20) {
  Write-Host "`e[31m[ERROR] Maximum concurrent migrations ($MAX_CONCURRENT) exceeds the allowed limit of 20.`e[0m"
  exit 1
}
if ($MAX_CONCURRENT -lt 1) {
  Write-Host "`e[31m[ERROR] --max-concurrent must be at least 1.`e[0m"
  exit 1
}

# Normalize CRLF if present (Windows-generated CSV)
try {
  if (Test-Path -LiteralPath $CSV_PATH) {
    (Get-Content -LiteralPath $CSV_PATH) | ForEach-Object { $_ -replace "`r$", "" } | Set-Content -LiteralPath $CSV_PATH
  }
} catch { }

if (-not (Test-Path -LiteralPath $CSV_PATH)) {
  Write-Host "`e[31m[ERROR] CSV file not found: $CSV_PATH`e[0m"
  exit 1
}

$OUTPUT_CSV_PATH = if ([string]::IsNullOrEmpty($OUTPUT_PATH)) {
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  "repo_migration_output-$timestamp.csv"
} else {
  $OUTPUT_PATH
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Host "`e[31m[ERROR] GitHub CLI (gh) is not installed. See https://cli.github.com/`e[0m"
  exit 1
}
LogV "gh version: $((& gh --version | Select-Object -First 1))"
& gh bbs2gh --version *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "`e[31m[ERROR] Required gh extension 'gh-bbs2gh' is not installed. Install with: gh extension install github/gh-bbs2gh`e[0m"
  exit 1
}
LogV "gh bbs2gh version: $((& gh bbs2gh --version 2>$null | Select-Object -First 1))"

# gh auth
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "`e[31m[ERROR] GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT).`e[0m"
  exit 1
}

# BBS env validation
if ([string]::IsNullOrEmpty($env:BBS_BASE_URL) -or [string]::IsNullOrEmpty($env:BBS_USERNAME) -or [string]::IsNullOrEmpty($env:BBS_PASSWORD)) {
  Write-Host "`e[31m[ERROR] BBS_BASE_URL, BBS_USERNAME, and BBS_PASSWORD must be set.`e[0m"
  exit 1
}
$BBS_BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')
LogV "Using BBS_BASE_URL=$BBS_BASE_URL"

if ([string]::IsNullOrEmpty($env:SSH_USER)) {
  Write-Host "`e[31m[ERROR] SSH_USER must be set.`e[0m"
  exit 1
}

if ([string]::IsNullOrEmpty($env:SSH_PRIVATE_KEY_PATH) -and [string]::IsNullOrEmpty($env:SSH_PRIVATE_KEY)) {
  Write-Host "`e[31m[ERROR] Provide SSH_PRIVATE_KEY_PATH or SSH_PRIVATE_KEY.`e[0m"
  exit 1
}

LogV "Using TARGET_API_URL=$TARGET_API_URL"

# Storage auto-detection (AWS S3 / Azure / GitHub-owned)
$STORAGE_ARGS = @()
function Choose-Storage-Backend {
  $hasAzure = -not [string]::IsNullOrEmpty($env:AZURE_STORAGE_CONNECTION_STRING)
  $hasAws = ($env:AWS_ACCESS_KEY_ID -or $env:AWS_SECRET_ACCESS_KEY -or $env:AWS_BUCKET_NAME -or $env:AWS_S3_BUCKET -or $env:AWS_BUCKET -or $env:AWS_REGION -or $env:AWS_DEFAULT_REGION)

  if ($hasAws -and $hasAzure) {
    Write-Host "`e[31m[ERROR] Both AWS and Azure storage variables are set. Please configure only one storage backend.`e[0m"
    return $false
  }

  if ($hasAws) {
    $bucket = if ($env:AWS_BUCKET_NAME) { $env:AWS_BUCKET_NAME } elseif ($env:AWS_S3_BUCKET) { $env:AWS_S3_BUCKET } else { $env:AWS_BUCKET }
    $region = if ($env:AWS_REGION) { $env:AWS_REGION } else { $env:AWS_DEFAULT_REGION }

    if (-not $env:AWS_ACCESS_KEY_ID -or -not $env:AWS_SECRET_ACCESS_KEY -or -not $bucket -or -not $region) {
      Write-Host "`e[31m[ERROR] AWS storage detected but missing required variables.`e[0m"
      Write-Host "`e[31m[ERROR] Required: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET_NAME (or AWS_S3_BUCKET/AWS_BUCKET), AWS_REGION (or AWS_DEFAULT_REGION).`e[0m"
      return $false
    }

    $script:STORAGE_ARGS = @('--aws-bucket-name', $bucket, '--aws-region', $region)
    LogV "Storage backend: AWS S3 (bucket=$bucket, region=$region)"
    return $true
  }

  if ($hasAzure) {
    $script:STORAGE_ARGS = @()
    LogV "Storage backend: Azure Blob (AZURE_STORAGE_CONNECTION_STRING detected)"
    return $true
  }

  $script:STORAGE_ARGS = @('--use-github-storage')
  LogV "Storage backend: GitHub-owned storage (--use-github-storage)"
  return $true
}

if (-not (Choose-Storage-Backend)) { exit 1 }

# CSV helpers (robust parsing)
function Parse-CsvLine([string]$line) {
  $fields = New-Object System.Collections.Generic.List[string]
  $field = ''
  $inQuotes = $false
  for ($i=0; $i -lt $line.Length; $i++) {
    $char = $line[$i]
    $next = if ($i+1 -lt $line.Length) { $line[$i+1] } else { [char]0 }

    if ($char -eq '"') {
      if ($inQuotes) {
        if ($next -eq '"') {
          $field += '"'
          $i++
        } else {
          $inQuotes = $false
        }
      } else {
        $inQuotes = $true
      }
    } elseif (($char -eq ',') -and (-not $inQuotes)) {
      $fields.Add($field)
      $field = ''
    } else {
      $field += $char
    }
  }
  $fields.Add($field)
  return ,$fields.ToArray()
}

function Strip-Quotes([string]$s) {
  if ($null -eq $s) { return '' }
  if ($s.StartsWith('"')) { $s = $s.Substring(1) }
  if ($s.EndsWith('"')) { $s = $s.Substring(0, $s.Length-1) }
  return $s
}

$REQUIRED_COLUMNS = @('project-key','project-name','repo','github_org','github_repo','gh_repo_visibility')
$HEADER_LINE = (Get-Content -LiteralPath $CSV_PATH -TotalCount 1)
$HEADER_FIELDS = Parse-CsvLine $HEADER_LINE

$COLIDX = @{}
for ($idx=0; $idx -lt $HEADER_FIELDS.Count; $idx++) {
  $name = $HEADER_FIELDS[$idx]
  $name = $name.Trim('"')
  $COLIDX[$name] = $idx
}

$missing = @()
foreach ($col in $REQUIRED_COLUMNS) {
  if (-not $COLIDX.ContainsKey($col)) { $missing += $col }
}
if ($missing.Count -gt 0) {
  Write-Host "`e[31m[ERROR] CSV missing required columns: $($missing -join ' ')`e[0m"
  Write-Host "`e[31m[ERROR] Required: $($REQUIRED_COLUMNS -join ' ')`e[0m"
  exit 1
}

# Status CSV writers
function Write-Migration-Status-Csv-Header {
  "project-key,project-name,repo,github_org,github_repo,gh_repo_visibility,Migration_Status,Log_File" | Set-Content -LiteralPath $OUTPUT_CSV_PATH
}

function Append-Status-Row($projectKey,$projectName,$repo,$github_org,$github_repo,$gh_repo_visibility,$status,$log_file) {
  ('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f $projectKey,$projectName,$repo,$github_org,$github_repo,$gh_repo_visibility,$status,$log_file) | Add-Content -LiteralPath $OUTPUT_CSV_PATH
}

function Update-Repo-Status-In-Csv($target_org,$target_repo,$new_status,$log_file) {
  $tmp = [System.IO.Path]::GetTempFileName()
  $lines = Get-Content -LiteralPath $OUTPUT_CSV_PATH
  if ($lines.Count -eq 0) { return }
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add($lines[0])
  for ($i=1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $F = Parse-CsvLine $line
    $projectKey = Strip-Quotes $F[0]
    $projectName = Strip-Quotes $F[1]
    $repo = Strip-Quotes $F[2]
    $github_org = Strip-Quotes $F[3]
    $github_repo = Strip-Quotes $F[4]
    $gh_repo_visibility = Strip-Quotes $F[5]
    $status = Strip-Quotes $F[6]
    $cur_log = Strip-Quotes $F[7]

    if (($github_org -eq $target_org) -and ($github_repo -eq $target_repo)) {
      $out.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f $projectKey,$projectName,$repo,$github_org,$github_repo,$gh_repo_visibility,$new_status,$log_file))
    } else {
      $out.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}"' -f $projectKey,$projectName,$repo,$github_org,$github_repo,$gh_repo_visibility,$status,$cur_log))
    }
  }
  $out | Set-Content -LiteralPath $tmp
  Move-Item -Force -LiteralPath $tmp -Destination $OUTPUT_CSV_PATH
}

# Queues and tracking
$JOB_JOBS = @{}      # job.Id -> repo_info
$JOB_LOGS = @{}      # job.Id -> log file
$JOB_REPOKEY = @{}   # job.Id -> "github_org,github_repo"
$JOB_LASTLEN = @{}   # job.Id -> last printed length (bytes)

$QUEUE = New-Object System.Collections.Generic.List[string]
$MIGRATED = New-Object System.Collections.Generic.List[string]
$FAILED = New-Object System.Collections.Generic.List[string]

# Load queue from CSV rows (skip header)
$LINE_NUM = 0
foreach ($line in (Get-Content -LiteralPath $CSV_PATH)) {
  $LINE_NUM++
  if ($LINE_NUM -eq 1) { continue }
  if ([string]::IsNullOrWhiteSpace($line)) { continue }

  $F = Parse-CsvLine $line
  $projectKey = Strip-Quotes $F[$COLIDX['project-key']]
  $projectName = Strip-Quotes $F[$COLIDX['project-name']]
  $repoSlug = Strip-Quotes $F[$COLIDX['repo']]
  $github_org = Strip-Quotes $F[$COLIDX['github_org']]
  $github_repo = Strip-Quotes $F[$COLIDX['github_repo']]
  $gh_repo_visibility = Strip-Quotes $F[$COLIDX['gh_repo_visibility']]

  if ([string]::IsNullOrEmpty($projectKey) -or [string]::IsNullOrEmpty($repoSlug) -or [string]::IsNullOrEmpty($github_org) -or [string]::IsNullOrEmpty($github_repo) -or [string]::IsNullOrEmpty($gh_repo_visibility)) {
    Write-Host "[WARNING] Skipping malformed line $($LINE_NUM): missing required columns" 
    Write-Host "Ensure project-key, repo, github_org, github_repo, gh_repo_visibility are populated."
    continue
  }

  $QUEUE.Add("$projectKey,$projectName,$repoSlug,$github_org,$github_repo,$gh_repo_visibility")
}

# Initialize output CSV with Pending
Write-Migration-Status-Csv-Header
foreach ($item in $QUEUE) {
  $p = $item.Split(',',6)
  Append-Status-Row $p[0] $p[1] $p[2] $p[3] $p[4] $p[5] "Pending" ""
}

Write-Host "[INFO] Starting migration with $MAX_CONCURRENT concurrent jobs..."
Write-Host "[INFO] Processing $($QUEUE.Count) repositories from: $CSV_PATH"
Write-Host "[INFO] Initialized migration status output: $OUTPUT_CSV_PATH"

# Status bar
$STATUS_LINE_WIDTH = 0
function Show-Status-Bar {
  $queue_count = $QUEUE.Count
  $progress_count = $JOB_JOBS.Keys.Count
  $migrated_count = $MIGRATED.Count
  $failed_count = $FAILED.Count
  $status = "QUEUE: $queue_count / IN PROGRESS: $progress_count / MIGRATED: $migrated_count / FAILED: $failed_count"
  if ($status.Length -gt $STATUS_LINE_WIDTH) { $script:STATUS_LINE_WIDTH = $status.Length }
  $pad = $status.PadRight($STATUS_LINE_WIDTH)
  Write-Host -NoNewline "`r`e[36m$pad`e[0m"
}

function Read-FileDelta([string]$path, [long]$lastLen) {
  if (-not (Test-Path -LiteralPath $path)) { return @('', $lastLen) }
  $fi = Get-Item -LiteralPath $path
  $newLen = [long]$fi.Length
  if ($newLen -le $lastLen) { return @('', $newLen) }

  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $fs.Seek($lastLen, [System.IO.SeekOrigin]::Begin) | Out-Null
    $buf = New-Object byte[] ($newLen - $lastLen)
    $read = $fs.Read($buf, 0, $buf.Length)
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $text = $text -replace "`r", ""
    return @($text, $newLen)
  } finally {
    $fs.Close()
  }
}

# Main loop
while (($QUEUE.Count -gt 0) -or ($JOB_JOBS.Keys.Count -gt 0)) {
  # Start new jobs up to concurrency
  while (($JOB_JOBS.Keys.Count -lt $MAX_CONCURRENT) -and ($QUEUE.Count -gt 0)) {
    $repo_info = $QUEUE[0]
    $QUEUE.RemoveAt(0)

    $parts = $repo_info.Split(',',6)
    $projectKey = $parts[0]
    $projectName = $parts[1]
    $repoSlug = $parts[2]
    $github_org = $parts[3]
    $github_repo = $parts[4]
    $gh_repo_visibility = $parts[5]

    $log_file = "migration-$github_repo-$(Get-Date -Format yyyyMMdd-HHmmss).txt"

    Update-Repo-Status-In-Csv $github_org $github_repo "In Progress" $log_file

    # Start background job (writes ONLY to log file and .result)
    $job = Start-Job -ScriptBlock {
      param($projectKey,$projectName,$repoSlug,$github_org,$github_repo,$gh_repo_visibility,$log_file,$BBS_BASE_URL,$SSH_USER,$SSH_PRIVATE_KEY_PATH,$SSH_PRIVATE_KEY,$TARGET_API_URL,$STORAGE_ARGS)

      function Resolve-KeyPath([string]$input, [string]$fallbackPath) {
        if (-not [string]::IsNullOrEmpty($input) -and $input.Contains('BEGIN') -and $input.Contains('PRIVATE KEY')) {
          $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bbs2gh_sshkey_{0}.pem" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
          Set-Content -LiteralPath $tmp -Value $input -NoNewline
          try { & chmod 600 $tmp *> $null } catch { }
          return $tmp
        } elseif ([string]::IsNullOrEmpty($input) -and -not [string]::IsNullOrEmpty($fallbackPath)) {
          return $fallbackPath
        } else {
          return $input
        }
      }

      function Is-KeyEncrypted([string]$keyPath) {
        if (-not (Test-Path -LiteralPath $keyPath)) { return $false }
        $txt = Get-Content -LiteralPath $keyPath -Raw -ErrorAction SilentlyContinue
        if ($txt -match 'ENCRYPTED') { return $true }
        if (($txt -match 'BEGIN OPENSSH PRIVATE KEY') -and ($txt -match 'bcrypt')) { return $true }
        return $false
      }

      function Append-Log([string]$msg) {
        Add-Content -LiteralPath $log_file -Value $msg
      }

      try {
        Append-Log ("[{0}] [START] Migration: {1}/{2} -> {3}/{4} (gh_repo_visibility: {5})" -f (Get-Date), $projectKey, $repoSlug, $github_org, $github_repo, $gh_repo_visibility)

        $resolvedKey = Resolve-KeyPath $SSH_PRIVATE_KEY $SSH_PRIVATE_KEY_PATH
        if ([string]::IsNullOrEmpty($resolvedKey) -or -not (Test-Path -LiteralPath $resolvedKey)) {
          Append-Log ("[{0}] [ERROR] SSH private key path is invalid or missing: {1}" -f (Get-Date), ($resolvedKey ?? '<empty>'))
          "FAILED" | Set-Content -LiteralPath "$log_file.result"
          return
        }

        if (Is-KeyEncrypted $resolvedKey) {
          Append-Log ("[{0}] [ERROR] SSH private key appears ENCRYPTED (passphrase-protected). Use an unencrypted key or preload ssh-agent." -f (Get-Date))
          "FAILED" | Set-Content -LiteralPath "$log_file.result"
          return
        }

        $storagePrintable = ($STORAGE_ARGS | ForEach-Object { $_ }) -join ' '
        Append-Log ("[{0}] [DEBUG] gh bbs2gh migrate-repo --bbs-server-url {1} --bbs-project {2} --bbs-repo {3} --github-org {4} --github-repo {5} {6} --ssh-user {7} --ssh-private-key {8} --target-api-url {9} --target-repo-visibility {10}" -f (Get-Date), $BBS_BASE_URL, $projectKey, $repoSlug, $github_org, $github_repo, $storagePrintable, $SSH_USER, $resolvedKey, $TARGET_API_URL, $gh_repo_visibility)

        # Export BBS credentials for extension
        $env:BBS_USERNAME = $env:BBS_USERNAME
        $env:BBS_PASSWORD = $env:BBS_PASSWORD

        $cmdArgs = @('bbs2gh','migrate-repo',
          '--bbs-server-url', $BBS_BASE_URL,
          '--bbs-project', $projectKey,
          '--bbs-repo', $repoSlug,
          '--github-org', $github_org,
          '--github-repo', $github_repo
        ) + $STORAGE_ARGS + @(
          '--ssh-user', $SSH_USER,
          '--ssh-private-key', $resolvedKey,
          '--target-api-url', $TARGET_API_URL,
          '--target-repo-visibility', $gh_repo_visibility
        )

        & gh @cmdArgs 2>&1 | Out-File -FilePath $log_file -Append -Encoding utf8

        $logText = Get-Content -LiteralPath $log_file -Raw -ErrorAction SilentlyContinue
        if ($logText -match 'No operation will be performed') {
          Append-Log ("[{0}] [FAILED] No operation performed - repository may already exist or migration was skipped" -f (Get-Date))
          "FAILED" | Set-Content -LiteralPath "$log_file.result"
          return
        }

        if ($logText -notmatch 'State: SUCCEEDED') {
          Append-Log ("[{0}] [FAILED] Migration did not reach SUCCEEDED state" -f (Get-Date))
          "FAILED" | Set-Content -LiteralPath "$log_file.result"
          return
        }

        Append-Log ("[{0}] [SUCCESS] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $projectKey, $repoSlug, $github_org, $github_repo)
        "SUCCESS" | Set-Content -LiteralPath "$log_file.result"
      } catch {
        Add-Content -LiteralPath $log_file -Value $_.Exception.Message
        "FAILED" | Set-Content -LiteralPath "$log_file.result"
      }
    } -ArgumentList $projectKey,$projectName,$repoSlug,$github_org,$github_repo,$gh_repo_visibility,$log_file,$BBS_BASE_URL,$env:SSH_USER,$env:SSH_PRIVATE_KEY_PATH,$env:SSH_PRIVATE_KEY,$TARGET_API_URL,$STORAGE_ARGS

    $JOB_JOBS[$job.Id] = $repo_info
    $JOB_LOGS[$job.Id] = $log_file
    $JOB_REPOKEY[$job.Id] = "$github_org,$github_repo"
    $JOB_LASTLEN[$job.Id] = 0

    Show-Status-Bar
  }

  # Stream new log content from each job (delta only)
  foreach ($jid in @($JOB_JOBS.Keys)) {
    $log = $JOB_LOGS[$jid]
    $last = [long]$JOB_LASTLEN[$jid]
    if (Test-Path -LiteralPath $log) {
      $delta, $newLen = Read-FileDelta $log $last
      if (-not [string]::IsNullOrEmpty($delta)) {
        Write-Host ""  # break the status line once
        foreach ($l in ($delta -split "`n")) {
          if (-not [string]::IsNullOrWhiteSpace($l)) { Write-Host $l }
        }
        $JOB_LASTLEN[$jid] = $newLen
        Show-Status-Bar
      } else {
        $JOB_LASTLEN[$jid] = $newLen
      }
    }
  }

  # Check completed jobs
  foreach ($jid in @($JOB_JOBS.Keys)) {
    $job = Get-Job -Id $jid -ErrorAction SilentlyContinue
    if ($null -eq $job) { continue }
    if ($job.State -ne 'Running') {
      $repo_info = $JOB_JOBS[$jid]
      $log_file = $JOB_LOGS[$jid]
      $repoKey = $JOB_REPOKEY[$jid]
      $tok = $repoKey.Split(',',2)
      $target_org = $tok[0]
      $target_repo = $tok[1]

      $result = 'FAILED'
      if (Test-Path -LiteralPath "$log_file.result") {
        $result = (Get-Content -LiteralPath "$log_file.result" -TotalCount 1)
        Remove-Item -Force -LiteralPath "$log_file.result" -ErrorAction SilentlyContinue
      }

      if ($result -eq 'SUCCESS') {
        $MIGRATED.Add($repo_info)
        Update-Repo-Status-In-Csv $target_org $target_repo "Success" $log_file
      } else {
        $FAILED.Add($repo_info)
        Update-Repo-Status-In-Csv $target_org $target_repo "Failure" $log_file
      }

      $JOB_JOBS.Remove($jid)
      $JOB_LOGS.Remove($jid)
      $JOB_REPOKEY.Remove($jid)
      $JOB_LASTLEN.Remove($jid)

      try { Remove-Job -Id $jid -Force -ErrorAction SilentlyContinue } catch { }

      Show-Status-Bar
    }
  }

  Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host ""
Write-Host "[INFO] All migrations completed."
$total_repos = (Get-Content -LiteralPath $CSV_PATH).Count - 1
Write-Host "[SUMMARY] Total: $total_repos / Migrated: $($MIGRATED.Count) / Failed: $($FAILED.Count)"
Write-Host "[INFO] Wrote migration results with Migration_Status column: $OUTPUT_CSV_PATH"

# Clean up per-repo log files - their content was already streamed to the Actions run log
Get-ChildItem -Path . -Filter 'migration-*.txt' | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host "[INFO] Cleaned up per-repo log files."

if ($FAILED.Count -eq 0) {
  Write-Host "::notice::All $total_repos repositories migrated successfully"
  exit 0
} elseif ($MIGRATED.Count -eq 0) {
  Write-Host "::error::All $total_repos repositories failed to migrate"
  foreach ($item in $FAILED) {
    $p = $item.Split(',',6)
    Write-Host "::error::Failed: $($p[3])/$($p[4]) ($($p[0])/$($p[2]))"
  }
  exit 1
} else {
  Write-Host "::warning::Migration completed with partial success: $($MIGRATED.Count) succeeded, $($FAILED.Count) failed out of $total_repos total"
  foreach ($item in $FAILED) {
    $p = $item.Split(',',6)
    Write-Host "::warning::Failed: $($p[3])/$($p[4]) ($($p[0])/$($p[2]))"
  }
  exit 0
}
