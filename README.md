# Netskope OpenAPI Mock on RHEL 10 — Microcks edition

Self-contained mock of the Netskope v2 endpoints used by the SentinelOne
Hyperautomation workflows. Backed by **Microcks Uber** (multi-arch image:
`quay.io/microcks/microcks-uber:latest`). Works on x86_64 and aarch64.

## Contents
- `install-mock-rhel10.sh` — installs `podman`, pulls Microcks Uber, creates+starts the `netskope-mock` systemd service, then uploads the spec via Microcks' REST API.
- `netskope-openapi.yaml` — OpenAPI 3 subset, with `info.title=Netskope-API`, `info.version=v2`.
- `curl-examples.sh` — one curl per operation, hitting the Microcks mock URL prefix.

## Install
```bash
sudo dnf -y install unzip
unzip netskope-mock-rhel10.zip -d netskope-mock && cd netskope-mock
sudo ./install-mock-rhel10.sh                 # default port 8080
```

After ~30s the script confirms upload and prints the mock URL:
```
Microcks UI:        http://<host>:8080
Mock base URL:      http://<host>:8080/rest/Netskope-API/v2
Example endpoint:   http://<host>:8080/rest/Netskope-API/v2/api/v2/policy/urllist
```

## Smoke-test
```bash
chmod +x curl-examples.sh
./curl-examples.sh                            # runs every example
./curl-examples.sh alerts                     # one op
HOST=10.0.0.20 PORT=8080 ./curl-examples.sh urllist_append 1001
```

## Wire Hyperautomation to this mock
Create/update Connection `netskope_api`:
- Base URL: `http://<rhel10-host>:8080/rest/Netskope-API/v2`
- Header: `Netskope-Api-Token: dummy`

Workflow JSON paths (`/api/v2/...`) stay unchanged. Full URL becomes:
`http://<host>:8080/rest/Netskope-API/v2/api/v2/events/data/alert` etc.

## Re-uploading the spec after edits
```bash
sudo cp netskope-openapi.yaml /opt/netskope-mock/
curl -fsS -X POST \
  -F "file=@/opt/netskope-mock/netskope-openapi.yaml" \
  "http://127.0.0.1:8080/api/artifact/upload?mainArtifact=true"
```

## Service control
```bash
sudo systemctl status netskope-mock
sudo systemctl restart netskope-mock
sudo journalctl -u netskope-mock -f
```

## Uninstall
```bash
sudo systemctl disable --now netskope-mock
sudo rm /etc/systemd/system/netskope-mock.service /opt/netskope-mock/netskope-openapi.yaml
sudo rmdir /opt/netskope-mock
sudo podman rmi quay.io/microcks/microcks-uber:latest || true
```

## Notes
- Microcks Uber serves the mock under `/rest/{title}/{version}{path}`. The spec sets `title=Netskope-API`, `version=v2`, so the prefix is `/rest/Netskope-API/v2`.
- Microcks returns the `examples:` blocks from the spec. You can add multiple named examples in the UI for richer demos (e.g., different responses per query parameter value).
- Stateful behavior (PATCH affecting subsequent GET) is **not** automatic; use Microcks scripting if you need it.
- Auth is not enforced by Microcks Uber by default. Add a reverse proxy if you need that.
