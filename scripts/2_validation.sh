#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Bitbucket ↔ GitHub Migration Validation (CLI)
# - Validates branch sets and HEAD commit SHAs between Bitbucket S/DC and GitHub
# - Extracts SHAs from branch-list API responses — no per-branch commit pagination needed
# - Writes: validation-log-<date>.txt, validation-summary.csv, validation-summary.md
#
# CSV columns required: project-key, project-name, repo, github_org, github_repo
#
# Env:
#   BBS_BASE_URL   : e.g., http://bitbucket.example.com:7990 (or pass -b)
#   Auth: BBS_PAT OR (BBS_AUTH_TYPE=Basic with BBS_USERNAME + BBS_PASSWORD)
#   gh auth status (GH_TOKEN/GH_PAT or interactive)
#
# Usage:
#   ./2_validation.sh [-c repos.csv] [-b http://host:7990]
# ------------------------------------------------------------------------------

set -euo pipefail

CSV_PATH="./repos.csv"
BBS_BASE_URL="${BBS_BASE_URL:-}"

while getopts ":c:b:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    b) BBS_BASE_URL="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-b BBS_BASE_URL]" >&2; exit 1 ;;
  esac
done

COMMIT_CHECK="${COMMIT_CHECK:-true}"
FAIL_ON_VALIDATION_FAILURES="${FAIL_ON_VALIDATION_FAILURES:-false}"

LOG_FILE="validation-log-$(date +'%Y%m%d-%H%M%S').txt"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_NC='\033[0m'
log_info()    { echo -e "${C_BLUE}[INFO]${C_NC} $1"      | tee -a "$LOG_FILE"; }
log_success() { echo -e "${C_GREEN}[OK]${C_NC} $1"       | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_NC} $1"      | tee -a "$LOG_FILE" >&2; }

ensure_tooling() {
  if ! command -v gh >/dev/null 2>&1; then
    log_error "GitHub CLI (gh) is not installed. See https://cli.github.com/"
    exit 1
  fi
  log_info "gh version: $(gh --version | head -n 1)"
}

ensure_auth() {
  if [[ -n "${GH_PAT:-}" && -z "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN="$GH_PAT"
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT)."
    exit 1
  fi
}

ensure_tooling
ensure_auth

if [[ -z "$BBS_BASE_URL" ]]; then
  log_error "BBS_BASE_URL is required (pass -b or export BBS_BASE_URL)."
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

# ---- Bitbucket auth header ----------------------------------------------------
auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    printf "Authorization: Bearer %s" "$BBS_PAT"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    local b64; b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    printf "Authorization: Basic %s" "$b64"
  else
    echo "[ERROR] Provide Bitbucket credentials via BBS_PAT (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

DISABLE_SSL_VERIFY=false
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) DISABLE_SSL_VERIFY=true ;;
esac
CURL_OPTS=(-sS)
$DISABLE_SSL_VERIFY && CURL_OPTS+=(--insecure)

curl_json() { curl "${CURL_OPTS[@]}" -H "$(auth_header)" "$1"; }

check_tls() {
  if $DISABLE_SSL_VERIFY; then
    log_warning "TLS certificate verification is DISABLED (BBS_DISABLE_SSL_VERIFY set). Proceeding without cert validation."
    return 0
  fi
  local probe rc
  probe="$(curl -sS -o /dev/null "${BASE_URL}/rest/api/1.0/projects?limit=1" 2>&1)"; rc=$?
  case "$rc" in
    35|51|58|59|60|66|77|83|91)
      log_error "TLS/SSL certificate validation failed for ${BASE_URL} (curl exit ${rc}): ${probe}"
      log_error "If this host uses a self-signed or internal CA certificate intentionally, re-run with BBS_DISABLE_SSL_VERIFY=Y."
      exit 1
      ;;
  esac
  return 0
}
check_tls

