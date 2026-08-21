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

detect_bbs_install() {
  local p launcher bbsHome line detected
  if [[ -n "${BITBUCKET_HOME:-}" && -d "${BITBUCKET_HOME}" ]]; then
    export BITBUCKET_HOME
    log_success "Bitbucket Server home found via BITBUCKET_HOME: ${BITBUCKET_HOME}"
    return 0
  fi
  line="$(ps -ef 2>/dev/null | grep -i '[b]itbucket' | grep -i 'home' | head -n1 || true)"
  if [[ -n "$line" ]]; then
    detected="$(printf '%s\n' "$line" | grep -oE 'bitbucket[._]home=[^[:space:]]+' | head -n1 | sed -E 's/^.*home=//' || true)"
    [[ -z "$detected" ]] && detected="$(printf '%s\n' "$line" | grep -oE '/[^[:space:]]+/bitbucket[^[:space:]]*' | head -n1 || true)"
    if [[ -n "$detected" ]]; then
      export BITBUCKET_HOME="$detected"
      log_success "Bitbucket Server home auto-detected from running process: ${detected}"
      return 0
    fi
  fi
  for p in /var/atlassian/application-data/bitbucket /opt/atlassian/bitbucket; do
    if [[ -d "$p" ]]; then
      export BITBUCKET_HOME="$p"
      log_success "Bitbucket Server found at default location: ${p}"
      return 0
    fi
  done
  launcher="$(command -v start-bitbucket.sh 2>/dev/null || command -v bitbucket 2>/dev/null || true)"
  if [[ -n "$launcher" ]]; then
    bbsHome="$(cd "$(dirname "$launcher")/.." 2>/dev/null && pwd || dirname "$launcher")"
    export BITBUCKET_HOME="$bbsHome"
    log_success "Bitbucket Server launcher found on PATH: ${launcher} (home: ${bbsHome})"
    return 0
  fi
  log_warning "Bitbucket Server install not found locally (checked BITBUCKET_HOME, running process, default dirs, PATH). Continuing — remote/SSH migration does not require a local install."
  return 0
}
detect_bbs_install || true

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

DISABLE_SSL_VERIFY=false
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) DISABLE_SSL_VERIFY=true ;;
esac
CURL_OPTS=(-sS)
$DISABLE_SSL_VERIFY && CURL_OPTS+=(--insecure)

