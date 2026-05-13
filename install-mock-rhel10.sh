#!/usr/bin/env bash
# Install the Netskope OpenAPI mock on RHEL 10 using Microcks Uber + MongoDB.
# Multi-arch: works on x86_64 and aarch64.
#
# Architecture:
#   - podman pod "netskope-mock-pod" exposes ${PORT}:8080
#   - container "netskope-mongo"      (mongo:6, multi-arch)
#   - container "netskope-microcks"   (quay.io/microcks/microcks-uber, multi-arch)
#   - systemd unit "netskope-mock"    runs a wrapper script that brings the pod up
#
# Usage:  sudo ./install-mock-rhel10.sh [--port 8080] [--microcks-image quay.io/microcks/microcks-uber:latest] [--mongo-image docker.io/library/mongo:6]
#
set -euo pipefail

PORT=8080
MICROCKS_IMAGE="quay.io/microcks/microcks-uber:latest"
MONGO_IMAGE="docker.io/library/mongo:6"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)            PORT="$2"; shift 2 ;;
    --microcks-image)  MICROCKS_IMAGE="$2"; shift 2 ;;
    --mongo-image)     MONGO_IMAGE="$2"; shift 2 ;;
    -h|--help)         sed -n '1,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC_SRC="${SCRIPT_DIR}/netskope-openapi.yaml"
[[ -f "${SPEC_SRC}" ]] || { echo "Missing netskope-openapi.yaml"; exit 1; }

echo "[1/6] Installing podman..."
dnf -y install --setopt=install_weak_deps=False podman curl jq ca-certificates >/dev/null
podman --version

echo "[2/6] Installing spec to /opt/netskope-mock..."
install -d -m 0755 /opt/netskope-mock
install -m 0644 "${SPEC_SRC}" /opt/netskope-mock/netskope-openapi.yaml
chmod a+rx /opt/netskope-mock
chmod a+r  /opt/netskope-mock/netskope-openapi.yaml

echo "[3/6] Pulling images..."
podman pull "${MONGO_IMAGE}"
podman pull "${MICROCKS_IMAGE}"

echo "[4/6] Writing /usr/local/bin/netskope-mock-start ..."
cat >/usr/local/bin/netskope-mock-start <<EOF
#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT}
MICROCKS_IMAGE="${MICROCKS_IMAGE}"
MONGO_IMAGE="${MONGO_IMAGE}"

# Recreate pod cleanly
/usr/bin/podman rm -f netskope-microcks netskope-mongo >/dev/null 2>&1 || true
/usr/bin/podman pod rm -f netskope-mock-pod         >/dev/null 2>&1 || true
/usr/bin/podman pod create --name netskope-mock-pod -p \${PORT}:8080

# Mongo
/usr/bin/podman run -d --rm --pod netskope-mock-pod --name netskope-mongo \\
  --security-opt label=disable \\
  "\${MONGO_IMAGE}" --bind_ip_all

# Wait until mongo is ready
for i in \$(seq 1 60); do
  if /usr/bin/podman exec netskope-mongo mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1; then
    echo "mongo: ready after \${i}s"
    break
  fi
  sleep 1
done

# Microcks Uber (foreground - systemd manages restarts)
exec /usr/bin/podman run --rm --init --pod netskope-mock-pod --name netskope-microcks \\
  --security-opt label=disable \\
  -v /opt/netskope-mock:/spec:ro \\
  -e SPRING_DATA_MONGODB_URI=mongodb://localhost:27017/microcks \\
  -e SPRING_DATA_MONGODB_DATABASE=microcks \\
  -e KEYCLOAK_ENABLED=false \\
  "\${MICROCKS_IMAGE}"
EOF
chmod +x /usr/local/bin/netskope-mock-start

cat >/usr/local/bin/netskope-mock-stop <<'EOF'
#!/usr/bin/env bash
/usr/bin/podman rm -f netskope-microcks netskope-mongo >/dev/null 2>&1 || true
/usr/bin/podman pod rm -f netskope-mock-pod >/dev/null 2>&1 || true
EOF
chmod +x /usr/local/bin/netskope-mock-stop

echo "[5/6] Creating systemd unit netskope-mock.service ..."
cat >/etc/systemd/system/netskope-mock.service <<EOF
[Unit]
Description=Netskope OpenAPI Mock (Microcks Uber + MongoDB via podman pod)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/netskope-mock-start
ExecStop=/usr/local/bin/netskope-mock-stop
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null
  firewall-cmd --reload >/dev/null
fi

systemctl daemon-reload
systemctl enable --now netskope-mock.service

echo "[6/6] Waiting for Microcks to be ready (up to 180s)..."
READY=0
for i in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo "  Microcks is up after ${i}s."
    READY=1
    break
  fi
  sleep 1
done
if [[ "${READY}" -ne 1 ]]; then
  echo "Microcks did not become ready in time. Check: journalctl -u netskope-mock -f"
  echo "Also: podman logs netskope-microcks ; podman logs netskope-mongo"
  exit 1
fi

echo "Uploading OpenAPI spec into Microcks ..."
UPLOAD_RESP=$(curl -fsS -X POST \
  -F "file=@/opt/netskope-mock/netskope-openapi.yaml" \
  "http://127.0.0.1:${PORT}/api/artifact/upload?mainArtifact=true") || true
echo "Upload response: ${UPLOAD_RESP}"

echo
echo "============================================================"
echo " Microcks UI:        http://<host>:${PORT}"
echo " Mock base URL:      http://<host>:${PORT}/rest/Netskope-API/v2"
echo " Example endpoint:   http://<host>:${PORT}/rest/Netskope-API/v2/api/v2/policy/urllist"
echo "============================================================"
echo "Logs:    journalctl -u netskope-mock -f"
echo "         podman logs -f netskope-microcks"
echo "Restart: systemctl restart netskope-mock"