# ---- Bitbucket helpers --------------------------------------------------------
# Returns tab-separated lines: branchName<TAB>sha  (paginated, limit 500 per page)
get_bbs_branches_with_shas() {
  local projectKey="$1" repoSlug="$2" start=0
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/branches?limit=500&start=${start}")"
    echo "$resp" | jq -r '.values[]? | [.displayId, .latestCommit] | @tsv'
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage')"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
}

# ---- GitHub helpers -----------------------------------------------------------
gh_repo_exists() { gh api -X GET "/repos/$1/$2" >/dev/null 2>&1; }

# Returns tab-separated lines: branchName<TAB>sha  (paginated, 100 per page)
get_gh_branches_with_shas() {
  local org="$1" repo="$2"
  gh api "/repos/${org}/${repo}/branches" --paginate | jq -r '.[] | [.name, .commit.sha] | @tsv'
}

urlencode_uri() { jq -rn --arg s "$1" '$s|@uri'; }

get_bbs_commit_count() {
  local projectKey="$1" repoSlug="$2" branch="$3"
  local total=0 start=0 limit=1000 encBranch; encBranch="$(urlencode_uri "$branch")"
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/commits?until=${encBranch}&limit=${limit}&start=${start}")"
    local cnt; cnt="$(echo "$resp" | jq '.values | length' 2>/dev/null || echo 0)"
    [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
    total=$(( total + cnt ))
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage' 2>/dev/null)"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty' 2>/dev/null)"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  echo "$total"
}

get_gh_commit_count() {
  local org="$1" repo="$2" branch="$3"
  local total=0 page=1 per=100 encBranch; encBranch="$(urlencode_uri "$branch")"
  while :; do
    local count; count="$(gh api "/repos/${org}/${repo}/commits?sha=${encBranch}&page=${page}&per_page=${per}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    total=$(( total + count ))
    (( count < per )) && break
    page=$(( page + 1 ))
  done
  echo "$total"
}

status_marker() { # $1: ok|true|false
  [[ "$1" == "true" ]] && echo "✅ Matching" || echo "❌ Not Matching"
}

# ---- Banners ------------------------------------------------------------------
echo "=================================================="
echo " Bitbucket ↔ GitHub Migration Validation (CLI) "
echo "=================================================="
echo "Using CSV: ${CSV_PATH}"
echo "Using Bitbucket Base URL: ${BASE_URL}"

# ---- CSV helpers (RFC 4180 compliant) -----------------------------------------
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

