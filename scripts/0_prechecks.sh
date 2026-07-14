#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./0_prechecks.sh [-c repos.csv] [-o output.csv]
#
# CSV columns required: project-key, project-name, repo, github_org, github_repo, gh_repo_visibility
# Env: BBS_BASE_URL + (BBS_PAT or BBS_USERNAME+BBS_PASSWORD with BBS_AUTH_TYPE=Basic)

CSV_PATH="repos.csv"
OUTPUT_PATH=""

while getopts ":c:o:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    o) OUTPUT_PATH="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-o output.csv]" >&2; exit 1 ;;
  esac
done

if [[ -z "${BBS_BASE_URL:-}" ]]; then
  echo "[ERROR] BBS_BASE_URL env var is required." >&2
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

LOG_FILE="bbs-prechecks-$(date +'%Y%m%d-%H%M%S').log"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_NC='\033[0m'
log_info()    { echo -e "${C_BLUE}[INFO]${C_NC} $1"      | tee -a "$LOG_FILE"; }
log_success() { echo -e "${C_GREEN}[OK]${C_NC} $1"       | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_NC} $1"      | tee -a "$LOG_FILE" >&2; }

auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    echo "Authorization: Bearer ${BBS_PAT}"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    echo "Authorization: Basic ${b64}"
  else
    echo "[ERROR] Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

curl_json() {
  curl -sS -H "$(auth_header)" "$1"
}

# Preflight auth test
preflight_status="$(curl -s -o /dev/null -w '%{http_code}' -H "$(auth_header)" "${BASE_URL}/rest/api/1.0/projects?limit=1")"
if [[ "$preflight_status" -lt 200 || "$preflight_status" -ge 300 ]]; then
  case "$preflight_status" in
    401|403) log_error "Bitbucket auth failed (HTTP $preflight_status). Verify BBS_PAT / credentials and permissions." ;;
    404)     log_error "Bitbucket endpoint not found (HTTP 404). Verify BBS_BASE_URL: ${BASE_URL}" ;;
    000)     log_error "Network/DNS/TLS issue reaching Bitbucket (HTTP 000). Verify connectivity to ${BASE_URL}." ;;
    *)       log_error "Bitbucket preflight failed (HTTP $preflight_status) for ${BASE_URL}." ;;
  esac
  exit 1
fi

timestamp="$(date +'%Y%m%d-%H%M%S')"
OUTPUT_CSV="${OUTPUT_PATH:-bbs_pr_validation_output-${timestamp}.csv}"

# Ensure temp files are cleaned up on any exit
rows_tmp=""
ready_tmp=""
results_tmp=""
trap 'rm -f "${rows_tmp:-}" "${ready_tmp:-}" "${results_tmp:-}"' EXIT

get_open_pr_count() {
  local projectKey="$1" repoSlug="$2"
  # Use limit=1 and read the top-level .size — a single call gives the full count
  local resp
  resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/pull-requests?state=OPEN&limit=1")" || { echo 0; return; }
  echo "$resp" | jq '.size // 0'
}

echo ""
echo " Bitbucket Readiness Check (Open PRs only) "
echo "============================================"

# Validate CSV input — fail fast if missing, empty, or wrong header
if [[ ! -f "$CSV_PATH" ]]; then
  echo "[ERROR] CSV file not found: ${CSV_PATH}" >&2
  echo "[INFO]  Provide a CSV via -c or ensure repos.csv exists in the working directory." >&2
  exit 1
fi
if [[ ! -s "$CSV_PATH" ]]; then
  echo "[ERROR] CSV file is empty: ${CSV_PATH}" >&2
  exit 1
fi
header="$(head -n1 "$CSV_PATH")"
for required_col in "project-key" "project-name" "repo"; do
  if ! echo "$header" | grep -q "$required_col"; then
    echo "[ERROR] CSV is missing required column '${required_col}': ${CSV_PATH}" >&2
    exit 1
  fi
done

rows_tmp="$(mktemp)"
# Strip stray quotes then copy data rows into temp file
sed 's/"//g' "$CSV_PATH" | tail -n +2 > "$rows_tmp"

# Process
ready_tmp="$(mktemp)"
results_tmp="$(mktemp)"
echo "project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate" > "$results_tmp"

total_open_prs=0
while IFS=',' read -r projKey projName repoSlug isArchived _rest; do
  openPrs="$(get_open_pr_count "$projKey" "$repoSlug")"
  total_open_prs=$(( total_open_prs + openPrs ))
  warns=""
  if (( openPrs > 0 )); then
    warns="OPEN_PRS"
    echo "[WARNING] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
  else
    echo "[OK] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
    echo "${projKey}/${repoSlug}" >> "$ready_tmp"
  fi
  ready=false; [[ -z "$warns" ]] && ready=true
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "$openPrs" "$warns" "$ready" >> "$results_tmp"
done < "$rows_tmp"

mv "$results_tmp" "$OUTPUT_CSV"
echo "[INFO] Wrote precheck CSV: $OUTPUT_CSV"

if [[ -s "$ready_tmp" ]]; then
  echo ""
  echo "[READY] Repos ready to migrate (no open PRs)✅:"
  sed 's/^/ - /' "$ready_tmp"
else
  echo ""
  echo "[READY] No repos are currently without open PRs."
fi

total_repos="$(($(wc -l < "$rows_tmp")))"
ready_repos=0
[[ -f "$ready_tmp" ]] && ready_repos="$(wc -l < "$ready_tmp" | tr -d ' ')"
repos_with_open_prs=$(( total_repos - ready_repos ))

echo ""
echo "[SUMMARY] Total repos: $total_repos"
echo "Open PRs total: $total_open_prs"
echo "======================Completed============================="

if (( total_repos == 0 )); then
  echo "::notice::No repositories found to check."
elif (( repos_with_open_prs == 0 )); then
  echo "::notice::All ${total_repos} repositories are ready to migrate (no open PRs)"
else
  echo "::warning::${repos_with_open_prs} of ${total_repos} repositories have open PRs"
  awk -F',' 'NR>1 && $7=="false"{printf "::warning::Open PRs: %s/%s (%s open)\n",$1,$3,$5}' "$OUTPUT_CSV"
fi
