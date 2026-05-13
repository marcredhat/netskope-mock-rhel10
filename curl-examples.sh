#!/usr/bin/env bash
# curl examples for every operation in the Netskope OpenAPI subset, served by Microcks.
# Microcks serves the mock under: /rest/Netskope-API/v2{path}
#
# Override HOST/PORT/TOKEN via env if needed.
#   ./curl-examples.sh                 # runs all
#   ./curl-examples.sh alerts          # only one op
#   HOST=10.0.0.20 PORT=8080 ./curl-examples.sh
#
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
TOKEN="${TOKEN:-dummy}"
PREFIX="/rest/Netskope-API/v2"
BASE="http://${HOST}:${PORT}${PREFIX}"
H_AUTH=(-H "Netskope-Api-Token: ${TOKEN}")
H_JSON=(-H "Content-Type: application/json" -H "Accept: application/json")

pretty() { if command -v jq >/dev/null 2>&1; then jq .; else cat; fi; }

alerts() {
  echo "==> GET ${PREFIX}/api/v2/events/data/alert (last 7d for alice@example.com)"
  curl -sS -G "${BASE}/api/v2/events/data/alert" \
    "${H_AUTH[@]}" \
    --data-urlencode 'starttime=0' \
    --data-urlencode 'limit=1000' \
    --data-urlencode 'query=user eq "alice@example.com"' \
  | pretty
}

uci() {
  echo "==> POST ${PREFIX}/api/v2/ubadatasvc/user/uci"
  curl -sS -X POST "${BASE}/api/v2/ubadatasvc/user/uci" \
    "${H_AUTH[@]}" "${H_JSON[@]}" \
    -d '{"user":"alice@example.com","fromTime":0}' \
  | pretty
}

urllist_list() {
  echo "==> GET ${PREFIX}/api/v2/policy/urllist"
  curl -sS "${BASE}/api/v2/policy/urllist" "${H_AUTH[@]}" | pretty
}

urllist_append() {
  local id="${1:-1001}"
  echo "==> PATCH ${PREFIX}/api/v2/policy/urllist/${id}/append"
  curl -sS -X PATCH "${BASE}/api/v2/policy/urllist/${id}/append" \
    "${H_AUTH[@]}" "${H_JSON[@]}" \
    -d '{"data":{"urls":["bad.example.com","evil.example.org"],"type":"exact"}}' \
  | pretty
}

urllist_remove() {
  local id="${1:-1001}"
  echo "==> PATCH ${PREFIX}/api/v2/policy/urllist/${id}/remove"
  curl -sS -X PATCH "${BASE}/api/v2/policy/urllist/${id}/remove" \
    "${H_AUTH[@]}" "${H_JSON[@]}" \
    -d '{"data":{"urls":["bad.example.com"],"type":"exact"}}' \
  | pretty
}

urllist_deploy() {
  echo "==> POST ${PREFIX}/api/v2/policy/urllist/deploy"
  curl -sS -X POST "${BASE}/api/v2/policy/urllist/deploy" \
    "${H_AUTH[@]}" "${H_JSON[@]}" -d '{}' \
  | pretty
}

usage() {
  cat <<EOF
Operations (served via Microcks at ${BASE}):
  alerts            GET    /api/v2/events/data/alert
  uci               POST   /api/v2/ubadatasvc/user/uci
  urllist_list      GET    /api/v2/policy/urllist
  urllist_append    PATCH  /api/v2/policy/urllist/{id}/append   (default id=1001)
  urllist_remove    PATCH  /api/v2/policy/urllist/{id}/remove   (default id=1001)
  urllist_deploy    POST   /api/v2/policy/urllist/deploy
  all               run every operation (default)

Env: HOST=${HOST}  PORT=${PORT}  TOKEN=${TOKEN}
EOF
}

cmd="${1:-all}"
case "$cmd" in
  alerts|uci|urllist_list|urllist_append|urllist_remove|urllist_deploy)
    shift || true; "$cmd" "$@" ;;
  all)
    alerts; uci; urllist_list; urllist_append 1001; urllist_remove 1001; urllist_deploy ;;
  -h|--help|help) usage ;;
  *) echo "Unknown: $cmd"; usage; exit 1 ;;
esac
