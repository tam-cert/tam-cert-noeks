#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-teleport.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

# ── Wait for apt lock ──────────────────────────────────────────────────────
systemctl disable --now unattended-upgrades || true
systemctl disable --now apt-daily.timer || true
systemctl disable --now apt-daily-upgrade.timer || true

systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" \
  --wait /bin/true 2>/dev/null || true

while fuser /var/lib/dpkg/lock-frontend \
            /var/lib/apt/lists/lock \
            /var/lib/dpkg/lock \
            /var/cache/apt/archives/lock >/dev/null 2>&1; do
  echo "Waiting for apt lock..."
  sleep 5
done

dpkg --configure -a || true
sleep 5

apt_install() {
  for i in 1 2 3 4 5; do
    apt-get "$@" && return 0
    echo "apt-get failed (attempt $i), retrying in 15s..."
    sleep 15
  done
  return 1
}

apt_install update
apt_install install -y curl

# ── Install Teleport Enterprise ────────────────────────────────────────────
curl -fsSL https://cdn.teleport.dev/install-v18.7.1.sh | bash -s 18.7.1 enterprise

# ── Write Teleport node config ─────────────────────────────────────────────
cat > /etc/teleport.yaml << 'TELEPORT_CFG'
version: v3
teleport:
  nodename: ssh-node-1
  data_dir: /var/lib/teleport
  log:
    output: stderr
    severity: INFO
  join_params:
    method: iam
    token_name: ssh-node-iam-token
  proxy_server: grant-tam-teleport.gvteleport.com:443

auth_service:
  enabled: false

proxy_service:
  enabled: false

ssh_service:
  enabled: true
  labels:
    team: platform
    env: demo
    node: ssh-node-1
  commands:
    - name: hostname
      command: [hostname]
      period: 1m0s
TELEPORT_CFG

# ── Enable and start Teleport ──────────────────────────────────────────────
# --insecure is required while the proxy uses a Let's Encrypt staging cert.
# Remove this drop-in once acmeURI is switched to production.
mkdir -p /etc/systemd/system/teleport.service.d
cat > /etc/systemd/system/teleport.service.d/insecure.conf << 'DROPIN'
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
DROPIN

systemctl daemon-reload
systemctl enable teleport
systemctl start teleport

echo "ssh-node-1 Teleport agent started — joining via AWS IAM join method"