# ---- CSV checks ---------------------------------------------------------------
[[ -f "$CSV_PATH" ]] || { echo "[ERROR] CSV file not found: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }
[[ -s "$CSV_PATH" ]] || { echo "[ERROR] CSV has no rows: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }

# Validate header and build column index
REQUIRED_COLUMNS=(project-key project-name repo github_org github_repo)
read -r HEADER_LINE < "$CSV_PATH"
mapfile -t HEADER_FIELDS < <(parse_csv_line "${HEADER_LINE}")
declare -A COLIDX=()
for idx in "${!HEADER_FIELDS[@]}"; do
  name="${HEADER_FIELDS[$idx]}"
  name="${name%\"}"; name="${name#\"}"
  COLIDX["$name"]="$idx"
done
missing_cols=()
for col in "${REQUIRED_COLUMNS[@]}"; do
  [[ -n "${COLIDX[$col]:-}" ]] || missing_cols+=("$col")
done
if [[ ${#missing_cols[@]} -gt 0 ]]; then
  echo "Missing required column(s): ${missing_cols[*]}" >&2; exit 1
fi

summary_csv="validation-summary-$(date +'%Y%m%d-%H%M%S').csv"
echo "github_org,github_repo,bbs_project_key,bbs_repo,branch_count_bbs,branch_count_gh,branch_count_match,commits_match_all,shas_match_all,gh_notes" > "$summary_csv"

echo "==> Starting validation..."

# ---- Parallel validation -------------------------------------------------------
# Each repo is validated in a background subshell. Results are written to
# per-repo temp files then merged in order into the summary CSV.
validate_repo() {
  local bbsProjectKey="$1" bbsRepoSlug="$2" ghOrg="$3" ghRepo="$4"
  local out_file="$5"  # temp file for this repo's CSV row + log lines

  {
    echo "============================================================"
    echo "ℹ️  [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validating: ${bbsProjectKey}/${bbsRepoSlug} -> ${ghOrg}/${ghRepo}"
    echo "============================================================"

    # A — Check GitHub repo exists
    local ghExists="yes"
    if ! gh_repo_exists "$ghOrg" "$ghRepo"; then
      echo "[$(date)] GitHub repo not found or inaccessible: ${ghOrg}/${ghRepo}. Treating GH side as empty."
      ghExists="no"
    fi

    # B — Fetch branch names + HEAD SHAs from both sides using the branch-list responses
    #     (no separate per-branch commit API calls needed)
    declare -A bbsSHAmap=() ghSHAmap=()
    while IFS=$'\t' read -r name sha; do
      [[ -n "$name" ]] && bbsSHAmap["$name"]="$sha"
    done < <(get_bbs_branches_with_shas "$bbsProjectKey" "$bbsRepoSlug")

    if [[ "$ghExists" == "yes" ]]; then
      while IFS=$'\t' read -r name sha; do
        [[ -n "$name" ]] && ghSHAmap["$name"]="$sha"
      done < <(get_gh_branches_with_shas "$ghOrg" "$ghRepo")
    fi

    # C — Branch count comparison
    local bbsBranchCount="${#bbsSHAmap[@]}" ghBranchCount="${#ghSHAmap[@]}"
    local branchCountOk="false"; [[ "$bbsBranchCount" -eq "$ghBranchCount" ]] && branchCountOk="true"
    if [[ "$branchCountOk" == "true" ]]; then
      echo "✅ Branch Count MATCHED | BBS=${bbsBranchCount} GitHub=${ghBranchCount}"
    else
      echo "❌ Branch Count MISMATCH | BBS=${bbsBranchCount} GitHub=${ghBranchCount}"
    fi

    local missingInGH missingInBBS
    missingInGH=$(comm -23 \
      <(printf "%s\n" "${!bbsSHAmap[@]}" | sort) \
      <(printf "%s\n" "${!ghSHAmap[@]}"  | sort) || true)
    missingInBBS=$(comm -13 \
      <(printf "%s\n" "${!bbsSHAmap[@]}" | sort) \
      <(printf "%s\n" "${!ghSHAmap[@]}"  | sort) || true)
    if [[ -n "$missingInGH" ]]; then
      echo "❌ Branches missing in GitHub: $(echo "$missingInGH" | tr '\n' ' ' | sed 's/ *$//')"
    else
      echo "✅ No branches missing in GitHub"
    fi
    if [[ -n "$missingInBBS" ]]; then
      echo "❌ Extra branches in GitHub (not in Bitbucket): $(echo "$missingInBBS" | tr '\n' ' ' | sed 's/ *$//')"
    else
      echo "✅ No extra branches found"
    fi

    # D — Commit count + SHA comparison
    local commitsMatchAll="false" shasMatchAll="false"
    if [[ "${COMMIT_CHECK}" != "true" ]]; then
      commitsMatchAll="true"; shasMatchAll="true"
      echo "ℹ️ COMMIT_CHECK=false - skipping per-branch commit/SHA comparison"
    elif [[ "$ghExists" == "yes" && "${#bbsSHAmap[@]}" -gt 0 && "${#ghSHAmap[@]}" -gt 0 ]]; then
      local ghDefault bbsDefault validation_branch=""
      ghDefault="$(gh api "/repos/${ghOrg}/${ghRepo}" --jq '.default_branch' 2>/dev/null || true)"
      bbsDefault="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${bbsProjectKey}/repos/${bbsRepoSlug}/branches/default" 2>/dev/null | jq -r '.displayId // empty' 2>/dev/null || true)"
      if [[ -n "$ghDefault" && ( -n "${ghSHAmap[$ghDefault]:-}" || -n "${bbsSHAmap[$ghDefault]:-}" ) ]]; then
        validation_branch="$ghDefault"
      elif [[ -n "$bbsDefault" && ( -n "${ghSHAmap[$bbsDefault]:-}" || -n "${bbsSHAmap[$bbsDefault]:-}" ) ]]; then
        validation_branch="$bbsDefault"
      fi

      local -a branches_to_check=()
      local name
      [[ -n "$validation_branch" ]] && branches_to_check+=("$validation_branch")
      for name in "${!ghSHAmap[@]}"; do
        (( ${#branches_to_check[@]} >= 10 )) && break
        [[ "$name" == "$validation_branch" ]] && continue
        branches_to_check+=("$name")
      done
      if (( bbsBranchCount > 10 || ghBranchCount > 10 )); then
        echo "ℹ️ Commit validation running only for first ${#branches_to_check[@]} branches (default branch first, max 10)"
      elif (( ${#branches_to_check[@]} > 0 )); then
        echo "ℹ️ Commit validation covering ${#branches_to_check[@]} branch(es) (default branch first, max 10)"
      else
        echo "ℹ️ Could not determine any branch for commit/SHA check"
      fi

      if (( ${#branches_to_check[@]} > 0 )); then
        commitsMatchAll="true"; shasMatchAll="true"
        local br
        for br in "${branches_to_check[@]}"; do
          [[ -z "$br" ]] && continue
          if [[ -z "${ghSHAmap[$br]:-}" ]]; then
            echo "Branch '$br': missing in GitHub branches list ❌ Not Matching"
            commitsMatchAll="false"; shasMatchAll="false"; continue
          fi
          if [[ -z "${bbsSHAmap[$br]:-}" ]]; then
            echo "Branch '$br': missing in Bitbucket branches list ❌ Not Matching"
            commitsMatchAll="false"; shasMatchAll="false"; continue
          fi
          local bbsCount ghCount countOk
          bbsCount="$(get_bbs_commit_count "$bbsProjectKey" "$bbsRepoSlug" "$br")"
          ghCount="$(get_gh_commit_count "$ghOrg" "$ghRepo" "$br")"
          countOk="false"; [[ "$bbsCount" == "$ghCount" ]] && countOk="true"
          [[ "$countOk" == "false" ]] && commitsMatchAll="false"
          echo "Branch '$br': BBS Commits=${bbsCount} | GitHub Commits=${ghCount} | $(status_marker "$countOk")"

          local bbsSha="${bbsSHAmap[$br]:-}" ghSha="${ghSHAmap[$br]:-}"
          local shaOk="false"
          [[ -n "$ghSha" && "$ghSha" == "$bbsSha" ]] && shaOk="true"
          [[ "$shaOk" == "false" ]] && shasMatchAll="false"
          echo "Branch '$br': BBS SHA=${bbsSha} | GitHub SHA=${ghSha} | $(status_marker "$shaOk")"
        done
      fi
    fi

    local gh_notes=""
    if [[ "$ghExists" == "no" ]]; then
      gh_notes="repo not found or no access"
    elif [[ "$ghBranchCount" -eq 0 && "$bbsBranchCount" -gt 0 ]]; then
      gh_notes="no branches on GH"
    fi

    echo "✅ Validation completed for: ${ghOrg}/${ghRepo}"
    # Write the CSV row as a sentinel line prefixed with CSV: so we can extract it
    printf 'CSV:%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ghOrg" "$ghRepo" "$bbsProjectKey" "$bbsRepoSlug" \
      "$bbsBranchCount" "$ghBranchCount" "$branchCountOk" \
      "$commitsMatchAll" "$shasMatchAll" "$gh_notes"
  } > "$out_file" 2>&1
}

# Launch all repos in parallel
declare -a PIDS=() OUTFILES=()
while IFS= read -r line; do
  mapfile -t F < <(parse_csv_line "$line")
  bbsProjectKey="$(strip_quotes "${F[${COLIDX[project-key]}]}")"
  bbsRepoSlug="$(strip_quotes "${F[${COLIDX[repo]}]}")"
  ghOrg="$(strip_quotes "${F[${COLIDX[github_org]}]}")"
  ghRepo="$(strip_quotes "${F[${COLIDX[github_repo]}]}")"
  tmp_out="$(mktemp)"
  OUTFILES+=("$tmp_out")
  validate_repo "$bbsProjectKey" "$bbsRepoSlug" "$ghOrg" "$ghRepo" "$tmp_out" &
  PIDS+=("$!")
done < <(tail -n +2 "$CSV_PATH")

# Collect results in submission order
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}" || true
  out="${OUTFILES[$i]}"
  if [[ -f "$out" ]]; then
    # Emit log lines (everything except the CSV: sentinel)
    grep -v '^CSV:' "$out" | tee -a "$LOG_FILE"
    # Append the CSV row (strip the CSV: prefix)
    grep '^CSV:' "$out" | sed 's/^CSV://' >> "$summary_csv"
    rm -f "$out"
  fi
done

echo "[$(date)] All validations from CSV completed" | tee -a "$LOG_FILE"

# Markdown table (name matches the summary CSV for easy correlation)
md="${summary_csv%.csv}.md"
{
  echo "| GitHub Repo | BBS Repo | Branches (BBS/GH) | Count ✓ | Commits ✓ | SHAs ✓ | Notes |"
  echo "|-|-|-|-|-|-|-|"
  # Read rows directly from the CSV file (no pipe → no subshell surprises)
  while IFS=',' read -r ghOrg ghRepo bbsKey bbsRepo bcB ghC bcOk commitsOk shaOk notes; do
    # Skip empty lines
    [[ -z "$ghOrg" && -z "$ghRepo" ]] && continue
    printf "| %s/%s | %s/%s | %s/%s | %s | %s | %s | %s |\n" \
      "$ghOrg" "$ghRepo" \
      "$bbsKey" "$bbsRepo" \
      "$bcB" "$ghC" \
      "$( [[ "$bcOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$commitsOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$shaOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "${notes}"
  done < <(tail -n +2 "$summary_csv")
} > "$md"
echo "=======================Summary==========================="
cat ${md}
echo "======================Completed==========================="

total_validated=$(awk -F',' 'NR>1{c++} END{print c+0}' "$summary_csv")
passed=$(awk -F',' 'NR>1 && $7=="true" && $8=="true" && $9=="true"{c++} END{print c+0}' "$summary_csv")
failed=$(( total_validated - passed ))

if (( total_validated == 0 )); then
  echo "::notice::No repositories were validated."
elif (( failed == 0 )); then
  echo "::notice::All ${total_validated} repositories validated successfully (branches, commits and SHAs match)"
elif (( passed == 0 )); then
  echo "::error::All ${total_validated} repositories have validation discrepancies"
  awk -F',' 'NR>1 && !($7=="true" && $8=="true" && $9=="true"){printf "::error::Validation discrepancy: %s/%s (%s)\n",$1,$2,$10}' "$summary_csv"
else
  echo "::warning::Validation completed with discrepancies: ${passed} matched, ${failed} with issues (of ${total_validated})"
  awk -F',' 'NR>1 && !($7=="true" && $8=="true" && $9=="true"){printf "::warning::Validation discrepancy: %s/%s (%s)\n",$1,$2,$10}' "$summary_csv"
fi

if [[ "$FAIL_ON_VALIDATION_FAILURES" == "true" && "$failed" -gt 0 ]]; then
  echo "::error::FAIL_ON_VALIDATION_FAILURES=true and ${failed} repository(ies) failed validation."
  exit 1
fi
exit 0
