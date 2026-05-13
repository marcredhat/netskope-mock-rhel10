#!/usr/bin/env bash
# Use Case 1: SentinelOne sees a suspicious file -> enrich the threat with
# recent Netskope alerts + UCI for the same user, derive a verdict, and show
# what would be written back to the SentinelOne threat.
#
# This script simulates the Hyperautomation Workflow 1 logic end-to-end by
# calling the Microcks-hosted Netskope mock directly. No real SentinelOne or
# Netskope tenant required.
#
# Env overrides:
#   HOST=127.0.0.1  PORT=8080  TOKEN=dummy
#   THREAT_USER=alice@example.com  THREAT_ID=T-12345
#
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
TOKEN="${TOKEN:-dummy}"
BASE="http://${HOST}:${PORT}/rest/Netskope-API/v2"

THREAT_USER="${THREAT_USER:-alice@example.com}"
THREAT_ID="${THREAT_ID:-T-$(date +%s)}"
THREAT_HASH="${THREAT_HASH:-d41d8cd98f00b204e9800998ecf8427e}"
START_EPOCH="${START_EPOCH:-$(( $(date +%s) - 604800 ))}"   # 7 days ago

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'

step() { echo; echo "${BOLD}${CYAN}=== $1 ===${OFF}"; }
note() { echo "${DIM}$*${OFF}"; }
val()  { echo "${BOLD}${GREEN}$*${OFF}"; }
warn() { echo "${BOLD}${YEL}$*${OFF}"; }
bad()  { echo "${BOLD}${RED}$*${OFF}"; }

pretty() { if command -v jq >/dev/null 2>&1; then jq .; else cat; fi; }

#---------------------------------------------------------------------
step "0. Simulated SentinelOne threat payload"
#---------------------------------------------------------------------
cat <<EOF
${DIM}{
  "threat": {
    "id":               "${THREAT_ID}",
    "username":         "${THREAT_USER}",
    "fileSha256":       "${THREAT_HASH}",
    "confidenceLevel":  "suspicious",
    "classification":   "Malware"
  }
}${OFF}
EOF

#---------------------------------------------------------------------
step "1. Query Netskope alerts for the user (last 7 days)"
#---------------------------------------------------------------------
ALERTS_URL="${BASE}/api/v2/events/data/alert"
note "GET ${ALERTS_URL}?starttime=${START_EPOCH}&query=user eq \"${THREAT_USER}\""
ALERTS_JSON=$(curl -sS -G "${ALERTS_URL}" \
  -H "Netskope-Api-Token: ${TOKEN}" \
  --data-urlencode "starttime=${START_EPOCH}" \
  --data-urlencode "limit=1000" \
  --data-urlencode "query=user eq \"${THREAT_USER}\"")
echo "${ALERTS_JSON}" | pretty

ALERTS_TOTAL=$(echo "${ALERTS_JSON}" | jq '.result | length')
HIGH_SEV=$(echo    "${ALERTS_JSON}" | jq '[.result[] | select(.severity=="high")]   | length')
DLP_COUNT=$(echo   "${ALERTS_JSON}" | jq '[.result[] | select(.alert_type=="DLP")]  | length')
echo
echo "  Alerts total: $(val ${ALERTS_TOTAL})  High-sev: $(val ${HIGH_SEV})  DLP: $(val ${DLP_COUNT})"

#---------------------------------------------------------------------
step "2. Query Netskope UCI (User Confidence Index)"
#---------------------------------------------------------------------
UCI_URL="${BASE}/api/v2/ubadatasvc/user/uci"
note "POST ${UCI_URL}  body={\"user\":\"${THREAT_USER}\",\"fromTime\":${START_EPOCH}}"
UCI_JSON=$(curl -sS -X POST "${UCI_URL}" \
  -H "Netskope-Api-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"user\":\"${THREAT_USER}\",\"fromTime\":${START_EPOCH}}")
echo "${UCI_JSON}" | pretty

UCI_SCORE=$(echo "${UCI_JSON}" | jq -r '.uci // "unknown"')
UCI_TREND=$(echo "${UCI_JSON}" | jq -r '.trend // "unknown"')
echo
echo "  UCI score: $(val ${UCI_SCORE})  Trend: $(val ${UCI_TREND})"

#---------------------------------------------------------------------
step "3. Compute verdict"
#---------------------------------------------------------------------
VERDICT="NORMAL"
if [[ "${HIGH_SEV}" -ge 1 || "${DLP_COUNT}" -ge 1 ]]; then
  VERDICT="HIGH_RISK_USER"
elif [[ "${UCI_SCORE}" != "unknown" && "${UCI_SCORE}" -lt 500 ]]; then
  VERDICT="HIGH_RISK_USER"
elif [[ "${ALERTS_TOTAL}" -ge 5 ]]; then
  VERDICT="ELEVATED"
fi

case "${VERDICT}" in
  HIGH_RISK_USER) bad   "  Verdict: ${VERDICT}" ;;
  ELEVATED)       warn  "  Verdict: ${VERDICT}" ;;
  *)              val   "  Verdict: ${VERDICT}" ;;
esac

#---------------------------------------------------------------------
step "4. Note that would be added to SentinelOne threat ${THREAT_ID}"
#---------------------------------------------------------------------
NOTE_TEXT="Netskope enrichment for ${THREAT_USER} (7d): alerts=${ALERTS_TOTAL}, high=${HIGH_SEV}, dlp=${DLP_COUNT}, uci=${UCI_SCORE} (trend=${UCI_TREND}). Verdict=${VERDICT}."
echo "${DIM}POST /web/api/v2.1/threats/notes${OFF}"
echo "${DIM}body:${OFF}"
jq -n --arg text "${NOTE_TEXT}" --arg id "${THREAT_ID}" \
  '{data:{text:$text}, filter:{ids:[$id]}}'

#---------------------------------------------------------------------
step "5. Analyst verdict update (only when HIGH_RISK_USER)"
#---------------------------------------------------------------------
if [[ "${VERDICT}" == "HIGH_RISK_USER" ]]; then
  echo "${DIM}POST /web/api/v2.1/threats/analyst-verdict${OFF}"
  jq -n --arg id "${THREAT_ID}" \
    '{data:{analystVerdict:"suspicious"}, filter:{ids:[$id]}}'
else
  note "  Skipped (verdict is ${VERDICT})."
fi

echo
echo "${BOLD}${GREEN}Use Case 1: end-to-end run complete.${OFF}"