curl_json() {
  curl "${CURL_OPTS[@]}" -H "$(auth_header)" "$1"
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

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

# Preflight auth test
preflight_status="$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -H "$(auth_header)" "${BASE_URL}/rest/api/1.0/projects?limit=1")"
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

declare -A SLUG_CACHE=()

WARN_SLUG() { log_warning "$*" >&2; }

resolve_repo_slug() {
  local projectKey="$1" value="$2"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  projectKey="${projectKey#"${projectKey%%[![:space:]]*}"}"
  projectKey="${projectKey%"${projectKey##*[![:space:]]}"}"
  local key="${projectKey}/${value}"
  if [[ -n "${SLUG_CACHE[$key]:-}" ]]; then
    printf '%s' "${SLUG_CACHE[$key]}"
    return 0
  fi

  local encP encV status probe_body
  probe_body="$(mktemp)"
  encP="$(urlencode "$projectKey")"
  encV="$(urlencode "$value")"

  status="$(curl "${CURL_OPTS[@]}" -o "$probe_body" -w '%{http_code}' -H "$(auth_header)" \
    "${BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encV}" 2>/dev/null || echo 000)"
  if [[ "$status" == "200" ]]; then
    local realSlug; realSlug="$(jq -r '.slug // empty' < "$probe_body" 2>/dev/null || true)"
    rm -f "$probe_body"
    if [[ -n "$realSlug" ]]; then
      if [[ "$realSlug" != "$value" ]]; then
        WARN_SLUG "'${value}' is a repository NAME, not a slug. Resolved to slug '${realSlug}' for ${projectKey}."
      fi
      SLUG_CACHE[$key]="$realSlug"
      printf '%s' "$realSlug"
      return 0
    fi
  fi
  rm -f "$probe_body"

  local start=0 resp found=""
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${encP}/repos?limit=100&start=${start}" 2>/dev/null || true)"
    [[ -z "$resp" ]] && break
    found="$(printf '%s' "$resp" | jq -r --arg n "$value" '.values[]? | select(((.name // "") | ascii_downcase) == ($n | ascii_downcase)) | .slug' 2>/dev/null | head -n1 || true)"
    [[ -n "$found" ]] && break
    [[ "$(printf '%s' "$resp" | jq -r '.isLastPage' 2>/dev/null)" == "true" ]] && break
    local nextStart; nextStart="$(printf '%s' "$resp" | jq -r '.nextPageStart // empty' 2>/dev/null)"
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done

  if [[ -z "$found" ]]; then
    local resp2
    resp2="$(curl "${CURL_OPTS[@]}" -H "$(auth_header)" "${BASE_URL}/rest/api/1.0/repos?projectkey=${encP}&name=${encV}&limit=100" 2>/dev/null || true)"
    if [[ -n "$resp2" ]]; then
      found="$(printf '%s' "$resp2" | jq -r --arg n "$value" --arg pk "$projectKey" '.values[]? | select((((.project.key // "")|ascii_downcase)==($pk|ascii_downcase)) and (((.name // "")|ascii_downcase)==($n|ascii_downcase))) | .slug' 2>/dev/null | head -n1 || true)"
    fi
  fi

  if [[ -n "$found" ]]; then
    log_warning "'${value}' is a repository NAME, not a slug. Resolved to slug '${found}' for ${projectKey}." >&2
    SLUG_CACHE[$key]="$found"
    printf '%s' "$found"
    return 0
  fi

  SLUG_CACHE[$key]="$value"
  printf '%s' "$value"
  return 0
}

get_open_pr_count() {
  local projectKey="$1" repoSlug="$2"
  # Use limit=1 and read the top-level .size — a single call gives the full count
  local resp encProjectKey encRepoSlug
  encProjectKey="$(urlencode "$projectKey")"
  encRepoSlug="$(urlencode "$repoSlug")"
  resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${encProjectKey}/repos/${encRepoSlug}/pull-requests?state=OPEN&limit=1")" || { echo "ERROR"; return; }
  echo "$resp" | jq -r '.size // 0' 2>/dev/null || echo "ERROR"
}

LARGE_FILE_REPORT="large_files_report-${timestamp}.csv"
LARGE_FILE_REPOS_CSV="large_file_repos-${timestamp}.csv"
LARGE_FILE_THRESHOLD_MB_EFFECTIVE="${LARGE_FILE_THRESHOLD_MB:-400}"
declare -A LARGE_FILE_REPO_SET=()
declare -A LARGE_FILE_REPO_COUNT=()
declare -A LARGE_FILE_REPO_MAXMB=()
LARGE_FILE_REPO_TOTAL=0
scan_large_files() {
  case "${RUN_LARGE_FILE_SCAN:-Y}" in
    [Nn]|[Nn][Oo]|0|[Ff][Aa][Ll][Ss][Ee]) log_info "Large-file scan disabled (RUN_LARGE_FILE_SCAN)."; return 0 ;;
  esac
  local threshold_mb="${LARGE_FILE_THRESHOLD_MB:-400}"
  local threshold_bytes=$(( threshold_mb * 1024 * 1024 ))
  if ! command -v git >/dev/null 2>&1; then
    log_warning "git not found - skipping large-file (>=${threshold_mb}MB) scan."
    return 0
  fi
  echo "project_key,repo_slug,file_path,size_bytes,size_mb" > "$LARGE_FILE_REPORT"
  local git_ssl=(); $DISABLE_SSL_VERIFY && git_ssl=(-c http.sslVerify=false)
  local hdr; hdr="$(auth_header)"
  local tmpdir; tmpdir="$(mktemp -d)"
  local flagged=0 scanned=0
  local projKey projName repoSlug _rest
  while IFS=',' read -r projKey projName repoSlug _rest; do
    [[ -z "${projKey:-}" || -z "${repoSlug:-}" ]] && continue
    scanned=$(( scanned + 1 ))
    repoSlug="$(resolve_repo_slug "$projKey" "$repoSlug")"
    local mir="${tmpdir}/${projKey}_${repoSlug}.git"
    local encProjKey encRepoSlug; encProjKey="$(urlencode "$projKey")"; encRepoSlug="$(urlencode "$repoSlug")"
    if ! git "${git_ssl[@]}" -c http.extraHeader="$hdr" clone --mirror --quiet \
         "${BASE_URL}/scm/${encProjKey}/${encRepoSlug}.git" "$mir" 2>/dev/null; then
      log_warning "Could not clone ${projKey}/${repoSlug} for large-file scan (skipping)."
      continue
    fi
    local bsize bpath mb rkey
    rkey="${projKey}/${repoSlug}"
    while IFS=$'\t' read -r bsize bpath; do
      [[ -z "${bsize:-}" ]] && continue
      mb=$(( bsize / 1024 / 1024 ))
      printf '%s,%s,"%s",%s,%s\n' "$projKey" "$repoSlug" "$bpath" "$bsize" "$mb" >> "$LARGE_FILE_REPORT"
      log_warning "Large file in ${projKey}/${repoSlug}: ${bpath} (${mb} MB)"
      flagged=$(( flagged + 1 ))
      if [[ -z "${LARGE_FILE_REPO_SET[$rkey]:-}" ]]; then
        LARGE_FILE_REPO_SET[$rkey]=1
        LARGE_FILE_REPO_COUNT[$rkey]=0
        LARGE_FILE_REPO_MAXMB[$rkey]=0
        LARGE_FILE_REPO_TOTAL=$(( LARGE_FILE_REPO_TOTAL + 1 ))
      fi
      LARGE_FILE_REPO_COUNT[$rkey]=$(( ${LARGE_FILE_REPO_COUNT[$rkey]} + 1 ))
      if (( mb > ${LARGE_FILE_REPO_MAXMB[$rkey]} )); then
        LARGE_FILE_REPO_MAXMB[$rkey]=$mb
      fi
    done < <(
      git -C "$mir" rev-list --objects --all 2>/dev/null \
        | git -C "$mir" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
        | awk -v t="$threshold_bytes" '$1=="blob" && ($3+0)>=t { size=$3; $1="";$2="";$3=""; sub(/^ +/,""); print size"\t"$0 }'
    )
    rm -rf "$mir"
  done < "$rows_tmp"
  rm -rf "$tmpdir"
  echo "project_key,repo_slug,large_file_count,largest_file_mb" > "$LARGE_FILE_REPOS_CSV"
  if (( LARGE_FILE_REPO_TOTAL > 0 )); then
    local k
    for k in "${!LARGE_FILE_REPO_SET[@]}"; do
      printf '%s,%s,%s,%s\n' "${k%%/*}" "${k#*/}" "${LARGE_FILE_REPO_COUNT[$k]}" "${LARGE_FILE_REPO_MAXMB[$k]}" >> "$LARGE_FILE_REPOS_CSV"
    done
  fi
  if (( flagged > 0 )); then
    log_warning "Large-file scan: ${flagged} file(s) >= ${threshold_mb}MB in ${LARGE_FILE_REPO_TOTAL} repo(s) across ${scanned} scanned. Use Git LFS for these before migrating. Report: ${LARGE_FILE_REPORT}"
    log_warning "Repos with large files will be marked not-ready and skipped by migration. Skip-list: ${LARGE_FILE_REPOS_CSV}"
  else
    log_success "Large-file scan: no files >= ${threshold_mb}MB found across ${scanned} repo(s)."
  fi
  return 0
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

scan_large_files

# Process
ready_tmp="$(mktemp)"
results_tmp="$(mktemp)"
echo "project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate,has_large_files" > "$results_tmp"

total_open_prs=0
pr_check_failed=false
while IFS=',' read -r projKey projName repoSlug isArchived _rest; do
  if [[ -z "${projKey//[[:space:]]/}" || -z "${repoSlug//[[:space:]]/}" ]]; then
    continue
  fi
  repoSlug="$(resolve_repo_slug "$projKey" "$repoSlug")"
  openPrs="$(get_open_pr_count "$projKey" "$repoSlug")"
  if [[ "$openPrs" == "ERROR" || ! "$openPrs" =~ ^[0-9]+$ ]]; then
    pr_check_failed=true
    echo "[ERROR] ${projKey}/${repoSlug}: failed to query open PRs (API error)"
    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "ERROR" "API_FAILURE" "false" "false" >> "$results_tmp"
    continue
  fi
  total_open_prs=$(( total_open_prs + openPrs ))
  warns=""
  if (( openPrs > 0 )); then
    warns="OPEN_PRS"
    echo "[INFO] ${projKey}/${repoSlug} PRs(Open): ${openPrs} - informational only, repo is still migrated"
  else
    echo "[OK] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
  fi
  hasLarge=false
  if [[ -n "${LARGE_FILE_REPO_SET["${projKey}/${repoSlug}"]:-}" ]]; then
    hasLarge=true
    warns="${warns:+${warns}|}LARGE_FILES"
    echo "[WARNING] ${projKey}/${repoSlug} has ${LARGE_FILE_REPO_COUNT["${projKey}/${repoSlug}"]} file(s) >= ${LARGE_FILE_THRESHOLD_MB_EFFECTIVE}MB - excluded from migration (convert to Git LFS, or override with MIGRATE_LARGE_FILE_REPOS=true)"
  fi
  ready=true
  if [[ "$hasLarge" == true ]]; then
    ready=false
  fi
  if [[ "$ready" == true ]]; then
    echo "${projKey}/${repoSlug}" >> "$ready_tmp"
  fi
  printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "$openPrs" "$warns" "$ready" "$hasLarge" >> "$results_tmp"
done < "$rows_tmp"

mv "$results_tmp" "$OUTPUT_CSV"
echo "[INFO] Wrote precheck CSV: $OUTPUT_CSV"

if [[ -s "$ready_tmp" ]]; then
  echo ""
  echo "[READY] Repos ready to migrate (open PRs do not block; large-file repos excluded)✅:"
  sed 's/^/ - /' "$ready_tmp"
else
  echo ""
  echo "[READY] No repos are currently ready to migrate."
fi

if (( LARGE_FILE_REPO_TOTAL > 0 )); then
  echo ""
  echo "[DEFERRED] Repos with file(s) >= ${LARGE_FILE_THRESHOLD_MB_EFFECTIVE}MB - excluded from this migration:"
  for rkey in "${!LARGE_FILE_REPO_SET[@]}"; do
    echo " - ${rkey} (${LARGE_FILE_REPO_COUNT[$rkey]} file(s), largest ${LARGE_FILE_REPO_MAXMB[$rkey]} MB)"
  done
  echo "[DEFERRED] Skip-list CSV: ${LARGE_FILE_REPOS_CSV}"
  echo "[DEFERRED] Per-file detail: ${LARGE_FILE_REPORT}"
  echo "[DEFERRED] Convert these repos to Git LFS, then migrate them with MIGRATE_LARGE_FILE_REPOS=true."
fi

total_repos="$(($(wc -l < "$rows_tmp")))"

echo ""
echo "[SUMMARY] Total repos: $total_repos"
echo "Open PRs total: $total_open_prs (informational - does not block migration)"
echo "Repos with large files (deferred): $LARGE_FILE_REPO_TOTAL"
echo "======================Completed============================="

if [[ "$pr_check_failed" == true ]]; then
  echo -e "\n\033[31mSome validation checks could not be completed due to API failures. Review the errors above before proceeding.\033[0m\n"
  exit 1
elif (( LARGE_FILE_REPO_TOTAL > 0 )); then
  echo -e "\n\033[33m${LARGE_FILE_REPO_TOTAL} repo(s) contain large files and will be skipped by migration. All other repos are ready to migrate.\033[0m\n"
else
  echo -e "\n\033[32mAll repos are ready to migrate.\033[0m\n"
fi
