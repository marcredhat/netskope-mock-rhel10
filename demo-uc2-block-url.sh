#!/usr/bin/env bash
# Use Case 2: Hash investigation reveals a malicious download URL/domain.
# Push that URL into a Netskope Custom URL List, deploy the policy, and
# write an audit note back to the SentinelOne threat.
#
# Simulates Hyperautomation Workflow 2 end-to-end against the Microcks mock.
#
# Env overrides:
#   HOST=127.0.0.1  PORT=8080  TOKEN=dummy
#   THREAT_ID=T-12345  MALICIOUS_URL=bad.example.com  NS_URLLIST_ID=1001
#
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
TOKEN="${TOKEN:-dummy}"
BASE="http://${HOST}:${PORT}/rest/Netskope-API/v2"

THREAT_ID="${THREAT_ID:-T-$(date +%s)}"
THREAT_HASH="${THREAT_HASH:-d41d8cd98f00b204e9800998ecf8427e}"
MALICIOUS_URL="${MALICIOUS_URL:-bad.example.com}"
NS_URLLIST_ID="${NS_URLLIST_ID:-1001}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
step() { echo; echo "${BOLD}${CYAN}=== $1 ===${OFF}"; }
note() { echo "${DIM}$*${OFF}"; }
val()  { echo "${BOLD}${GREEN}$*${OFF}"; }
bad()  { echo "${BOLD}${RED}$*${OFF}"; }
pretty() { if command -v jq >/dev/null 2>&1; then jq .; else cat; fi; }

#---------------------------------------------------------------------
step "0. Simulated investigation result"
#---------------------------------------------------------------------
cat <<EOF
${DIM}Threat under investigation:
  threat_id:      ${THREAT_ID}
  fileSha256:     ${THREAT_HASH}
  pivoting on download history reveals:
  malicious_url:  ${MALICIOUS_URL}${OFF}
EOF

#---------------------------------------------------------------------
step "1. Read current Netskope URL Lists (sanity check)"
#---------------------------------------------------------------------
LIST_URL="${BASE}/api/v2/policy/urllist"
note "GET ${LIST_URL}"
LISTS_JSON=$(curl -sS "${LIST_URL}" -H "Netskope-Api-Token: ${TOKEN}")
echo "${LISTS_JSON}" | pretty

EXISTS=$(echo "${LISTS_JSON}" | jq --argjson id "${NS_URLLIST_ID}" \
  '[.[] | select(.id==$id)] | length')
if [[ "${EXISTS}" -lt 1 ]]; then
  bad "  URL list id=${NS_URLLIST_ID} not found in mock. Aborting."
  exit 1
fi
val "  URL list id=${NS_URLLIST_ID} confirmed present."

#---------------------------------------------------------------------
step "2. Append the malicious URL to the URL list"
#---------------------------------------------------------------------
APPEND_URL="${BASE}/api/v2/policy/urllist/${NS_URLLIST_ID}/append"
APPEND_BODY=$(jq -n --arg u "${MALICIOUS_URL}" \
  '{data:{urls:[$u], type:"exact"}}')
note "PATCH ${APPEND_URL}"
note "body: ${APPEND_BODY}"
APPEND_RESP=$(curl -sS -X PATCH "${APPEND_URL}" \
  -H "Netskope-Api-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${APPEND_BODY}")
echo "${APPEND_RESP}" | pretty

STATUS=$(echo "${APPEND_RESP}" | jq -r '.status // "unknown"')
if [[ "${STATUS}" != "success" ]]; then
  bad "  Append did not return status=success. Aborting before deploy."
  exit 1
fi
val "  Append OK."

#---------------------------------------------------------------------
step "3. Deploy URL list changes"
#---------------------------------------------------------------------
DEPLOY_URL="${BASE}/api/v2/policy/urllist/deploy"
note "POST ${DEPLOY_URL}"
DEPLOY_RESP=$(curl -sS -X POST "${DEPLOY_URL}" \
  -H "Netskope-Api-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}')
echo "${DEPLOY_RESP}" | pretty

DSTATUS=$(echo "${DEPLOY_RESP}" | jq -r '.status // "unknown"')
[[ "${DSTATUS}" == "deployed" ]] && val "  Deploy OK." || bad "  Deploy unexpected: ${DSTATUS}"

#---------------------------------------------------------------------
step "4. Audit note that would be added to SentinelOne threat ${THREAT_ID}"
#---------------------------------------------------------------------
NOTE_TEXT="Netskope action: appended ${MALICIOUS_URL} to Custom URL List id=${NS_URLLIST_ID}; policy deployed."
echo "${DIM}POST /web/api/v2.1/threats/notes${OFF}"
jq -n --arg text "${NOTE_TEXT}" --arg id "${THREAT_ID}" \
  '{data:{text:$text}, filter:{ids:[$id]}}'

echo
echo "${BOLD}${GREEN}Use Case 2: end-to-end run complete.${OFF}"
echo "${DIM}Tip: re-run with MALICIOUS_URL=another-bad.example.com to add more entries.${OFF}"
